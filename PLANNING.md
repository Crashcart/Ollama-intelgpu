# 🗺️ Session Planning
**Date**: 2026-04-09
**Issue**: Speed up Ollama requests — "worst way to keep running them"
**Branch**: copilot/update-github-for-speed-requests

## Approach
Root cause: Ollama's default `KEEP_ALIVE=5m` evicts models from VRAM after 5 minutes of idle.
Each post-eviction request incurs a 10–45 s cold-start penalty (model reload from disk).

Three-lever fix:
1. `OLLAMA_KEEP_ALIVE=-1` — keeps model in VRAM indefinitely (biggest impact)
2. `OLLAMA_FLASH_ATTENTION=1` — 2-3× faster attention computation (no downside)
3. `OLLAMA_KV_CACHE_TYPE=q8_0` — ~50% VRAM reduction via quantised KV cache

Safety net: `scripts/keep-alive.sh` heartbeat pings the model every 4 minutes, preventing
client-side `keep_alive` overrides from evicting it unexpectedly.

Documentation:
- `.github/ollama-request-speed.md` — full guide explaining all optimisations
- `.github/copilot-instructions.md` — updated with performance standards section

## Decisions Log
- [2026-04-09] Changed OLLAMA_KEEP_ALIVE default from `5m` to `-1` — eliminates cold-start
- [2026-04-09] Added OLLAMA_FLASH_ATTENTION=1 — safe default, falls back silently if unsupported
- [2026-04-09] Added OLLAMA_KV_CACHE_TYPE=q8_0 — best balance of VRAM savings vs quality
- [2026-04-09] Created scripts/keep-alive.sh — protects against client-side eviction overrides
- [2026-04-09] Created .github/ollama-request-speed.md — documents all speed levers for future agents
- [2026-04-06] Set default PROJECT_PREFIX to `olama-intelgpu` (matches GitHub repo name, lowercase with hyphens for Docker compatibility)
- [2026-04-06] Container naming: `${PROJECT_PREFIX}-[service]`
- [2026-04-06] deploy.sh sits alongside install.sh
- [2026-04-07] CRITICAL fix: Open WebUI /health endpoint used, RETRIES 200, auto-pull llama3.2:1b
- [2026-04-08] Set DEFAULT_MODELS=llama3.2:1b in .env.example

## Open Questions
- [ ] Should image names also use PROJECT_PREFIX?
- [ ] Should deploy.sh eventually replace install.sh as the primary entry point?
