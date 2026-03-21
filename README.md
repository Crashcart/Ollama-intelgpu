# Olama — Intel GPU Docker

Run [Ollama](https://ollama.com) in Docker with Intel GPU acceleration.
Supports **Intel Arc**, **Iris Xe**, and **integrated Intel graphics** via Intel's oneAPI runtime.

> **No models are bundled.** After starting, open the **Model Manager** at `http://localhost:45214` to search, download, and delete models from your browser — no CLI needed.

---

## What's Included

| Container | Service | Purpose | Port |
|---|---|---|---|
| `olama` | `olama` | Ollama LLM engine — Intel GPU passthrough | `11434` |
| `olama-open-webui` | `open-webui` | Browser chat UI | `45213` |
| `olama-model-manager` | `model-manager` | Model search, download, and delete UI | `45214` |
| `olama-searxng` | `searxng` | Self-hosted web search backend | internal |
| `olama-pipelines` | `pipelines` | Python tool/function runtime for Open WebUI | internal |
| `olama-dozzle` | `dozzle` | Real-time web log viewer for all containers | `9999` |

All containers carry the `olama-` prefix so they are easy to identify in `docker ps` alongside other stacks.

**Containers are never recreated by default.** On re-runs the installer skips any container that already exists — your settings and history are never disturbed. Pass `--recreate` to force a fresh rebuild of every container.

**Web search is off by default.** SearXNG only runs searches when you click the web search toggle in the chat UI.

**Pipelines** adds custom tools, code execution, filters, rate limiting, and usage monitoring to Open WebUI. Drop any `.py` file into `${DATA_DIR}/pipelines/` to add new capabilities.

All data is stored under a single configurable `DATA_DIR` on the host — no anonymous Docker volumes.

---

## Prerequisites

- **Linux** with an Intel GPU (Arc, Iris Xe, or integrated graphics)
  - Confirm the device is visible: `ls /dev/dri/renderD*`
- **Docker** and **Docker Compose** — the installer will install them automatically if they are missing

---

## Method 1 — One-Command Installer

The fastest way to get the full stack running. Clones the repo, installs Docker if needed, builds the Intel GPU image, creates data directories, writes a `.env`, and starts all 6 containers. Safe to run over SSH — closing the terminal will not stop the install.

**Step 1 — Run the installer**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/install.sh)
```

The installer will:

1. Install Docker and Docker Compose if they are not already present
2. Warn if no Intel GPU render node (`/dev/dri/renderD*`) is found
3. Clone the repo to `/opt/olama-stack/`
4. Create data directories under `/opt/olama/`
5. Write `docker/.env` (or update it if one already exists)
6. Open the three host-facing ports in ufw or firewalld for LAN access
7. Build the Ollama Intel GPU image (~5 min first run — installs Intel oneAPI drivers)
8. Pull images for any containers that do not already exist; skip existing ones
9. Start all 6 containers
10. Wait until Ollama and Open WebUI are healthy

The installer is **idempotent** — safe to re-run after an upgrade or a failed run. It updates ports and GPU group IDs in an existing `.env` without touching your custom settings (API keys, model names, feature flags, etc.).

**The installer survives SSH disconnects.** All output is also logged to `/tmp/olama-install.log`:

```bash
tail -f /tmp/olama-install.log
```

**Step 2 — Download a model**

No model is bundled — download one after the stack is running. The easiest way is the Model Manager web UI:

Open **http://localhost:45214** — browse the catalog, filter by category, and click **Download**.

Or from the CLI:

```bash
# Interactive menu
bash /opt/olama-stack/scripts/pull-model.sh

# Or pull directly
docker exec olama ollama pull mistral
docker exec olama ollama pull llama3.2:3b
```

**Step 3 — Open the chat UI**

Open **http://localhost:45213** and select the model you pulled.

To access from another device on the same network, use the host's IP — the installer prints it at the end:

```
From other devices on your network:
  Chat UI        →  http://192.168.x.x:45213
  Model Manager  →  http://192.168.x.x:45214
  Ollama API     →  http://192.168.x.x:11434
  Log viewer     →  http://192.168.x.x:9999
```

---

## Installer Options

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/install.sh) [OPTIONS]
```

| Flag | Default | Purpose |
|---|---|---|
| `--data-dir DIR` | `/opt/olama` | Where to store models, chat history, logs |
| `--port PORT` | `11434` | Host port for the Ollama API |
| `--webui-port PORT` | `45213` | Host port for the Open WebUI chat UI |
| `--version TAG` | `latest` | Ollama image tag |
| `--branch NAME` | auto-detected | Git branch to clone (`main` → `master` fallback) |
| `--recreate` | off | Force-recreate all containers (pull latest images, replace existing) |

**Example — custom ports and data directory:**

```bash
bash <(curl -fsSL .../install.sh) \
  --port 11434 \
  --webui-port 45213 \
  --data-dir /mnt/nas/olama
```

**Example — force-recreate all containers to pick up latest images:**

```bash
bash scripts/install.sh --recreate
```

---

## Method 2 — Docker Compose (Manual)

**Step 1 — Clone the repository**

```bash
git clone https://github.com/Crashcart/Olama-intelgpu.git
cd Olama-intelgpu
```

**Step 2 — Configure environment**

```bash
cp .env.example docker/.env
```

Open `docker/.env` and set `DATA_DIR` to wherever you have enough space:

```env
DATA_DIR=/opt/olama
OLLAMA_PORT=11434
WEBUI_PORT=45213
```

Create the data directories:

```bash
mkdir -p ${DATA_DIR}/{models,webui,searxng,pipelines,logs}
```

**Step 3 — Build and start**

```bash
cd docker

# First run: builds the Olama image and starts all containers
docker compose up --build -d

# Subsequent starts (image already built):
docker compose up -d --no-recreate
```

**Step 4 — Pull a model**

```bash
docker exec olama ollama pull mistral
# or use the helper
bash scripts/pull-model.sh
```

**Step 5 — Open the chat UI**

Open **http://localhost:45213**.

---

## Upgrading Containers

Use `scripts/update.sh` to pull fresh images for the UI services and fix the "Ollama is running" blank-page issue:

```bash
# Update open-webui and model-manager (most common)
bash /opt/olama-stack/scripts/update.sh

# Update every service including searxng, pipelines, dozzle
bash /opt/olama-stack/scripts/update.sh --all
```

The script pulls the latest images, rebuilds any locally-built containers, and recreates the affected containers. All data is preserved.

To upgrade the entire stack from scratch:

```bash
bash /opt/olama-stack/scripts/install.sh --recreate
```

**Fixing the "Ollama is running" blank page in Open WebUI:**

This happens when the cached `open-webui` image is stale. Run:

```bash
bash /opt/olama-stack/scripts/update.sh
```

---

## Storage — Exportable Data

All persistent data is bind-mounted to the host under `DATA_DIR`. Nothing is locked inside Docker volumes.

```
${DATA_DIR}/
├── models/        ← Ollama model weights          (can reach 100+ GB for large models)
├── webui/         ← Chat history, RAG documents, ChromaDB vector DB, user settings
├── searxng/       ← SearXNG runtime state
├── pipelines/     ← Pipeline .py scripts; drop files here to add tools to Open WebUI
└── logs/          ← Log files exported by scripts/logs.sh
```

**Backup:**

```bash
rsync -av --progress ${DATA_DIR}/ /mnt/backup/olama/
```

**Move to a new machine:**

1. Copy `${DATA_DIR}/` to the new machine
2. Clone the repo, set `DATA_DIR` in `docker/.env`
3. Run `docker compose up -d` — all history and models are immediately available

---

## Logs

```bash
# Container status and disk usage
bash scripts/logs.sh status

# Live tail all containers
bash scripts/logs.sh tail

# Live tail a single container
bash scripts/logs.sh tail olama
bash scripts/logs.sh tail open-webui

# Show recent logs (last 100 lines)
bash scripts/logs.sh show
bash scripts/logs.sh show olama 200

# Show only ERROR / WARN / CRITICAL lines
bash scripts/logs.sh errors

# Export all logs to ${DATA_DIR}/logs/
bash scripts/logs.sh export

# Toggle verbose debug logging
bash scripts/logs.sh debug-on
bash scripts/logs.sh debug-off
```

Open **http://localhost:9999** for the Dozzle web log viewer — real-time, color-coded, no CLI needed.

---

## Intel GPU Verification

```bash
# Real-time GPU utilization
sudo intel_gpu_top

# Verify OpenCL device is visible inside the container
docker exec olama clinfo | grep -i "device name"

# Run a quick inference
docker exec olama ollama run mistral "hello"
```

---

## Model Manager

The **Model Manager** at `http://localhost:45214` lets you:

- Browse a curated catalog of 25+ models
- Filter by category: Text · Code · Vision · Embedding · Fast (&lt;2 GB) · Large
- Search by name or description
- Download any model with real-time progress
- Pull any unlisted model by entering its name (e.g. `llama3.3`, `deepseek-r1:7b`)
- Delete installed models to reclaim disk space

The Installed tab shows every model currently on disk with its size and pull date.

**Recommended first models:**

| Model | Size | Good for |
|---|---|---|
| `llama3.2:1b` | 770 MB | Fast replies, minimal VRAM |
| `llama3.2:3b` | 2.0 GB | Good general model, fast |
| `phi3:mini` | 2.3 GB | Strong reasoning for the size |
| `mistral` | **4.1 GB** | **Solid all-round default** |
| `llama3.1:8b` | 4.7 GB | High quality, everyday tasks |
| `qwen2.5-coder:7b` | 4.7 GB | Code generation |
| `llava:7b` | 4.7 GB | Vision — understands images |

---

## Web Search

```
You (toggle ON) → Open WebUI → SearXNG → Public search engines
                                    ↓
                          Results returned to Open WebUI
                                    ↓
                    Open WebUI sends results + question → Olama
                                    ↓
                              AI answers you
```

- **Private** — SearXNG has no exposed port; only reachable by Open WebUI inside the Docker network
- **No API keys** — aggregates public search engines
- **On-demand** — click the magnifying glass icon in the chat bar to toggle; off by default

---

## Runtipi App Store

### Option A — Add as a custom app store

1. In Runtipi settings → **App Stores**, add:
   ```
   https://github.com/Crashcart/Olama-intelgpu
   ```
2. **Olama (Intel GPU)** will appear in your store.
3. Install it, then pull a model:
   ```bash
   docker exec olama ollama pull mistral
   ```

### Option B — Copy files manually

Copy `runtipi/apps/olama-intel-gpu/` into your Runtipi `apps/` directory and refresh the store.

> **Before clicking Install:** SearXNG needs its config placed at `<APP_DATA_DIR>/data/searxng/settings.yml`. See the app description in Runtipi for the exact command.

---

## Directory Structure

```
Olama-intelgpu/
├── docker/
│   ├── Dockerfile               # Ollama + Intel oneAPI GPU drivers
│   ├── docker-compose.yml       # Full stack: olama + open-webui + model-manager + searxng + pipelines + dozzle
│   ├── model-manager/
│   │   ├── Dockerfile           # Python 3.11 slim + FastAPI
│   │   ├── main.py              # API proxy + model catalog
│   │   └── static/index.html   # Browser UI
│   └── searxng/
│       └── settings.yml         # SearXNG config (auto-mounted read-only)
├── scripts/
│   ├── install.sh               # One-command full-stack installer
│   ├── update.sh                # Pull fresh images and recreate UI containers
│   ├── pull-model.sh            # Interactive model downloader (CLI)
│   └── logs.sh                  # Log viewer, exporter, debug mode toggle
├── runtipi/
│   └── apps/
│       └── olama-intel-gpu/
│           ├── config.json
│           ├── docker-compose.yml
│           └── metadata/
│               └── description.md
└── .env.example                 # All configurable environment variables

${DATA_DIR}/                     # Host storage (default /opt/olama)
├── models/                      # Ollama model weights
├── webui/                       # Chat history, RAG, settings
├── searxng/                     # SearXNG runtime state
├── pipelines/                   # Custom tool/function .py scripts
└── logs/                        # Exported by scripts/logs.sh
```
