# lambda-llm-chat

Serve a Hugging Face model with vLLM on a Lambda Cloud GPU box and chat with it from your laptop, either in a browser
(Open WebUI) or in the terminal. Every conversation is saved locally. The box terminates itself after it has been idle for 2 hours.

The default model is [huihui-ai/Huihui-Qwen3.8-27B-abliterated](https://huggingface.co/huihui-ai/Huihui-Qwen3.8-27B-abliterated)
(bf16, ~56 GB), which runs on a single 80 GB GPU (H100 at $3.79/hr when this was written).

## Setup (once)

```bash
git clone https://github.com/Mkrolick/lambda-llm-chat ~/Code/lambda-llm-chat
ln -s ~/Code/lambda-llm-chat/llmchat ~/bin/llmchat     # or anywhere on your PATH
```

You need:

- A Lambda Cloud API key, in `~/.config/lambda/api-key` or `$LAMBDA_API_KEY`.
- An SSH key in `~/.ssh` (`id_ed25519`, `id_ecdsa` or `id_rsa`). If Lambda doesn't have it yet, it is uploaded on the first `up`.
- Python 3.9+ (standard library only) and [uv](https://docs.astral.sh/uv/). uv installs Open WebUI on the first `llmchat ui`.
- For gated models, a Hugging Face token in `$HF_TOKEN` or `~/.cache/huggingface/token`.

## Use

```bash
llmchat ui        # browser chat at http://localhost:13000 (launches the box first if none is running)
llmchat chat      # terminal chat
llmchat status    # box, cost so far, idle timer, tunnel, UI
llmchat down      # terminate the box
```

The first `up` takes about 10 minutes: boot, vLLM install, weight download, model load. `ui` and `chat` run `up`
automatically when no box is running.

| Command | What it does |
|---|---|
| `llmchat up` | Launch the cheapest Lambda box with capacity that fits the model, install vLLM, download the model, start serving. If a box is already running, it is re-provisioned in place (safe to re-run). |
| `llmchat ui [--no-open]` | Start Open WebUI locally and open it. Chats are stored on your machine, so they survive the box being terminated. |
| `llmchat chat` | Terminal chat. `/help` lists commands (system prompt, thinking on/off, sampling, images, retry, undo). |
| `llmchat api [--env]` | Open the tunnel and print the OpenAI-compatible endpoint. `eval "$(llmchat api --env)"` exports `OPENAI_BASE_URL`, `OPENAI_API_KEY` and `LLMCHAT_MODEL`. |
| `llmchat status` | Model and revision, instance, cost so far, minutes idle, tunnel, UI. |
| `llmchat keepalive on\|off` | Pause or resume idle auto-terminate. |
| `llmchat logs` | Follow the vLLM log on the box. |
| `llmchat ssh [cmd]` | Shell on the box. |
| `llmchat down` | Terminate the box and stop the tunnel and the local UI. Transcripts and UI history stay. |
| `llmchat adopt ID` | Take over a Lambda instance launched some other way; then `llmchat up` provisions it. |

## Thinking mode

Qwen3.8 thinks before answering by default. You can turn this off or lower the effort.

- **Open WebUI**: the menu button next to the model picker has a **Thinking** menu: On, On (medium effort), On (low effort), Off.
  Reasoning appears as a collapsible "Thought for N seconds" block.
- **Terminal**: `/think off`, `/think on`, `/think low`. Start with `llmchat chat --no-think` to have it off from the beginning.
- **API**: pass `chat_template_kwargs`:

```python
from openai import OpenAI
import os
client = OpenAI()  # after: eval "$(llmchat api --env)"
r = client.chat.completions.create(
    model=os.environ["LLMCHAT_MODEL"],
    messages=[{"role": "user", "content": "..."}],
    extra_body={"chat_template_kwargs": {"enable_thinking": False}},  # or {"reasoning_effort": "low"}
)
print(r.choices[0].message.content)
# reasoning (when thinking is on) comes back separately, in the message's `reasoning` field
```

If you don't set sampling parameters, the model's own defaults from `generation_config.json` apply (temperature 1.0,
top_p 0.95, top_k 20 for this model).

## Transcripts

`llmchat chat` writes each conversation to `~/LLM-Chat/<model>/transcripts/<date>_<time>.json` after every turn. Each file records:

- `meta`: model repo, exact commit sha, instance type, vLLM version, the model's default sampling
- `system_prompt`
- `turns`: each message with timestamp. Assistant turns also record their reasoning, usage, finish reason, and the
  request settings used (system prompt, sampling, chat template kwargs).
- `discarded`: replies dropped with `/retry` or `/undo`

Open WebUI keeps its own history in `~/LLM-Chat/open-webui/` and can export chats as JSON.

## Cost and auto-shutdown

The box bills by the minute until it is terminated. A systemd timer on the box checks vLLM every 5 minutes. After
`IDLE_MIN` minutes (default 120) with no requests, the box terminates itself through the Lambda API.
`llmchat status` shows the idle time. Pause the timer with `llmchat keepalive on` and resume it with `keepalive off`.
Nothing is lost when the box goes away: transcripts and Open WebUI data are on your machine. The next `ui`/`chat`/`up` starts a
fresh box.

## Configuration

Defaults are in [`config.env`](config.env). Override any value in `~/.config/lambda-llm-chat/config.env`, or for one run with
`LLMCHAT_<KEY>=value`:

```bash
LLMCHAT_MODEL_REVISION=739e3c5b89849f6c238ce1e5b70008612ae42cdd llmchat up   # pin the exact weights
LLMCHAT_INSTANCE_TYPES=gpu_1x_h100_sxm5 llmchat up                           # choose the GPU type
LLMCHAT_IDLE_MIN=0 llmchat up                                                # never auto-terminate
```

To serve a different model, set `MODEL_REPO` (and `MIN_VRAM_GB` if it needs more or less memory). Running a different
model needs `llmchat down` first. Running two boxes at once needs a separate state directory and separate ports:
`LLMCHAT_STATE_DIR=~/.config/lambda-llm-chat-2`, with its own `config.env` there setting `API_PORT` and `UI_PORT`.

## How it works

- **Box** (`box/provision.sh`, run over SSH):
  - Installs uv, Python 3.12 and vLLM.
  - Downloads the weights at a resolved commit sha while vLLM installs.
  - Runs `vllm serve` as a systemd service bound to `127.0.0.1:8000`.
  - Lambda's Ubuntu image ships an older NVIDIA driver (CUDA 12.8) than current vLLM builds need (CUDA 13). The script
    detects this and installs NVIDIA's CUDA forward-compatibility libraries, which datacenter GPUs support.
- **Idle watchdog** (`box/idle-terminate.sh`): reads vLLM's `/metrics`. To terminate itself it needs the Lambda API key,
  which is copied to `/etc/llmchat/lambda-api-key` (root-only) on the box. Set `IDLE_MIN=0` to skip both.
- **Laptop**:
  - An SSH tunnel forwards `127.0.0.1:18000` to vLLM, and a small background process reopens it if it drops (sleep,
    network change).
  - Open WebUI runs locally on `127.0.0.1:13000` with login disabled and its background title/tag generation turned off,
    so the only requests to the model are yours.
  - Nothing is exposed publicly. vLLM and the UI listen on localhost only, and the box is reached over SSH.

## Troubleshooting

- `llmchat logs` shows vLLM's log. `llmchat up` re-runs provisioning and picks up where it failed.
- Hybrid linear-attention models like Qwen3.8 need `--max-num-seqs` at or below the number of cache blocks that fit.
  `MAX_NUM_SEQS=128` works on 80 GB. vLLM's default of 1024 fails at startup.
- "no capacity right now": Lambda has no fitting GPU free. Retry later, or widen `INSTANCE_TYPES`, `MAX_GPUS` or `MIN_VRAM_GB`.
- Logs on your machine: `~/.config/lambda-llm-chat/tunnel-keeper.log` and `~/LLM-Chat/open-webui/webui.log`.
