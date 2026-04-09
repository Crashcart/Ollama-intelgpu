# 🗺️ Session Planning
**Date**: 2026-04-09
**Issue**: docker keeps rebooting (model-manager restart loop)
**Branch**: copilot/fix-docker-keeos-rebooting
**Tier**: TIER 1 — CRITICAL (production crash)

## Approach
Root cause: `docker/model-manager/Dockerfile` was missing `COPY models.json .`.
`main.py` reads `models.json` at module level (`CATALOG = json.loads(_CATALOG_PATH.read_text())`).
When the file was absent in the container, uvicorn failed to import the app, the process exited with
a non-zero code, and Docker's `restart: unless-stopped` policy caused an infinite restart loop.

Fix: add a single line `COPY models.json .` to the Dockerfile, directly after `COPY main.py .`.

## Decisions Log
- [2026-04-06] Set default PROJECT_PREFIX to `olama-intelgpu` (matches GitHub repo name, lowercase with hyphens for Docker compatibility)
- [2026-04-06] Container naming: `${PROJECT_PREFIX}-ollama`, `${PROJECT_PREFIX}-open-webui`, etc. (hyphen-separated as specified in TDR)
- [2026-04-06] Image names (`ollama:latest`, `ollama-model-manager:latest`, etc.) left unchanged — only `container_name:` is prefixed, reducing scope of change
- [2026-04-06] deploy.sh sits alongside install.sh (not replacing it) — as owner said "you decide" on whether it replaces install.sh
- [2026-04-06] Port conflict coverage: all host-exposed ports checked (OLLAMA, WEBUI, MODEL_MANAGER, PORTAL, GHOST_RUNNER, MEMORY, FILE_CATALOG, DOZZLE); internal-only services skipped
- [2026-04-06] install.sh preserves user-set PROJECT_PREFIX on re-run (reads from .env before stamping)
- [2026-04-06] Default model changed from `mistral` (~4.1 GB) to `llama3.2:1b` (~770 MB) per owner's comment
- [2026-04-07] CRITICAL fix: Open WebUI /health endpoint used instead of / — /health responds immediately on FastAPI startup, before embedding model downloads; RETRIES bumped to 200 (600s); WEBUI_START_PERIOD 300s; PIPELINES_START_PERIOD 60s; auto-pull llama3.2:1b if no models exist
- [2026-04-08] Set DEFAULT_MODELS=llama3.2:1b in .env.example — Open WebUI pre-selects the smallest model for new conversations; users can override by clearing the value

## Open Questions
- [ ] Should image names also use PROJECT_PREFIX (e.g. `${PROJECT_PREFIX}/app:latest` as TDR suggests)?
  Currently left as `ollama-model-manager:latest` etc. to minimize scope.
- [ ] Should deploy.sh eventually replace install.sh as the primary entry point, or remain a companion script?
