# Olama — Intel GPU Docker

Run [Ollama](https://ollama.com) in Docker with Intel GPU acceleration.
Supports **Intel Arc**, **Iris Xe**, and **integrated Intel graphics** via Intel's oneAPI runtime.

> **No models are bundled.** After starting the stack, pull whichever model you want with `docker exec olama ollama pull <model>`.

---

## What's Included

| Container | Category | Purpose | Port |
|---|---|---|---|
| `olama` | **AI Core** | Ollama LLM engine with Intel GPU passthrough | `11434` |
| `open-webui` | **Interface** | Browser chat UI connected to the AI | `45213` |
| `searxng` | **Search** | Self-hosted web search backend | internal only |
| `pipelines` | **Pipelines** | Python tool/function runtime for Open WebUI | internal only |
| `dozzle` | **Logs** | Real-time web log viewer for all containers | `9999` |

**Web search is off by default.** SearXNG only runs searches when you explicitly toggle the web search button in the chat UI — it never runs in the background on its own.

**Pipelines** adds custom tools, code execution, filters, rate limiting, and usage monitoring to Open WebUI. Drop any `.py` pipeline file into `${DATA_DIR}/pipelines/` to add new capabilities.

**Dozzle** provides a real-time web log viewer at **http://localhost:9999** — open it in your browser to see live logs from all containers without using the CLI.

All data is stored under a single configurable `DATA_DIR` on the host — no anonymous Docker volumes — so everything is exportable by simply copying that directory.

---

## Prerequisites

Before installing, make sure you have:

- **Docker** — [Install Docker Engine](https://docs.docker.com/engine/install/)
- **Docker Compose** — included with Docker Desktop; for Linux servers install the [Compose plugin](https://docs.docker.com/compose/install/linux/)
- **Intel GPU** — any system with Intel Arc, Iris Xe, or integrated Intel graphics running Linux
  - Confirm your GPU is visible: `ls /dev/dri/renderD*` (should list at least one device)

---

## Method 1 — One-Command Installer

The fastest way to get the full stack running. The script clones the repo, builds the Intel GPU image, creates the data directories, writes a `.env`, and starts all 5 containers. Safe to run over SSH — closing the terminal will not stop the install.

**Step 1 — Run the installer**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/install.sh)
```

The installer will:
1. Verify Docker and Docker Compose are available
2. Warn if no Intel GPU render node (`/dev/dri/renderD*`) is found
3. Clone the repo to `/opt/olama-stack/`
4. Create data directories under `/opt/olama/` (models, webui, searxng, pipelines, logs)
5. Build the Ollama Intel GPU image (~5 min on first run — pulls Ollama from Docker Hub and installs Intel oneAPI drivers)
6. Pull the `open-webui`, `searxng`, `pipelines`, and `dozzle` images
7. Start all 5 containers and wait until Ollama and Open WebUI are ready

**The installer is safe to run over SSH — closing the terminal will not interrupt it.**
All output is logged to `/tmp/olama-install.log`. To follow progress from another session:

```bash
tail -f /tmp/olama-install.log
```

If the install fails, the full log is printed in the error message. You can override the log path with `LOG_FILE=/path/to/install.log bash scripts/install.sh`.

**Step 2 — Pull a model**

No model is included — pull one from the terminal:

```bash
# Interactive menu
bash /opt/olama-stack/scripts/pull-model.sh

# Or pull directly
docker exec olama ollama pull mistral
docker exec olama ollama pull llama3.2:3b
```

**Step 3 — Open the chat UI**

Open your browser at **http://localhost:45213** and select the model you just pulled.

**Optional — Custom install options**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/install.sh) \
  --port 11434 \
  --webui-port 45213 \
  --data-dir /opt/olama \
  --version latest
```

Available flags:

| Flag | Default | Purpose |
|---|---|---|
| `--data-dir DIR` | `/opt/olama` | Where to store models, chat history, logs |
| `--port PORT` | `11434` | Host port for the Ollama API |
| `--webui-port PORT` | `45213` | Host port for the Open WebUI chat UI |
| `--version TAG` | `latest` | Ollama image tag |
| `--branch NAME` | auto-detected | Git branch to clone (auto-tries `main` → `master`) |

---

## Method 2 — Docker Compose (Manual)

Use this if you want full control over the compose file or are already familiar with Docker Compose.

**Step 1 — Clone the repository**

```bash
git clone https://github.com/Crashcart/Olama-intelgpu.git
cd Olama-intelgpu
```

**Step 2 — Configure environment**

```bash
cp .env.example docker/.env
```

Open `docker/.env`. At minimum, set `DATA_DIR` to wherever you have enough space (external drive, NAS, etc.):

```env
# Root for all data and logs — change to your storage path
DATA_DIR=/opt/olama

OLLAMA_PORT=11434
WEBUI_PORT=45213
```

Then create the data directories:

```bash
# Docker would create these as root if you skip this — better to own them yourself
mkdir -p ${DATA_DIR}/{models,webui,searxng,pipelines,logs}
```

> **SearXNG config note:** `docker/searxng/settings.yml` is automatically bind-mounted into the container — no manual copy needed. To customise search engines, edit `docker/searxng/settings.yml` directly.

**Step 3 — Build and start**

```bash
cd docker

# First run: builds the Olama image (Intel GPU drivers) and starts all containers
docker compose up --build -d

# Subsequent starts (image already built):
docker compose up -d
```

The image build takes ~5 minutes the first time — it installs Intel oneAPI GPU drivers on top of the Ollama base image.

**Step 4 — Pull a model (required — no model is included)**

```bash
# From terminal
docker exec olama ollama pull mistral

# Or use the helper script from the repo root
bash scripts/pull-model.sh
```

**Step 5 — Open the chat UI**

Open your browser at **http://localhost:45213** and select the model you just pulled.

**Step 6 — Enable web search (when you want it)**

Web search is **off by default**. To search the web for a specific question:

1. In the chat bar, click the **magnifying glass icon** (web search toggle)
2. It turns blue — your next message will search the web before answering
3. Click it again to turn web search off

The AI will fetch and summarize relevant search results, then answer your question. SearXNG does not run any searches unless you activate the toggle.

**Stopping and removing**

```bash
# Stop all containers (all data in DATA_DIR is preserved)
cd docker && docker compose down
```

Since all data is bind-mounted to the host, `docker compose down -v` has no extra effect. To fully wipe data: `rm -rf ${DATA_DIR}`.

---

## How Web Search Works

```
You (toggle ON) → Open WebUI → SearXNG → Public search engines
                                    ↓
                          Results returned to Open WebUI
                                    ↓
                    Open WebUI sends results + your question → Olama
                                    ↓
                              AI answers you
```

- **SearXNG is private** — no exposed port; only reachable by Open WebUI inside the Docker network
- **No API keys needed** — SearXNG aggregates results from public search engines
- **You stay in control** — the toggle must be on for any web request to happen

---

## Storage — Exportable Data

All persistent data is bind-mounted to the host under `DATA_DIR`. Nothing is locked inside Docker volumes.

```
${DATA_DIR}/
├── models/        ← Ollama model weights          (can reach 100+ GB for large models)
├── webui/         ← Chat history, RAG documents, ChromaDB vector DB, user settings
├── searxng/       ← SearXNG runtime state (limiter.toml, favicon cache)
├── pipelines/     ← Pipeline .py scripts; drop files here to add tools to Open WebUI
└── logs/          ← Log files exported by scripts/logs.sh
```

`docker/searxng/settings.yml` (search engine config) lives in the repo and is mounted read-only — edit it there.

**To export or back up everything:**

```bash
# Copy entire data dir to external drive / NAS
rsync -av --progress ${DATA_DIR}/ /mnt/backup/olama/

# Or just models (largest item)
rsync -av --progress ${DATA_DIR}/models/ /mnt/backup/olama-models/

# Or just chat history and documents
rsync -av --progress ${DATA_DIR}/webui/ /mnt/backup/olama-webui/
```

**To move to a new machine:**

1. Copy `${DATA_DIR}/` to the new machine
2. Clone the repo and set `DATA_DIR` in `docker/.env` to the copied path
3. Run `docker compose up -d` — all history and models are immediately available

---

## Logs — Viewing and Analyzing

All containers write logs to Docker's `json-file` driver with automatic rotation (10 MB × 5 files per container by default, configurable via `LOG_MAX_SIZE` / `LOG_MAX_FILES` in `.env`).

### Log helper script

```bash
# Show container categories, running state, and disk usage
bash scripts/logs.sh status

# Live tail all containers (Ctrl-C to stop)
bash scripts/logs.sh tail

# Live tail a single container
bash scripts/logs.sh tail olama
bash scripts/logs.sh tail open-webui
bash scripts/logs.sh tail searxng
bash scripts/logs.sh tail pipelines

# Dump recent logs to terminal (last 100 lines by default)
bash scripts/logs.sh show
bash scripts/logs.sh show olama 200

# Show only ERROR / WARN / CRITICAL lines across all containers
bash scripts/logs.sh errors

# Export all logs to ${DATA_DIR}/logs/*.log for offline analysis
bash scripts/logs.sh export
```

### Log files after export

```
${DATA_DIR}/logs/
├── olama.log           ← LLM engine — GPU errors, model load failures, inference errors
├── open-webui.log      ← Chat UI — RAG errors, auth failures, API call errors
├── searxng.log         ← Search — query failures, engine timeouts, config errors
├── pipelines.log       ← Pipelines — tool errors, function failures, API call issues
└── export-summary.txt  ← File sizes, line counts, timestamp of export
```

### Searching exported logs for issues

```bash
# All errors across all services
grep -iE "error|warn|critical|exception" ${DATA_DIR}/logs/*.log

# GPU-related issues
grep -i "intel\|gpu\|opencl\|device" ${DATA_DIR}/logs/olama.log

# Web search failures
grep -iE "searxng|timeout|search" ${DATA_DIR}/logs/open-webui.log

# RAG / document issues
grep -iE "embed|chroma|rag|document" ${DATA_DIR}/logs/open-webui.log
```

### Change log verbosity

```bash
# Enable verbose debug logging across all containers (restarts containers automatically)
bash scripts/logs.sh debug-on

# Restore normal logging
bash scripts/logs.sh debug-off
```

---

## Available Models

| Model | Size | Notes |
|---|---|---|
| `llama3.2:1b` | ~770 MB | Fastest, minimal hardware |
| `gemma2:2b` | ~1.6 GB | Google Gemma 2 |
| `llama3.2:3b` | ~2.0 GB | Meta Llama 3.2 |
| `phi3:mini` | ~2.3 GB | Microsoft Phi-3 |
| `codellama:7b` | ~3.8 GB | Code generation |
| `mistral` | **~4.1 GB** | **Recommended starting model** |
| `llama3.1:8b` | ~4.7 GB | High quality, 8B params |

Pull any model:

```bash
docker exec olama ollama pull <model-name>
```

---

## Runtipi App Store

To add Olama to a self-hosted [Runtipi](https://runtipi.io) instance:

### Option A — Add as a custom app store

1. In Runtipi settings → **App Stores**, add:
   ```
   https://github.com/Crashcart/Olama-intelgpu
   ```
2. **Olama (Intel GPU)** will appear in your store.
3. Install it, then pull a model from the terminal once the stack is running:
   ```bash
   docker exec olama ollama pull mistral
   ```

### Option B — Copy files manually

Copy `runtipi/apps/olama-intel-gpu/` into your Runtipi `apps/` directory and refresh the store.

> **Before clicking Install:** SearXNG needs its config file placed at `<APP_DATA_DIR>/data/searxng/settings.yml`. See the app description in Runtipi for the exact `curl` command to place it.

---

## Log Viewer — Web UI (Dozzle)

Open **http://localhost:9999** in your browser for a real-time view of all container logs — no CLI required.

Dozzle shows live, color-coded log streams for `olama`, `open-webui`, `searxng`, and `pipelines` in one tab. Use it to:

- Watch what's happening in real time as you chat or pull a model
- Search and filter log output across all containers at once
- Copy log output to share when reporting an issue

**Dozzle is read-only** — it can only view logs, not control containers.

If you need to share logs for a bug report, open Dozzle, reproduce the issue, and paste the relevant output.

To change the port:

```bash
# In docker/.env
DOZZLE_PORT=9999
```

---

## Intel GPU Verification

After pulling a model, confirm the Intel GPU is being used:

```bash
# Check Intel GPU utilization in real time
sudo intel_gpu_top

# Verify OpenCL device is visible inside the container
docker exec olama clinfo | grep -i "device name"

# Run a quick inference and check for Intel references in output
docker exec olama ollama run mistral "hello" 2>&1 | grep -i intel || true
```

---

## Directory Structure

```
Olama-intelgpu/
├── docker/
│   ├── Dockerfile               # Multi-stage: copies Ollama binary from Docker Hub, installs Intel oneAPI GPU drivers
│   ├── docker-compose.yml       # Full stack: olama + open-webui + searxng + pipelines + dozzle
│   └── searxng/
│       └── settings.yml         # SearXNG config (auto-mounted read-only into container)
├── scripts/
│   ├── install.sh               # One-command full-stack installer
│   ├── pull-model.sh            # Interactive model downloader
│   └── logs.sh                  # Log viewer, exporter, debug mode toggle
├── runtipi/
│   └── apps/
│       └── olama-intel-gpu/
│           ├── config.json          # Runtipi app metadata & form fields
│           ├── docker-compose.yml   # Runtipi-compatible compose
│           └── metadata/
│               └── description.md  # App store description
└── .env.example                 # All configurable environment variables

${DATA_DIR}/                     # Host storage (default /opt/olama)
├── models/                      # AI CORE    — Ollama model weights
├── webui/                       # INTERFACE  — chat history, RAG, settings
├── searxng/                     # SEARCH     — SearXNG runtime state
├── pipelines/                   # PIPELINES  — custom tool/function .py scripts
└── logs/                        # LOGS       — exported by scripts/logs.sh
```
