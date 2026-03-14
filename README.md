# Olama — Intel GPU Docker

Run [Ollama](https://ollama.com) in Docker with Intel GPU acceleration.
Supports **Intel Arc**, **Iris Xe**, and **integrated Intel graphics** via Intel's oneAPI runtime.

> **Minimal by design** — no LLM models are bundled in the image.
> **Mistral** (~4.1 GB) is pulled automatically on first start as the default model.

---

## What's Included

| Container | Purpose | Default Port |
|---|---|---|
| `olama` | Ollama LLM engine with Intel GPU passthrough | `11434` |
| `open-webui` | Chat interface — talk to the AI in your browser | `3000` |
| `searxng` | Self-hosted search engine for web browsing | internal only |

**Web search is off by default.** SearXNG only runs searches when you explicitly toggle the web search button in the chat UI — it never runs in the background on its own.

---

## Prerequisites

Before installing, make sure you have:

- **Docker** — [Install Docker Engine](https://docs.docker.com/engine/install/)
- **Docker Compose** — included with Docker Desktop; for Linux servers install the [Compose plugin](https://docs.docker.com/compose/install/linux/)
- **Intel GPU** — any system with Intel Arc, Iris Xe, or integrated Intel graphics running Linux
  - Confirm your GPU is visible: `ls /dev/dri/renderD*` (should list at least one device)

---

## Method 1 — One-Command CLI Install

This is the fastest way to get running. The script handles everything: directory setup, compose file generation, image pull, and container start.

> **Note:** The CLI installer starts only the `olama` engine. For the full stack (chat UI + web search), use Method 2.

**Step 1 — Run the installer**

```bash
curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/install.sh | bash
```

The installer will:
1. Check that Docker and Docker Compose are available
2. Warn you if no Intel GPU render node (`/dev/dri/renderD*`) is found
3. Create `/opt/olama/` to store models and config
4. Pull the `ollama/ollama` image (~1 GB, no model included)
5. Start the container and wait until it's ready

**Step 2 — Pull a model**

```bash
# Interactive menu — press Enter to accept mistral as the default
bash scripts/pull-model.sh

# Or pull a specific model directly
bash scripts/pull-model.sh mistral
```

**Step 3 — Chat via terminal**

```bash
docker exec -it olama ollama run mistral
```

**Optional — Custom install options**

```bash
curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/install.sh -o install.sh

# Available flags:
#   --port      Host port (default: 11434)
#   --data-dir  Where to store models and config (default: /opt/olama)
#   --version   Ollama image tag to use (default: latest)
bash install.sh --port 11434 --data-dir /opt/olama --version latest
```

---

## Method 2 — Docker Compose (Full Stack — Recommended)

This starts all three containers: the LLM engine, the chat UI, and the web search backend.

**Step 1 — Clone the repository**

```bash
git clone https://github.com/Crashcart/Olama-intelgpu.git
cd Olama-intelgpu
```

**Step 2 — Configure environment**

```bash
cp .env.example docker/.env
```

Open `docker/.env` and change any values you need. The defaults work for most setups:

```env
OLLAMA_PORT=11434    # raw API port
OLLAMA_VERSION=latest
OLLAMA_PULL_MODEL=mistral
WEBUI_PORT=3000      # chat UI port
```

Also open `docker/searxng/settings.yml` and set a unique `secret_key`:

```yaml
server:
  secret_key: "replace-with-a-long-random-string"
```

**Step 3 — Build and start**

```bash
cd docker

# First run: builds the Olama image (Intel GPU drivers) and starts all containers
docker compose up --build -d

# Subsequent starts (image already built):
docker compose up -d
```

The image build takes a few minutes the first time — it installs Intel oneAPI GPU drivers on top of the Ollama base image.

**Step 4 — Open the chat UI**

Open your browser at **http://localhost:3000**

On first load, Open WebUI will connect to Olama automatically. Select **mistral** (or whichever model you pulled) from the model selector at the top.

**Step 5 — Pull a model (first time only)**

The container starts without any model. Pull one from the UI or terminal:

```bash
# From terminal
docker exec -it olama ollama pull mistral

# Or use the helper script from the repo root
bash scripts/pull-model.sh
```

**Step 6 — Enable web search (when you want it)**

Web search is **off by default**. To search the web for a specific question:

1. In the chat bar, click the **magnifying glass icon** (web search toggle)
2. It turns blue — your next message will search the web before answering
3. Click it again to turn web search off

The AI will fetch and summarize relevant search results, then answer your question. SearXNG does not run any searches unless you activate the toggle.

**Stopping and removing**

```bash
# Stop all containers (models and chat history are preserved)
docker compose down

# Stop and delete all data including models and chat history
docker compose down -v
```

---

## How Web Search Works

```
You (toggle ON) → Open WebUI → SearXNG → Public search engines
                                    ↓
                          Results returned to Open WebUI
                                    ↓
                    Open WebUI sends results + your question → Olama (mistral)
                                    ↓
                              AI answers you
```

- **SearXNG is private** — it has no exposed port and is only reachable by Open WebUI inside the Docker network
- **No API keys needed** — SearXNG aggregates results from public search engines
- **You stay in control** — the toggle must be on for any web request to happen

---

## Available Models

| Model | Size | Notes |
|---|---|---|
| `llama3.2:1b` | ~770 MB | Fastest, minimal hardware |
| `gemma2:2b` | ~1.6 GB | Google Gemma 2 |
| `llama3.2:3b` | ~2.0 GB | Meta Llama 3.2 |
| `phi3:mini` | ~2.3 GB | Microsoft Phi-3 |
| `codellama:7b` | ~3.8 GB | Code generation |
| `mistral` | **~4.1 GB** | **Default — best all-around** |
| `llama3.1:8b` | ~4.7 GB | High quality, 8B params |

Pull any model:

```bash
docker exec -it olama ollama pull <model-name>
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
3. Install it — `mistral` is pulled automatically on first start.

### Option B — Copy files manually

Copy `runtipi/apps/olama/` into your Runtipi `apps/` directory and refresh the store.

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
│   ├── Dockerfile               # Builds Ollama + Intel oneAPI GPU drivers
│   ├── docker-compose.yml       # Full stack: olama + open-webui + searxng
│   └── searxng/
│       └── settings.yml         # SearXNG config (enable JSON API, set secret key)
├── scripts/
│   ├── install.sh               # One-command CLI installer (olama engine only)
│   └── pull-model.sh            # Interactive model downloader (default: mistral)
├── runtipi/
│   └── apps/
│       └── olama/
│           ├── config.json          # Runtipi app metadata & form fields
│           ├── docker-compose.yml   # Runtipi-compatible compose
│           └── metadata/
│               └── description.md  # App store description
└── .env.example                 # All configurable environment variables
```
