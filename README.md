# Ollama — Intel GPU Docker

Run [Ollama](https://ollama.com) in Docker with Intel GPU acceleration.
Supports **Intel Arc**, **Iris Xe**, and **integrated Intel graphics** via Intel's oneAPI runtime.

> **Unified portal at `http://localhost:45200`** — Chat, Model Manager, and Log Viewer all in one browser tab. No model is bundled; open the **Models** tab to download one.

---

## What's Included

| Container | Service | Purpose | Port |
|---|---|---|---|
| `ollama-portal` | `portal` | **Unified web portal** — Chat, Models, and Logs in one tab | `45200` |
| `ollama` | `ollama` | Ollama LLM engine — Intel GPU passthrough | `11434` |
| `ollama-open-webui` | `open-webui` | Browser chat UI | `45213` |
| `ollama-model-manager` | `model-manager` | Model search, download, and delete UI | `45214` |
| `ollama-searxng` | `searxng` | Self-hosted web search backend | internal |
| `ollama-pipelines` | `pipelines` | Python tool/function runtime for Open WebUI | internal |
| `ollama-dozzle` | `dozzle` | Real-time web log viewer for all containers | `9999` |

All containers carry the `ollama-` prefix so they are easy to identify in `docker ps` alongside other stacks.

**The portal is the recommended bookmark.** Open `http://localhost:45200` once and you can reach Chat, Models, and Logs from the top nav without switching tabs or ports. Each service is still accessible directly on its own port if you prefer.

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

The fastest way to get the full stack running. Clones the repo, installs Docker if needed, builds the Intel GPU image, creates data directories, writes a `.env`, and starts all 7 containers. Safe to run over SSH — closing the terminal will not stop the install.

**Step 1 — Run the installer**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/install.sh)
```

The installer will:

1. Install Docker and Docker Compose if they are not already present
2. Warn if no Intel GPU render node (`/dev/dri/renderD*`) is found
3. Clone the repo to `/opt/ollama-stack/`
4. Create data directories under `/opt/ollama/`
5. Write `docker/.env` (or update it if one already exists)
6. **Check all 5 ports for conflicts** — if any port is already in use by another process, print what is using it and ask for an alternative before continuing
7. Open the host-facing ports in ufw or firewalld for LAN access
8. Build the Ollama Intel GPU image (~5 min first run — installs Intel oneAPI drivers)
9. Pull images for any containers that do not already exist; skip existing ones
10. Start all 7 containers
11. Wait until Ollama and Open WebUI are healthy

The installer is **idempotent** — safe to re-run after an upgrade or a failed run. It updates ports and GPU group IDs in an existing `.env` without touching your custom settings (API keys, model names, feature flags, etc.).

**The installer survives SSH disconnects.** All output is also logged to `/tmp/ollama-install.log`:

```bash
tail -f /tmp/ollama-install.log
```

**Step 2 — Download a model**

No model is bundled — download one after the stack is running. The easiest way is the unified portal:

Open **http://localhost:45200** → click the **Models** tab — browse the catalog, filter by category, and click **Download**.

Or go directly to the Model Manager at **http://localhost:45214**.

Or from the CLI:

```bash
# Interactive menu
bash /opt/ollama-stack/scripts/pull-model.sh

# Or pull directly
docker exec ollama ollama pull mistral
docker exec ollama ollama pull llama3.2:3b
```

**Step 3 — Open the portal**

Open **http://localhost:45200** — the unified portal loads with Chat, Models, and Logs all accessible from the top nav bar. Bookmark this single URL.

To access from another device, use the host's IP or hostname — the installer prints it at the end:

```
From other devices on your network:
  Portal (all-in-one) →  http://boris.local:45200   ← bookmark this
  Chat UI             →  http://boris.local:45213
  Model Manager       →  http://boris.local:45214
  Ollama API          →  http://boris.local:11434
  Log viewer          →  http://boris.local:9999
```

> **ZeroTier / VPN users** — `.local` (mDNS) hostnames are link-local and do
> not propagate over ZeroTier or most VPN tunnels.  Use the host's **ZeroTier
> IP address** instead of `boris.local`:
> ```
> Portal  →  http://192.168.x.x:45200
> Ollama  →  http://192.168.x.x:11434
> ```
> All services bind to `0.0.0.0`, so they are reachable on every interface
> including ZeroTier.  The portal resolves service URLs from the hostname your
> browser used to reach it, so navigating via the IP makes everything work.

The stack binds to `0.0.0.0` so it is reachable on **all network interfaces and subnets** the host belongs to. See [Multi-Subnet Access](#multi-subnet-access) if you need to restrict which subnets can connect.

---

## Installer Options

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/install.sh) [OPTIONS]
```

| Flag | Default | Purpose |
|---|---|---|
| `--data-dir DIR` | `/opt/ollama` | Where to store models, chat history, logs |
| `--port PORT` | `11434` | Host port for the Ollama API |
| `--webui-port PORT` | `45213` | Host port for the Open WebUI chat UI |
| `--version TAG` | `latest` | Ollama image tag |
| `--branch NAME` | auto-detected | Git branch to clone (`main` → `master` fallback) |
| `--recreate` | off | Force-recreate all containers (pull latest images, replace existing) |
| `--allow-from CIDR[,CIDR]` | any | Firewall: restrict UI ports to specific source subnets |

**Example — allow access only from two subnets:**

```bash
bash <(curl -fsSL .../install.sh) --allow-from 192.168.1.0/24,10.5.0.0/16
```

**Example — custom ports and data directory:**

```bash
bash <(curl -fsSL .../install.sh) \
  --port 11434 \
  --webui-port 45213 \
  --data-dir /mnt/nas/ollama
```

**Example — force-recreate all containers to pick up latest images:**

```bash
bash scripts/install.sh --recreate
```

---

## Multi-Subnet Access

The stack is designed to work across subnets out of the box:

- **Docker** binds every service to `0.0.0.0` (all host interfaces)
- **Firewall** — the installer opens the 5 UI ports from *any* source by default (`ufw allow PORT/tcp`). Use `--allow-from CIDR[,CIDR...]` to restrict instead:

  ```bash
  # Allow from two different subnets / VLANs
  bash <(curl -fsSL .../install.sh) --allow-from 192.168.1.0/24,10.10.0.0/16
  ```

  The `ALLOW_FROM` value is stored in `docker/.env` so `uninstall.sh` removes exactly the rules that were added.

- **Ollama API origins** — Ollama has its own allow-list for direct browser→API calls (`OLLAMA_ORIGINS` in `docker/.env`). The default covers all three RFC-1918 ranges (`192.168.*`, `10.*`, `172.*`) and localhost. If your hosts are on a non-standard range (e.g. Tailscale `100.64.x.x`, corporate VPN), add the prefix to `docker/.env`:

  ```ini
  # docker/.env
  OLLAMA_ORIGINS=http://localhost,https://localhost,http://127.0.0.1,http://192.168.,http://10.,http://172.,http://100.
  ```

  Then restart: `docker compose -f /opt/ollama-stack/docker/docker-compose.yml restart ollama`

- **ZeroTier** — ZeroTier creates a virtual network interface (e.g. `ztXXXXXX`). The stack binds to `0.0.0.0` so it listens on that interface automatically. The only thing to do is use the ZeroTier-assigned IP address instead of the `.local` mDNS hostname, because mDNS does not traverse ZeroTier:

  ```bash
  # Find your ZeroTier IP (shown in ZeroTier Central or via CLI)
  ip addr show | grep zt   # Linux — look for the zt* interface
  ```

  Then access the stack via that IP:
  ```
  http://<zerotier-ip>:45200
  ```

  If you need to open the firewall for the ZeroTier subnet (e.g. `192.168.191.0/24`):
  ```bash
  sudo ufw allow from 192.168.191.0/24 to any port 45200,45213,45214,11434 proto tcp
  ```

  Add the ZeroTier prefix to `OLLAMA_ORIGINS` in `docker/.env` if direct browser→API calls fail:
  ```ini
  OLLAMA_ORIGINS=http://localhost,https://localhost,http://127.0.0.1,http://192.168.,http://10.,http://172.,http://192.168.191.
  ```

> **Note:** Routing between subnets is an infrastructure concern (router/firewall between VLANs). The stack itself has no subnet restrictions once the host firewall is open.

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
DATA_DIR=/opt/ollama
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

# First run: builds the Ollama image and starts all containers
docker compose up --build -d

# Subsequent starts (image already built):
docker compose up -d --no-recreate
```

**Step 4 — Pull a model**

```bash
docker exec ollama ollama pull mistral
# or use the helper
bash scripts/pull-model.sh
```

**Step 5 — Open the portal**

Open **http://localhost:45200** for the unified portal (Chat + Models + Logs in one tab), or go directly to **http://localhost:45213** for just the chat UI.

---

## Uninstalling

Use `scripts/uninstall.sh` to stop and remove the stack. Your data is kept by default — pass `--purge` to also delete models, chat history, and config.

```bash
# Stop and remove containers, images, volumes, networks; keep data
bash /opt/ollama-stack/scripts/uninstall.sh

# Also delete all models, chat history, and config (irreversible)
bash /opt/ollama-stack/scripts/uninstall.sh --purge

# Uninstall from a machine where the repo was never cloned (one-liner)
bash <(curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/uninstall.sh)
```

**Options:**

| Flag | Default | Purpose |
|---|---|---|
| `--data-dir DIR` | `/opt/ollama` | Where data is stored |
| `--install-dir DIR` | `/opt/ollama-stack` | Where stack files are installed |
| `--purge` | off | Also delete the data directory (models, history, config) |
| `--keep-images` | off | Keep Docker images (default: remove all ollama images) |
| `--yes` / `-y` | off | Skip confirmation prompts |

The script:
1. Shows a full list of what will be removed (containers, images, volumes, networks) before asking
2. Stops and removes all 7 Ollama containers (`docker compose down --volumes --remove-orphans`)
3. Removes **all** locally-built images across every tag — `ollama:latest`, `ollama:0.6.2`, etc.
4. Removes any Docker volumes and networks belonging to the stack
5. Removes dangling build layers left over from `docker compose build`
6. Removes firewall rules the installer added
7. Deletes the stack files at `--install-dir`
8. If `--purge`: requires you to type `purge` (not just `y`) to confirm, then deletes `--data-dir`

Public registry images (`open-webui`, `searxng`, `pipelines`, `dozzle`) are always left in place since other stacks may use them — the script prints the exact `docker rmi` command if you want to remove them too.

To also reclaim Docker build cache after uninstalling:
```bash
docker builder prune --all
```

---

## Upgrading Containers

Use `scripts/update.sh` to pull fresh images and rebuild local services:

```bash
# Update open-webui, model-manager, and portal (most common)
bash /opt/ollama-stack/scripts/update.sh

# Update every service including searxng, pipelines, dozzle
bash /opt/ollama-stack/scripts/update.sh --all
```

The script:
1. Pulls the latest registry images (`open-webui`, `searxng`, `pipelines`, `dozzle`)
2. **Rebuilds locally-built images from source** (`model-manager`, `portal`) with `--pull --no-cache`
3. Recreates the updated containers; all data is preserved

> **Always include `portal` in updates.** The portal's diagnostic health-check page is baked into the image at build time. Running `update.sh` ensures it is always in sync with the current `model-manager` API.

To upgrade the entire stack from scratch:

```bash
bash /opt/ollama-stack/scripts/install.sh --recreate
```

**Fixing the "Ollama is running" blank page in Open WebUI:**

This happens when the cached `open-webui` image is stale. Run:

```bash
bash /opt/ollama-stack/scripts/update.sh
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

**Backup (safe — stop first):**

Open WebUI stores its chat history and user accounts in a SQLite database (`${DATA_DIR}/webui/webui.db`) and vector embeddings in ChromaDB (`${DATA_DIR}/webui/chroma.sqlite3`). Copying these files while the containers are running can produce a corrupt backup. Stop the stack first:

```bash
# Stop the stack, copy everything, restart
cd /opt/ollama-stack/docker
docker compose down
rsync -av --progress ${DATA_DIR}/ /mnt/backup/ollama/
docker compose up -d
```

For a live (running-stack) snapshot you can use SQLite's backup command directly:

```bash
# Safe live backup of just the chat database
docker exec ollama-open-webui sqlite3 /app/backend/data/webui.db ".backup /app/backend/data/webui.db.bak"
cp ${DATA_DIR}/webui/webui.db.bak /mnt/backup/ollama/webui.db
```

**Restore:**

1. Stop the stack: `cd /opt/ollama-stack/docker && docker compose down`
2. Copy the backup to `DATA_DIR`: `rsync -av /mnt/backup/ollama/ ${DATA_DIR}/`
3. Start the stack: `docker compose up -d`

**Move to a new machine:**

1. Stop the stack on the old machine and copy `${DATA_DIR}/` to the new machine
2. On the new machine: clone the repo, copy `.env.example` → `docker/.env`, set `DATA_DIR`
3. Run `docker compose up -d --build` — all history and models are immediately available

---

## Logs

```bash
# Container status and disk usage
bash scripts/logs.sh status

# Live tail all containers
bash scripts/logs.sh tail

# Live tail a single container
bash scripts/logs.sh tail ollama
bash scripts/logs.sh tail open-webui

# Show recent logs (last 100 lines)
bash scripts/logs.sh show
bash scripts/logs.sh show ollama 200

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
docker exec ollama clinfo | grep -i "device name"

# Run a quick inference
docker exec ollama ollama run mistral "hello"
```

---

## Unified Portal

The **portal** at `http://localhost:45200` is a lightweight nginx container that wraps all three web interfaces into a single browser tab.

```
┌───────────────────────────────────────────────────────────────┐
│  Ollama Stack  [ Chat ]  [ Models ]  [ Logs ]  [⚠ Crit Issues] │  ← 48 px dark nav bar
├───────────────────────────────────────────────────────────────┤
│                                                               │
│   Active service displayed here via iframe                    │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

- **Chat** — Open WebUI (port 45213)
- **Models** — Model Manager (port 45214)
- **Logs** — Dozzle real-time log viewer (port 9999)
- **Crit Issues** *(red, pulsing — only appears when a service is down)* — Service Health panel

**State is preserved** — switching tabs does not reload the iframe, so your open chat conversation and scroll position survive.

**↗ Open in new tab** — each nav button has a small external-link icon to pop the service out full-screen.

**Status badge** — the top-right corner shows the number of installed models and whether the stack is healthy, polled every 30 seconds.

**Works on any hostname** — the portal resolves service URLs from `window.location.hostname`, so `localhost`, a LAN IP, and a hostname like `boris.local` all work without reconfiguration.

### Service Health panel

When any service stops responding the portal adds a red **Crit Issues** button to the nav bar (pulsing until resolved). Clicking it opens the Service Health panel:

- **Per-service rows** — coloured dot (green/red/yellow), status text, latency, and the URL that was checked shown as a dim sub-line beneath each service.
- **Error detail** — when a service is down, the exact error type and message appear inline (e.g. `ConnectError`, `HTTP 502`, timeout duration).
- **Event log** — a scrollable, timestamped history of every health check run (last 80 entries). Entries are colour-coded: green = ok, red = error, yellow = warning, dim = informational. A **Clear** button wipes the log. Newest entries appear at the top.
- **Copy diagnostic** — generates a plain-text report containing each service's status, URL, latency, and error details, plus the full event log. Copies to clipboard silently on HTTPS; on plain HTTP a modal appears with the text pre-selected so you can hit Ctrl+C.
- **Refresh now** — re-runs all checks immediately without waiting for the 60-second polling interval.

The panel auto-navigates back to Chat once all services recover.

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
                    Open WebUI sends results + question → Ollama
                                    ↓
                              AI answers you
```

- **Private** — SearXNG has no exposed port; only reachable by Open WebUI inside the Docker network
- **No API keys** — aggregates public search engines
- **On-demand** — click the magnifying glass icon in the chat bar to toggle; off by default

---

## Runtipi App Store

> **Standalone vs Runtipi — which should I use?**
>
> | | Standalone (`scripts/install.sh`) | Runtipi |
> |---|---|---|
> | **Ollama image** | Custom-built with Intel oneAPI GPU drivers | Stock `ollama/ollama` image (no Intel GPU acceleration) |
> | **HTTPS** | Plain HTTP only (see Issue #42 for proxy guide) | Automatic via Traefik reverse proxy |
> | **Unified portal** | Included at `:45200` | Not included |
> | **Scripts (`logs.sh` etc.)** | Fully supported | **Not compatible** — standalone scripts only |
> | **Install method** | One-liner curl or local clone | Runtipi app store UI |
>
> Use **Standalone** if you have an Intel GPU and want GPU-accelerated inference.
> Use **Runtipi** if you are already running Runtipi and do not need Intel GPU passthrough.

> **Note for Runtipi users:** The `scripts/` directory (`logs.sh`, `update.sh`, `pull-model.sh`, etc.) is designed for the standalone installation only. Container names differ in Runtipi and these scripts will not find them. Use Runtipi's own log viewer and management UI to manage the app.

### Option A — Add as a custom app store

1. In Runtipi settings → **App Stores**, add:
   ```
   https://github.com/Crashcart/Olama-intelgpu
   ```
2. **Ollama (Intel GPU)** will appear in your store.
3. Install it, then pull a model:
   ```bash
   docker exec ollama ollama pull mistral
   ```

### Option B — Copy files manually

Copy `runtipi/apps/ollama-intel-gpu/` into your Runtipi `apps/` directory and refresh the store.

> **Before clicking Install:** SearXNG needs its config placed at `<APP_DATA_DIR>/data/searxng/settings.yml`. See the app description in Runtipi for the exact command.

---

## Directory Structure

```
Olama-intelgpu/
├── docker/
│   ├── Dockerfile               # Ollama + Intel oneAPI GPU drivers
│   ├── docker-compose.yml       # Full stack: portal + ollama + open-webui + model-manager + searxng + pipelines + dozzle
│   ├── portal/
│   │   ├── Dockerfile           # nginx:alpine + gettext (envsubst)
│   │   ├── nginx.conf           # Static file server on port 8080
│   │   ├── entrypoint.sh        # Injects port vars into HTML template at container start
│   │   └── index.html.template  # Single-page portal shell (iframes + dark nav)
│   ├── model-manager/
│   │   ├── Dockerfile           # Python 3.11 slim + FastAPI
│   │   ├── main.py              # API proxy + model catalog
│   │   └── static/index.html   # Browser UI
│   └── searxng/
│       └── settings.yml         # SearXNG config (auto-mounted read-only)
├── scripts/
│   ├── install.sh               # One-command full-stack installer
│   ├── uninstall.sh             # Remove containers, images, firewall rules; optionally purge data
│   ├── update.sh                # Pull fresh images and recreate UI containers
│   ├── pull-model.sh            # Interactive model downloader (CLI)
│   └── logs.sh                  # Log viewer, exporter, debug mode toggle
├── runtipi/
│   └── apps/
│       └── ollama-intel-gpu/
│           ├── config.json
│           ├── docker-compose.yml
│           └── metadata/
│               └── description.md
└── .env.example                 # All configurable environment variables

${DATA_DIR}/                     # Host storage (default /opt/ollama)
├── models/                      # Ollama model weights
├── webui/                       # Chat history, RAG, settings
├── searxng/                     # SearXNG runtime state
├── pipelines/                   # Custom tool/function .py scripts
└── logs/                        # Exported by scripts/logs.sh
```
