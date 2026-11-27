# lambda-vllm-chat

Rent a GPU on Lambda Cloud, run an AI model on it, and talk to it from your own computer: in a browser, in the
terminal, or through opencode, a coding agent that can run commands and edit files on your computer. The GPU shuts
itself down after an hour without use.

The default model is [huihui-ai/Huihui-Qwen3.8-27B-abliterated](https://huggingface.co/huihui-ai/Huihui-Qwen3.8-27B-abliterated),
a 27B Qwen model with its refusals removed ("abliterated"), so it answers things other models decline. It runs on one
80 GB GPU (an H100 at $3.79/hr when this was written).

## Quick start

You need:

- A Mac, or a Linux computer. On Windows, install [WSL](https://learn.microsoft.com/windows/wsl/install) and do
  everything inside its Ubuntu terminal.
- A [Lambda Cloud](https://cloud.lambda.com) account with a payment method. You pay Lambda for every minute a GPU
  is running.

Then, in a terminal (on a Mac: the Terminal app):

1. Get this code. Either clone it:

   ```bash
   git clone https://github.com/Mkrolick/lambda-vllm-chat.git ~/lambda-vllm-chat
   ```

   or, on the GitHub page, click **Code → Download ZIP**, unzip it and move the folder to your home folder as
   `lambda-vllm-chat`. (On a Mac, the first `git` command may offer to install Apple's developer tools; say yes.)

2. Run the installer:

   ```bash
   cd ~/lambda-vllm-chat
   ./install.sh
   ```

   It installs what it needs (uv, Python, opencode), creates an SSH key if you don't have one, and asks for your
   Lambda API key. Make one at [cloud.lambda.com/api-keys](https://cloud.lambda.com/api-keys) and paste it in. It is
   checked, then saved in `~/.config/lambda/api-key`, readable only by you. Running the installer again is safe; it
   also updates opencode.

3. Open a **new** terminal window and start:

   ```bash
   lambdachat ui          # chat in your browser
   lambdachat chat        # chat in the terminal
   lambdachat opencode    # coding agent: runs commands and edits files on THIS computer, without asking
   ```

   The first one starts a GPU, which takes about 10 minutes. Later commands reuse it while it's running.

4. When you're done:

   ```bash
   lambdachat down        # shut the GPU down now (otherwise it stops itself after an hour without use)
   lambdachat status      # what's running and what it has cost so far
   ```

Good to know:

- **Cost:** billing runs from the first command until `lambdachat down` or the one-hour idle shutdown.
  `lambdachat status` shows the running total.
- **opencode acts on your computer:** with this uncensored model it will run whatever commands it decides to, without
  asking. Start it inside a project folder. `lambdachat opencode --ask` makes it ask before every command and edit.
- **What's saved:**
  - The terminal and browser chats aren't saved.
  - opencode chats are saved on your computer so you can pick up where you left off. They are never uploaded, and
    they're never put in a git repository.

## Manual setup

`install.sh` does all of this. To do it by hand:

- **The command:** put `lambdachat` on your PATH, e.g. `ln -s ~/lambda-vllm-chat/lambdachat ~/.local/bin/lambdachat`.
- **Lambda API key:** in `~/.config/lambda/api-key` or `$LAMBDA_API_KEY`.
- **SSH key:** one in `~/.ssh` (`id_ed25519`, `id_ecdsa` or `id_rsa`). It is uploaded to Lambda on first use.
- **Python and uv:** Python 3.9+ and [uv](https://docs.astral.sh/uv/). uv installs Open WebUI on the first `lambdachat ui`
  and provides prompt_toolkit for the terminal chat.
- **Gated models:** a Hugging Face token in `$HF_TOKEN` or `~/.cache/huggingface/token`.
- **opencode:** for `lambdachat opencode`, opencode 2.x (`curl -fsSL https://opencode.ai/v2/install | bash`).

## Use

```bash
lambdachat ui        # browser chat at http://localhost:13000 (launches the box first if none is running)
lambdachat chat      # terminal chat
lambdachat status    # box, cost so far, idle timer, tunnel, UI
lambdachat down      # terminate the box
```

The first `up` takes about 10 minutes: boot, vLLM install, weight download, model load. `ui` and `chat` run `up`
automatically when no box is running.

| Command | What it does |
|---|---|
| `lambdachat up` | Launch the cheapest Lambda box with capacity that fits the model, install vLLM, download the model, start serving. If a box is already running, it is re-provisioned in place (safe to re-run). |
| `lambdachat ui [--no-open]` | Start Open WebUI locally and open it. Chats are temporary and the UI's data is wiped when it stops (see below). |
| `lambdachat chat` | Terminal chat, kept in memory only. Pasted multi-line text stays one message until you press Enter (Esc then Enter adds a line). `/help` lists commands (system prompt, thinking on/off, sampling, images, retry, undo). |
| `lambdachat opencode [dir] [--new] [--ask]` | [opencode](https://opencode.ai) (coding agent) on your machine, using this model. Resumes the folder's last chat (`--new` starts a fresh one). It runs commands and edits files **without asking**; `--ask` makes it confirm each action. See below. |
| `lambdachat api [--env]` | Open the tunnel and print the OpenAI-compatible endpoint. `eval "$(lambdachat api --env)"` exports `OPENAI_BASE_URL`, `OPENAI_API_KEY` and `LAMBDACHAT_MODEL` (it needs a running box and never launches one). |
| `lambdachat status` | Model and revision, instance, cost so far, minutes idle, tunnel, UI. |
| `lambdachat keepalive on\|off` | Pause or resume idle auto-terminate. |
| `lambdachat logs` | Follow the vLLM log on the box. |
| `lambdachat ssh [cmd]` | Shell on the box. |
| `lambdachat down` | Terminate the box, stop the tunnel and the local UI, and delete the UI's session data. |
| `lambdachat adopt ID` | Take over a Lambda instance launched some other way; then `lambdachat up` provisions it. |

## Thinking mode

Qwen3.8 thinks before answering by default. You can turn this off or lower the effort.

- **Open WebUI**: the menu button next to the model picker has a **Thinking** menu: On, On (medium effort), On (low effort), Off.
  Reasoning appears as a collapsible "Thought for N seconds" block.
- **Terminal**: `/think off`, `/think on`, `/think low`. Start with `lambdachat chat --no-think` to have it off from the beginning.
- **API**: pass `chat_template_kwargs`:

```python
from openai import OpenAI
import os
client = OpenAI()  # after: eval "$(lambdachat api --env)"
r = client.chat.completions.create(
    model=os.environ["LAMBDACHAT_MODEL"],
    messages=[{"role": "user", "content": "..."}],
    extra_body={"chat_template_kwargs": {"enable_thinking": False}},  # or {"reasoning_effort": "low"}
)
print(r.choices[0].message.content)
# reasoning (when thinking is on) comes back separately, in the message's `reasoning` field
```

If you don't set sampling parameters, the model's own defaults from `generation_config.json` apply (temperature 1.0,
top_p 0.95, top_k 20 for this model).

## opencode: an agent that acts on your machine

```bash
cd ~/some/project
lambdachat opencode            # full-screen opencode; resumes this folder's last chat
lambdachat opencode --new      # start a fresh chat instead
lambdachat opencode --ask      # asks before every shell command, edit and web request
lambdachat opencode run "fix the failing test"     # one-shot (also continues the folder's last chat; --new for fresh)
```

- **What runs where:** the model runs on the Lambda box. opencode, and everything it does (shell commands, file
  edits), runs **on your machine** as you.
- **Approval:** auto-approve is the default (`OPENCODE_AUTO=1` in config.env). Set it to 0 to make `--ask` the default.
- **Chats:** each folder has its own chat history. `lambdachat opencode` picks up that folder's latest chat. Inside
  opencode you can also switch to older ones, or use `--session ID`. Chats are stored by opencode in
  `~/.local/share/opencode` on your computer:
  - They're outside every git repository. A session adds no files and no commits to the project folder you work in,
    and opencode's own undo snapshots there have no remote.
  - Sharing (uploading a chat to opencode.ai) is turned off.
  - To delete them, remove that folder.
- **Thinking mode:** pick a variant in `/models` (`#low`, `#medium`, `#nothink`), or `run -m lambda/<model>#nothink`.
- **What it can see:** its only model is the Lambda one, and it does not read your `~/.claude` instructions or skills.
- **Idle shutdown:** the box's idle timer counts opencode's requests. After 60 minutes with none, the box terminates.
  The next `lambdachat opencode` starts a new one and your chats are still there.

## What is saved

- **Terminal chat**: the conversation exists only in the `lambdachat chat` process. Nothing is written to disk, including
  your input history, and it is gone when you quit.
- **Open WebUI**: new chats are temporary, so they are never written to its database. The UI's whole data directory
  (`~/.config/lambda-vllm-chat/webui-session`) is deleted whenever the UI starts or stops, and `lambdachat down` stops it.
  This also removes chats you made permanent by turning temporary mode off, uploads and logs. Only the helper models it
  downloads (embeddings, tokenizer) are kept, in `webui-cache`.
- **The box**: vLLM doesn't log prompts or replies, and the box's disk is erased when it terminates.
- **opencode**: chats are saved on your computer so they can be resumed (see above). They're never uploaded.
- **API**: whatever your own scripts record is up to them.

## Cost and auto-shutdown

The box bills by the minute until it is terminated. A systemd timer on the box checks vLLM every 5 minutes. After
`IDLE_MIN` minutes (default 60) with no requests, the box terminates itself through the Lambda API.
`lambdachat status` shows the idle time. Pause the timer with `lambdachat keepalive on` and resume it with `keepalive off`.
The next `ui`/`chat`/`up` starts a fresh box.

## Configuration

Defaults are in [`config.env`](config.env). Override any value in `~/.config/lambda-vllm-chat/config.env`, or for one run with
`LAMBDACHAT_<KEY>=value`:

```bash
LAMBDACHAT_MODEL_REVISION=739e3c5b89849f6c238ce1e5b70008612ae42cdd lambdachat up   # pin the exact weights
LAMBDACHAT_INSTANCE_TYPES=gpu_1x_h100_sxm5 lambdachat up                           # choose the GPU type
LAMBDACHAT_IDLE_MIN=0 lambdachat up                                                # never auto-terminate
```

To serve a different model, set `MODEL_REPO` (and `MIN_VRAM_GB` if it needs more or less memory). Switching models or
revisions needs `lambdachat down` first. Running two boxes at once needs a separate state directory
(`LAMBDACHAT_STATE_DIR=~/.config/lambda-vllm-chat-2`), with its own `config.env` there setting `API_PORT` and `UI_PORT`.

## How it works

- **Box** (`box/provision.sh`, run over SSH):
  - Installs the idle watchdog first, so a box whose provisioning fails still terminates itself.
  - Installs uv, Python 3.12 and vLLM.
  - Downloads the weights at a resolved commit sha while vLLM installs.
  - Runs `vllm serve` as a systemd service bound to `127.0.0.1:8000`.
  - Lambda's Ubuntu image ships an older NVIDIA driver (CUDA 12.8) than current vLLM builds need (CUDA 13). The script
    detects this and installs NVIDIA's CUDA forward-compatibility libraries, which datacenter GPUs support.
- **Idle watchdog** (`box/idle-terminate.sh`): reads vLLM's `/metrics`. To terminate itself it needs the Lambda API key,
  which is copied to `/etc/lambdachat/lambda-api-key` (root-only) on the box. Set `IDLE_MIN=0` to skip both.
- **Laptop**:
  - An SSH tunnel forwards `127.0.0.1:18000` to vLLM, and a small background process reopens it if it drops (sleep,
    network change).
  - Open WebUI runs locally on `127.0.0.1:13000` with login disabled. To keep that safe and the evals clean:
    - Only its own origin may call its API (CORS), so other websites can't use the no-login admin session.
    - Tools, code execution, automations, web search and memory are off, so the model can't run anything on your
      machine and nothing extra is added to its prompts.
    - Background title/tag/follow-up generation is off, so the only requests to the model are yours.
  - Nothing is exposed publicly. vLLM and the UI listen on localhost only, and the box is reached over SSH (Lambda's
    firewall allows only port 22). Provisioning also turns off the JupyterLab that Lambda's image publishes through a
    Cloudflare tunnel.
  - Neither the UI nor the API asks for a password. Anything running as your user on this machine can use them.

## Troubleshooting

- `lambdachat logs` shows vLLM's log. `lambdachat up` re-runs provisioning and picks up where it failed.
- Hybrid linear-attention models like Qwen3.8 need `--max-num-seqs` at or below the number of cache blocks that fit.
  `MAX_NUM_SEQS=128` works on 80 GB. vLLM's default of 1024 fails at startup.
- "no capacity right now": Lambda has no fitting GPU free. Retry later, or widen `INSTANCE_TYPES`, `MAX_GPUS` or `MIN_VRAM_GB`.
- Logs on your machine: `~/.config/lambda-vllm-chat/tunnel-keeper.log`, and `webui-session/webui.log` there while the UI runs.
