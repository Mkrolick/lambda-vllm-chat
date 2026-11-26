#!/usr/bin/env bash
# Runs on the GPU box (as ubuntu). Installs the idle watchdog first (so a failed run still self-terminates), then vLLM,
# downloads the model and serves it with systemd on 127.0.0.1:8000. Safe to re-run: finished steps are skipped and vLLM
# only restarts if its config or version changed.
#
# Inputs (environment): MODEL_REPO MODEL_REVISION SERVED_NAME VLLM_VERSION MAX_MODEL_LEN MAX_NUM_SEQS
#                       GPU_MEMORY_UTILIZATION VLLM_ARGS TP IDLE_MIN INSTANCE_ID
set -euo pipefail

: "${MODEL_REPO:?}" "${SERVED_NAME:?}" "${INSTANCE_ID:?}"
MODEL_REVISION=${MODEL_REVISION:-main}
VLLM_VERSION=${VLLM_VERSION:-0.34.0}
MAX_MODEL_LEN=${MAX_MODEL_LEN:-131072}
MAX_NUM_SEQS=${MAX_NUM_SEQS:-128}
GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION:-0.92}
VLLM_ARGS=${VLLM_ARGS:-}
TP=${TP:-1}
IDLE_MIN=${IDLE_MIN:-120}

HERE=$(cd "$(dirname "$0")" && pwd)
VENV=$HOME/venv
PY=$VENV/bin/python
export PATH=$HOME/.local/bin:$PATH

step() { printf '\n==> %s\n' "$*"; }

exec 9>/tmp/lambdachat-provision.lock
flock -w 1800 9 || { echo "another provisioning run is still going"; exit 1; }

step "Idle watchdog (terminate after $IDLE_MIN min without requests)"
sudo install -d -m 700 /etc/lambdachat /var/lib/lambdachat
sudo install -m 755 "$HERE/idle-terminate.sh" /usr/local/bin/lambdachat-idle-terminate
printf 'INSTANCE_ID=%s\nIDLE_MIN=%s\n' "$INSTANCE_ID" "$IDLE_MIN" | sudo tee /etc/lambdachat/idle.env >/dev/null
# Idle time counts from 30 min from now while provisioning runs; set to "now" once the model is up. If this run fails,
# the box terminates itself IDLE_MIN minutes after that.
echo $(( $(date +%s) + 1800 )) | sudo tee /var/lib/lambdachat/last_active >/dev/null
sudo tee /etc/systemd/system/lambdachat-idle.service >/dev/null <<EOF
[Unit]
Description=Terminate this Lambda box when the model has been idle for IDLE_MIN minutes

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lambdachat-idle-terminate
EOF
sudo tee /etc/systemd/system/lambdachat-idle.timer >/dev/null <<EOF
[Unit]
Description=Check model idleness every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
sudo systemctl daemon-reload
if [ "$IDLE_MIN" -gt 0 ] && sudo test -s /etc/lambdachat/lambda-api-key; then
  sudo systemctl enable -q --now lambdachat-idle.timer
  echo "on"
else
  sudo systemctl disable -q --now lambdachat-idle.timer 2>/dev/null || true
  sudo rm -f /etc/lambdachat/lambda-api-key
  echo "off (IDLE_MIN=0 or no API key on the box)"
fi


step "Close Lambda's public JupyterLab (a Cloudflare tunnel to a shell on this box, guarded only by a token)"
sudo systemctl disable -q --now lambda-jupyter.service cloudflared.service 2>/dev/null || true

step "Python env"
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
[ -x "$PY" ] || uv venv -q --python 3.12 "$VENV"
uv pip install -q --python "$PY" -U "huggingface_hub[hf_xet]"

step "Resolve $MODEL_REPO@$MODEL_REVISION"
SHA=$("$PY" -c 'import sys; from huggingface_hub import model_info; print(model_info(sys.argv[1], revision=sys.argv[2]).sha)' \
  "$MODEL_REPO" "$MODEL_REVISION")
MODEL_DIR=$HOME/models/${MODEL_REPO##*/}-${SHA:0:7}
echo "commit $SHA -> $MODEL_DIR"

step "Download weights (in the background while vLLM installs)"
mkdir -p "$MODEL_DIR"
"$VENV/bin/hf" download "$MODEL_REPO" --revision "$SHA" --local-dir "$MODEL_DIR" >"$HOME/download.log" 2>&1 &
DL=$!

step "vLLM $VLLM_VERSION"
INSTALLED=$("$PY" -c 'import importlib.metadata as m; print(m.version("vllm"))' 2>/dev/null || true)
if [ "$INSTALLED" != "$VLLM_VERSION" ]; then
  [ -z "$INSTALLED" ] || sudo systemctl stop vllm 2>/dev/null || true  # don't swap packages under a live server
  uv pip install -q --python "$PY" "vllm==$VLLM_VERSION"
fi
"$PY" -c 'import importlib.metadata as m; print("vllm", m.version("vllm"), "torch", m.version("torch"))'

step "CUDA driver check"
NEED=$("$PY" -c 'import torch; print(torch.version.cuda)')
HAVE=$(nvidia-smi | sed -n 's/.*CUDA Version: *\([0-9.]*\).*/\1/p' | head -1)
COMPAT=""
if [ "$(printf '%s\n%s\n' "$NEED" "$HAVE" | sort -V | head -1)" != "$NEED" ]; then
  # The driver is older than the CUDA vLLM was built for. Datacenter GPUs support NVIDIA's forward-compat libraries.
  COMPAT=/usr/local/cuda-$NEED/compat
  echo "driver supports CUDA $HAVE, vLLM needs $NEED: using forward-compat libraries in $COMPAT"
  if [ ! -e "$COMPAT/libcuda.so.1" ]; then
    . /etc/os-release
    REPO=ubuntu${VERSION_ID//./}/$(uname -m | sed 's/aarch64/sbsa/')
    curl -fsSL -o /tmp/cuda-keyring.deb "https://developer.download.nvidia.com/compute/cuda/repos/$REPO/cuda-keyring_1.1-1_all.deb"
    APT="sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600"  # unattended-upgrades may hold it
    $APT install -y -qq /tmp/cuda-keyring.deb >/dev/null
    $APT update -qq -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/cuda-"${REPO//\//-}".list \
      -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
    $APT install -y -qq "cuda-compat-${NEED//./-}" >/dev/null
  fi
else
  echo "driver supports CUDA $HAVE, vLLM needs $NEED: ok"
fi
LD_LIBRARY_PATH=$COMPAT "$PY" -c 'import torch; assert torch.cuda.is_available(), "CUDA not usable"; print(torch.cuda.device_count(), "x", torch.cuda.get_device_name(0))'

step "Wait for download"
if ! wait "$DL"; then tail -20 "$HOME/download.log"; exit 1; fi
du -sh "$MODEL_DIR"
printf '%s\n' "$SHA" >"$MODEL_DIR/.lambdachat-revision"
"$PY" - "$MODEL_REPO" "$SHA" "$MODEL_DIR" "$COMPAT" >"$HOME/lambdachat-served.json" <<'PYEOF'
import importlib.metadata as m, json, pathlib, sys
repo, sha, model_dir, compat = sys.argv[1:]
gen = pathlib.Path(model_dir, "generation_config.json")
# Chat-template switches the clients can offer (Qwen-style enable_thinking / reasoning_effort).
template = "".join(p.read_text() for p in pathlib.Path(model_dir).glob("*.jinja"))
tok_cfg = pathlib.Path(model_dir, "tokenizer_config.json")
if tok_cfg.exists():
    template += json.dumps(json.loads(tok_cfg.read_text()).get("chat_template") or "")
print(json.dumps({"model_repo": repo, "revision_sha": sha, "model_dir": model_dir, "cuda_compat": compat or None,
                  "vllm_version": m.version("vllm"), "torch_version": m.version("torch"),
                  "generation_config": json.loads(gen.read_text()) if gen.exists() else None,
                  "template_kwargs": [k for k in ("enable_thinking", "reasoning_effort") if k in template]}))
PYEOF

step "vLLM service"
UNIT=$(cat <<EOF
[Unit]
Description=vLLM serving $MODEL_REPO@$SHA
After=network-online.target

[Service]
User=$USER
WorkingDirectory=$HOME
Environment=LD_LIBRARY_PATH=$COMPAT
Environment=HF_HUB_OFFLINE=1
Environment=VLLM_NO_USAGE_STATS=1
Environment=LAMBDACHAT_VLLM_VERSION=$VLLM_VERSION
ExecStart=$VENV/bin/vllm serve $MODEL_DIR --served-model-name $SERVED_NAME --host 127.0.0.1 --port 8000 --tensor-parallel-size $TP --max-model-len $MAX_MODEL_LEN --max-num-seqs $MAX_NUM_SEQS --gpu-memory-utilization $GPU_MEMORY_UTILIZATION $VLLM_ARGS
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
)
if [ "$UNIT" != "$(cat /etc/systemd/system/vllm.service 2>/dev/null)" ] || ! systemctl is-active -q vllm; then
  printf '%s\n' "$UNIT" | sudo tee /etc/systemd/system/vllm.service >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable -q vllm
  sudo systemctl restart vllm
  echo "started"
else
  echo "unchanged and running"
fi

step "Wait for the model to load"
for i in $(seq 1 180); do
  if curl -fs -m 5 http://127.0.0.1:8000/health >/dev/null; then
    echo "ready after ~$((i * 10)) s"
    date +%s | sudo tee /var/lib/lambdachat/last_active >/dev/null
    curl -fs http://127.0.0.1:8000/v1/models | "$PY" -c 'import json,sys; [print("serving", m["id"], "max_model_len", m.get("max_model_len")) for m in json.load(sys.stdin)["data"]]'
    exit 0
  fi
  if [ "$(systemctl show -p NRestarts --value vllm)" -ge 2 ]; then
    echo "vLLM keeps crashing:"; journalctl -u vllm --no-pager -n 60; exit 1
  fi
  sleep 10
done
echo "vLLM not healthy after 30 min:"; journalctl -u vllm --no-pager -n 60; exit 1
