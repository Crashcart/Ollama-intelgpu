## Olama — Ollama LLM Stack for Intel GPUs

A complete, self-hosted AI stack purpose-built for **Intel Arc, Iris Xe, and integrated Intel GPUs**. Chat with large language models in your browser with all the features you'd expect from a modern AI platform — without sending a single byte to the cloud.

### What's in the box

| Container | Role |
|---|---|
| **Olama** | Ollama LLM engine with Intel GPU drivers (oneAPI/SYCL) pre-installed |
| **Open WebUI** | Browser-based chat interface at your configured port |
| **SearXNG** | Private web search engine (internal, no exposed port) |
| **Pipelines** | Python function/tool runtime for custom tools and code execution |
| **Dozzle** | Real-time web log viewer for all containers (port 45213 by default) |

### Full capability list

- **Chat** — Conversation with any Ollama-compatible model (Mistral, LLaMA, Phi, CodeLlama, Gemma, etc.)
- **Vision / Multimodal** — Upload images to chat with vision models (LLaVA, MiniCPM-V, BakLLaVA)
- **Tool / Function Calling** — Models that support tools get automatic tool use (Mistral, LLaMA 3.1+)
- **RAG (Document Q&A)** — Upload PDF, DOCX, TXT files or paste URLs. Open WebUI chunks, embeds, and retrieves context automatically
- **YouTube Transcripts** — Paste a YouTube URL to load its transcript as chat context
- **Web Search** — Toggle per message; uses the built-in SearXNG instance to search the web privately
- **Voice Input (STT)** — Click the microphone icon to dictate using faster-whisper (runs locally, no external API)
- **Voice Output (TTS)** — Click the speaker icon to hear responses read aloud (browser-native, or Kokoro pipeline for higher quality)
- **Image Generation** — Disabled by default; enable when you add a Stable Diffusion (AUTOMATIC1111 or ComfyUI) service
- **Pipelines** — Drop Python scripts into the pipelines directory to add custom tools, filters, rate limiting, usage monitoring, and code execution
- **Log Viewer** — Open `http://<host>:45213` to see live, color-coded logs from all containers in your browser — no CLI needed
- **Modelfiles** — Create custom model personas with system prompts and parameters from the UI
- **Prompt Presets** — Save and share conversation templates
- **Arena Mode** — Compare two models side by side on the same prompt
- **Multi-User Auth** — Optional login system; first user becomes admin
- **Community Sharing** — Share custom prompts to the Open WebUI community hub

### Multi-app queuing

Multiple apps (Open WebUI, Cursor, VS Code extensions, custom scripts) can all connect to the Ollama API on port 11434 simultaneously. Requests are natively queued — no proxy needed. Configure parallel slots and queue depth from the app settings.

### Intel GPU requirement

This app requires:
- An Intel GPU visible at `/dev/dri` (Arc discrete, Iris Xe, or Intel integrated graphics)
- The host kernel must have the Intel GPU driver loaded (`i915` or `xe`)

The Olama container bundles Intel OpenCL and Level Zero drivers so the GPU is used automatically. If no Intel GPU is found, inference falls back to CPU.

### Pre-built image

The Olama container uses a custom image with Intel GPU drivers. Before installing, build and push it:

```bash
git clone https://github.com/Crashcart/Olama-intelgpu.git
cd Olama-intelgpu/docker
docker build -t ghcr.io/crashcart/olama-intel-gpu:latest .
docker push ghcr.io/crashcart/olama-intel-gpu:latest
```

Or use the pre-built image from the Crashcart GitHub Container Registry if available.

### First-time setup — SearXNG config

SearXNG requires a `settings.yml` before it will start. Copy it from the repo **before** clicking Install in Runtipi:

```bash
# Replace <APP_DATA_DIR> with the path Runtipi shows for this app's data
mkdir -p <APP_DATA_DIR>/data/searxng
curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/docker/searxng/settings.yml \
  -o <APP_DATA_DIR>/data/searxng/settings.yml
```

Without this file, SearXNG will crash and Open WebUI will not start (it waits for SearXNG to become healthy before launching).

### Data storage

All data is stored under Runtipi's app data directory:

| Path | Contents |
|---|---|
| `data/models/` | Ollama model weights (can grow to 100+ GB) |
| `data/webui/` | Chat history, uploaded docs, embeddings, user settings |
| `data/searxng/` | SearXNG config (settings.yml) |
| `data/pipelines/` | Pipeline scripts (.py files) |

Back up the entire app data directory to export everything.
