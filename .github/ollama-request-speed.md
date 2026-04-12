# Ollama Request Speed Guide

> **Context:** "Ollama is still the easiest way to start local LLMs, but it's the worst way to keep running them."
>
> This guide documents the root causes of slow Ollama responses and the concrete settings applied to this stack to fix them.

---

## The Problem: Cold-Start Latency

By default Ollama unloads a model from VRAM after **5 minutes of idle**. The next request must reload the model from disk before any tokens can be generated. On a typical NVMe drive this adds:

| Model Size | Cold-Start Penalty |
|------------|--------------------|
| ~1B params | 3–8 seconds        |
| ~7B params | 10–20 seconds      |
| ~13B params | 20–45 seconds     |

For interactive use (chat, IDE extensions) this latency is frustrating. For automated pipelines it breaks SLA assumptions entirely.

---

## Fix 1 — Keep the Model in VRAM (biggest impact)

**Variable:** `OLLAMA_KEEP_ALIVE`

| Value | Effect |
|-------|--------|
| `5m`  | Ollama default — model evicted after 5 min idle |
| `60m` | Reasonable middle-ground for shared servers |
| `-1`  | **Keep forever** — no cold-starts, best TTFT |
| `0`   | Evict immediately after each request (worst latency, max VRAM savings) |

**This stack defaults to `-1`.**  Change in `docker/.env` if you need VRAM back for other workloads.

```dotenv
OLLAMA_KEEP_ALIVE=-1
```

### API-Level Override

Client libraries and frontends can send `keep_alive` per-request, which **overrides the server setting**. If Open WebUI or an IDE extension is sending `keep_alive: 5m` the model still gets evicted regardless of the server config. The heartbeat script below protects against this.

---

## Fix 2 — Flash Attention (2–3× faster inference)

**Variable:** `OLLAMA_FLASH_ATTENTION=1`

Flash Attention is an optimised attention algorithm that computes attention in tiles rather than materialising the full attention matrix. Benefits:
- 2–3× speedup during inference
- Lower peak VRAM usage
- No quality change — it is a numerically equivalent algorithm

Ollama falls back silently to the standard kernel if the model or runtime doesn't support it, so there is **no downside to enabling it**.

**This stack defaults to `1` (enabled).**

```dotenv
OLLAMA_FLASH_ATTENTION=1
```

---

## Fix 3 — KV-Cache Quantization (more context fits on-GPU)

**Variable:** `OLLAMA_KV_CACHE_TYPE`

The KV cache stores intermediate attention scores as tokens are processed. It grows with context length and can exhaust VRAM on long conversations or RAG workloads. Quantising it reduces VRAM usage significantly.

| Value  | VRAM vs f16 | Accuracy   | Recommendation |
|--------|-------------|------------|----------------|
| `f16`  | 100%        | Best       | Default         |
| `q8_0` | ~50%        | Negligible loss | **Recommended** |
| `q4_0` | ~25%        | Slight loss | Low-VRAM systems |

**This stack defaults to `q8_0`.**

```dotenv
OLLAMA_KV_CACHE_TYPE=q8_0
```

---

## Fix 4 — Heartbeat Script (safety net against eviction)

Even with `KEEP_ALIVE=-1`, a client sending `keep_alive: 0` or `5m` in the request body will evict the model. The `scripts/keep-alive.sh` script sends a silent ping every 4 minutes to keep the model resident regardless of client behaviour.

```bash
# Run in the background (Ctrl-C to stop)
bash scripts/keep-alive.sh

# Pin a specific model
bash scripts/keep-alive.sh --model llama3.2:1b

# Custom interval (seconds)
bash scripts/keep-alive.sh --interval 120
```

Run `ollama ps` to verify the model shows as loaded:

```bash
docker exec ${PROJECT_PREFIX:-olama-intelgpu}-ollama ollama ps
```

---

## Summary of Settings Applied

| Variable | Old Default | New Default | Why Changed |
|----------|-------------|-------------|-------------|
| `OLLAMA_KEEP_ALIVE` | `5m` | `-1` | Eliminates cold-start penalty |
| `OLLAMA_FLASH_ATTENTION` | *(not set)* | `1` | 2–3× faster inference |
| `OLLAMA_KV_CACHE_TYPE` | *(not set / f16)* | `q8_0` | ~50% VRAM reduction, negligible quality loss |

All values are tunable via `docker/.env` — see `.env.example` for full documentation.

---

## Diagnosing Slow Requests

```bash
# See which models are currently loaded in VRAM
docker exec ${PROJECT_PREFIX:-olama-intelgpu}-ollama ollama ps

# Tail Ollama logs — shows model load/unload events and per-request timing
docker logs -f ${PROJECT_PREFIX:-olama-intelgpu}-ollama

# Enable debug logging for detailed GPU and token generation traces
bash scripts/logs.sh debug-on
```

A log line like `msg="loading model"` means a cold-start occurred. If you see it after every request (or after a short idle), check your `OLLAMA_KEEP_ALIVE` setting and look for client-side `keep_alive` overrides.

---

## References

- [Ollama is still the easiest way to start local LLMs, but it's the worst way to keep running them](https://www.msn.com/en-us/technology/artificial-intelligence/ollama-is-still-the-easiest-way-to-start-local-llms-but-it-s-the-worst-way-to-keep-running-them/ar-AA20tY9P)
- [Configure Ollama Keep-Alive: Memory Management for Always-On Models](https://markaicode.com/ollama-keep-alive-memory-management/)
- [Bringing K/V Context Quantisation to Ollama](https://smcleod.net/2024/12/bringing-k/v-context-quantisation-to-ollama/)
- [Ollama Performance Tuning: Getting Maximum Speed from Local LLMs](https://dasroot.net/posts/2026/01/ollama-performance-tuning-gpu-acceleration-model-quantization/)
- [Ollama FAQ — Environment Variables](https://docs.ollama.com/faq)
