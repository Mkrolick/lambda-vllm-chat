#!/usr/bin/env bash
# One-time setup for lambdachat on macOS or Linux. Safe to re-run.
#
#   ./install.sh                  set everything up (asks for your Lambda API key, offers to install opencode)
#   ./install.sh --no-opencode    skip opencode
#   ./install.sh --opencode       install opencode without asking
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
BIN=$HOME/.local/bin
ENV_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/lambdachat/venv
KEY_FILE=$HOME/.config/lambda/api-key
OPENCODE=ask
for arg in "$@"; do
  case $arg in
    --opencode) OPENCODE=yes ;;
    --no-opencode) OPENCODE=no ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok() { printf '    %s\n' "$*"; }
fail() { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin | Linux) ;;
  *) fail "lambdachat runs on macOS or Linux. On Windows, install WSL (Ubuntu) and run this inside it." ;;
esac
for c in curl ssh ssh-keygen tar; do
  command -v "$c" >/dev/null || fail "'$c' is missing; install it (on Ubuntu: sudo apt install curl openssh-client tar) and re-run"
done

say "uv (installs Python and Python tools)"
ORIG_PATH=$PATH # the installers only edit your shell config if their folder isn't on PATH yet
if command -v uv >/dev/null || [ -x "$BIN/uv" ]; then
  ok "found uv"
else
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$BIN:$PATH"
command -v uv >/dev/null || fail "uv did not install; see https://docs.astral.sh/uv/"

say "Python environment for lambdachat"
[ -x "$ENV_DIR/bin/python" ] || uv venv -q --python 3.12 "$ENV_DIR"
uv pip install -q --python "$ENV_DIR/bin/python" "prompt_toolkit>=3.0.40"
ok "$ENV_DIR"

say "The lambdachat command"
mkdir -p "$BIN"
cat >"$BIN/lambdachat" <<EOF
#!/bin/sh
exec "$ENV_DIR/bin/python" "$REPO/lambdachat" "\$@"
EOF
chmod 755 "$BIN/lambdachat"
ok "$BIN/lambdachat"
case ":$ORIG_PATH:" in
  *":$BIN:"*) ;;
  *)
    if grep -qs '\.local/bin' "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; then
      ok "$BIN is already on PATH in your shell config"
    elif PATH=$ORIG_PATH "$(command -v uv)" tool update-shell >/dev/null 2>&1; then
      ok "added $BIN to PATH in your shell config"
    else
      ok "add $BIN to your PATH (e.g. in ~/.zshrc: export PATH=\"$BIN:\$PATH\")"
    fi
    ;;
esac

say "Lambda Cloud API key"
entered=""
if [ -n "${LAMBDA_API_KEY:-}" ]; then
  ok "using \$LAMBDA_API_KEY"
elif [ -s "$KEY_FILE" ]; then
  ok "found $KEY_FILE"
else
  [ -t 0 ] || fail "no API key: put it in $KEY_FILE (or set LAMBDA_API_KEY) and re-run"
  echo "    You need a Lambda Cloud account with a payment method: https://cloud.lambda.com"
  echo "    Create a key at https://cloud.lambda.com/api-keys and paste it below."
  printf '    API key (typing is hidden): '
  read -rs key
  echo
  [ -n "$key" ] || fail "no key entered"
  mkdir -p "$(dirname "$KEY_FILE")"
  (umask 077 && printf '%s\n' "$key" >"$KEY_FILE")
  entered=1
fi
if ! "$ENV_DIR/bin/python" - "$KEY_FILE" <<'EOF'; then
import json, os, sys, urllib.request
key = os.environ.get("LAMBDA_API_KEY") or open(sys.argv[1]).read().split()[0]
req = urllib.request.Request("https://cloud.lambda.com/api/v1/instance-types",
                             headers={"Authorization": f"Bearer {key}", "User-Agent": "lambda-vllm-chat"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        types = json.load(r)["data"]
except Exception as e:  # noqa: BLE001
    print(f"    key check failed: {e}")
    sys.exit(1)
print(f"    key works ({len(types)} GPU types on the account)")
EOF
  if [ -n "$entered" ]; then
    rm -f "$KEY_FILE" # don't keep a key that doesn't work
    fail "Lambda rejected that key. Copy it again from https://cloud.lambda.com/api-keys and re-run."
  fi
  fail "Lambda rejected the key (from \$LAMBDA_API_KEY or $KEY_FILE). Replace it and re-run."
fi
[ -z "$entered" ] || ok "saved to $KEY_FILE (readable only by you)"

say "SSH key (used to reach the GPU box)"
have_key=""
for k in id_ed25519 id_ecdsa id_rsa; do
  if [ -e "$HOME/.ssh/$k" ] || [ -e "$HOME/.ssh/$k.pub" ]; then have_key=$k; break; fi
done
if [ -n "$have_key" ]; then
  [ -e "$HOME/.ssh/$have_key.pub" ] || fail "~/.ssh/$have_key has no .pub file; recreate it with: ssh-keygen -y -f ~/.ssh/$have_key > ~/.ssh/$have_key.pub"
  ok "found ~/.ssh/$have_key (it is uploaded to Lambda on first use)"
else
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N "" -C "lambdachat" -f "$HOME/.ssh/id_ed25519"
  ok "created ~/.ssh/id_ed25519 (it is uploaded to Lambda on first use)"
fi

say "opencode (optional: a coding agent that uses the model and acts on this computer)"
have_opencode() {
  for exe in $(type -a -P opencode 2>/dev/null) "$HOME/.opencode/bin/opencode"; do
    [ -x "$exe" ] && "$exe" --version 2>/dev/null | grep -Eq '(^|[^0-9])2\.[0-9]' && oc_exe=$exe && return 0
  done
  return 1
}
if have_opencode; then
  ok "found opencode 2.x; updating it to the latest version"
  "$oc_exe" upgrade >/dev/null 2>&1 || ok "(update failed; run 'opencode upgrade' later)"
  "$oc_exe" --version 2>/dev/null | sed 's/^/    /'
else
  if [ "$OPENCODE" = ask ]; then
    if [ -t 0 ]; then
      read -rp "    Install opencode? [Y/n] " answer
      case $answer in [nN]*) OPENCODE=no ;; *) OPENCODE=yes ;; esac
    else
      OPENCODE=no
    fi
  fi
  if [ "$OPENCODE" = yes ]; then
    curl -fsSL https://opencode.ai/v2/install | bash
  else
    ok "skipped (install later with: curl -fsSL https://opencode.ai/v2/install | bash)"
  fi
fi

say "Done"
cat <<EOF
    Open a new terminal window (so the new PATH applies), then:

      lambdachat ui          chat in your browser
      lambdachat chat        chat in the terminal
      lambdachat opencode    coding agent that runs commands on this computer
      lambdachat status      what's running and what it has cost
      lambdachat down        shut the GPU box down

    The first command starts a GPU box (about 10 minutes, \$3.79/hr for an H100). It shuts itself down after
    an hour with no requests. Run 'lambdachat down' when you're done to stop paying right away.
EOF
