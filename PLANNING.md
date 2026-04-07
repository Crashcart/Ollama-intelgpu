# 🗺️ Session Planning
**Date**: 2026-04-07
**Issue**: #59 — important change (Agnostic Docker Ecosystem Deployment & Conflict Prevention TDR)
**Branch**: copilot/explore-codebase-and-create-implementation-plan

## Approach
All planned gap fixes implemented:
1. `scripts/uninstall.sh` — fallback container list expanded to all 11 services; "7 containers" → "11"
2. `scripts/update.sh` — LOCAL_BUILDS now covers all 6 locally-built services
3. `scripts/logs.sh` — CONTAINERS array, CNAME map, CATEGORY/DATA_PATH maps expanded to all 11 services
4. `README.md` — container table updated (all 11 services, PROJECT_PREFIX naming); counts corrected; docker exec examples fixed; data dirs tree and mkdir updated; proxy examples fixed to use service names

## Decisions Log
- [2026-04-06] Set default PROJECT_PREFIX to `olama-intelgpu` (matches GitHub repo name, lowercase with hyphens for Docker compatibility)
- [2026-04-06] Container naming: `${PROJECT_PREFIX}-ollama`, `${PROJECT_PREFIX}-open-webui`, etc. (hyphen-separated as specified in TDR)
- [2026-04-06] Image names (`ollama:latest`, `ollama-model-manager:latest`, etc.) left unchanged — only `container_name:` is prefixed, reducing scope of change
- [2026-04-06] deploy.sh sits alongside install.sh (not replacing it) — as owner said "you decide" on whether it replaces install.sh
- [2026-04-06] Port conflict coverage: all host-exposed ports checked (OLLAMA, WEBUI, MODEL_MANAGER, PORTAL, GHOST_RUNNER, MEMORY, FILE_CATALOG, DOZZLE); internal-only services skipped
- [2026-04-06] install.sh preserves user-set PROJECT_PREFIX on re-run (reads from .env before stamping)
- [2026-04-06] Default model changed from `mistral` (~4.1 GB) to `llama3.2:1b` (~770 MB) per owner's comment
- [2026-04-07] Image name prefixing left as-is (e.g. `ollama-model-manager:latest`) — adding PROJECT_PREFIX to image names would break cached builds and is out of scope
- [2026-04-07] deploy.sh remains a companion to install.sh; README does not promote it as primary entry point
- [2026-04-07] Nginx/Traefik proxy examples updated to use Docker service names (portal:8080, open-webui:8080) — these are stable regardless of PROJECT_PREFIX; container_name is only for external docker ps identification
- [2026-04-07] update.sh: all 6 local builds (model-manager, portal, ghost-runner, memory-browser, file-catalog, uds-proxy) included in both default and --all update paths

## Open Questions
- (none — all questions from previous session resolved)
