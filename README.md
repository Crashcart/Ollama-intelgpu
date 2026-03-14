# Olama — Intel GPU Docker

Run [Ollama](https://ollama.com) in Docker with Intel GPU acceleration.
Supports **Intel Arc**, **Iris Xe**, and **integrated Intel graphics** via Intel's oneAPI runtime.

> **Minimal by design** — no LLM models are bundled in the image.
> **Mistral** (~4.1 GB) is pulled automatically on first start as the default model.

---

## Prerequisites

Before installing, make sure you have:

- **Docker** — [Install Docker Engine](https://docs.docker.com/engine/install/)
- **Docker Compose** — included with Docker Desktop; for Linux servers install the [Compose plugin](https://docs.docker.com/compose/install/linux/)
- **Intel GPU** — any system with Intel Arc, Iris Xe, or integrated Intel graphics running Linux
  - Confirm your GPU is visible: `ls /dev/dri/renderD*` (should list at least one device)

---

## Method 1 — One-Command CLI Install (Recommended)

This is the fastest way to get running. The script handles everything: directory setup, compose file generation, image pull, and container start.

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

Once the container is running, download mistral (default) or any model you want:

```bash
# Interactive menu — press Enter to accept mistral as the default
bash scripts/pull-model.sh

# Or pull a specific model directly
bash scripts/pull-model.sh mistral
```

**Step 3 — Chat**

```bash
# Interactive chat in the terminal
docker exec -it olama ollama run mistral

# Or send a single prompt via the API
curl http://localhost:11434/api/generate \
  -d '{"model": "mistral", "prompt": "Hello!", "stream": false}'
```

**Optional — Custom install options**

Download the script first if you want to pass flags before running:

```bash
curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/install.sh -o install.sh

# Available flags:
#   --port      Host port (default: 11434)
#   --data-dir  Where to store models and config (default: /opt/olama)
#   --version   Ollama image tag to use (default: latest)
bash install.sh --port 11434 --data-dir /opt/olama --version latest
```

---

## Method 2 — Docker Compose (Manual)

Use this method if you prefer to manage the compose file yourself or want to build the image locally with Intel GPU drivers baked in.

**Step 1 — Clone the repository**

```bash
git clone https://github.com/Crashcart/Olama-intelgpu.git
cd Olama-intelgpu
```

**Step 2 — (Optional) Configure environment**

Copy the example env file and edit any values you want to change:

```bash
cp .env.example docker/.env
# Edit docker/.env to change OLLAMA_PORT, OLLAMA_VERSION, etc.
```

Key variables:

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_PORT` | `11434` | Host port Olama listens on |
| `OLLAMA_VERSION` | `latest` | Ollama image tag |
| `OLLAMA_DATA_DIR` | `/opt/olama` | Host path for model storage |
| `OLLAMA_PULL_MODEL` | `mistral` | Model to auto-pull on first start |

**Step 3 — Build and start**

```bash
cd docker

# First run: build the image (includes Intel GPU drivers) then start
docker compose up --build -d

# Subsequent starts (image already built):
docker compose up -d
```

The image build takes a few minutes the first time — it installs Intel oneAPI GPU drivers on top of the Ollama base image.

**Step 4 — Verify the container is running**

```bash
docker ps | grep olama
# Should show the olama container with port 11434 mapped

# Check Olama is responding
curl http://localhost:11434/api/tags
```

**Step 5 — Pull a model**

The container starts without any model. Pull one now:

```bash
# Pull mistral (recommended — well-rounded general model, ~4.1 GB)
docker exec -it olama ollama pull mistral

# Or use the helper script from the repo root
bash scripts/pull-model.sh
```

**Step 6 — Chat**

```bash
# Interactive chat
docker exec -it olama ollama run mistral

# Single prompt via API
curl http://localhost:11434/api/generate \
  -d '{"model": "mistral", "prompt": "Hello!", "stream": false}'
```

**Stopping and removing**

```bash
# Stop the container (models are preserved in the named volume)
docker compose down

# Stop and delete the model volume (removes all downloaded models)
docker compose down -v
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
| `mistral` | **~4.1 GB** | **Default — best all-around** |
| `llama3.1:8b` | ~4.7 GB | High quality, 8B params |

Pull any model with:

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
│   ├── Dockerfile           # Builds Ollama + Intel oneAPI GPU drivers
│   └── docker-compose.yml   # Standalone compose for manual use
├── scripts/
│   ├── install.sh           # One-command CLI installer
│   └── pull-model.sh        # Interactive model downloader (default: mistral)
├── runtipi/
│   └── apps/
│       └── olama/
│           ├── config.json          # Runtipi app metadata & form fields
│           ├── docker-compose.yml   # Runtipi-compatible compose
│           └── metadata/
│               └── description.md  # App store description
└── .env.example             # All configurable environment variables
```
