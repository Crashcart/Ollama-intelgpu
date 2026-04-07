# 🗺️ Session Planning
**Date**: 2026-04-06 → 2026-04-07
**Issue**: #59 — important change (Agnostic Docker Ecosystem Deployment & Conflict Prevention TDR)
**Branch**: copilot/update-docker-images

## Approach
Implement the TDR requirements with minimal, surgical changes:
1. Add `PROJECT_PREFIX=olama-intelgpu` to `.env.example` (repo-name-based default)
2. Update all `container_name:` fields in `docker/docker-compose.yml` to use `${PROJECT_PREFIX:-olama-intelgpu}`
3. Create `scripts/deploy.sh` as a standalone pre-flight wrapper (container name + port conflict detection, `--force`, `--down`, `--status` flags)
4. Update all scripts that reference container names to use the PREFIX dynamically
5. Change default model in `pull-model.sh` to `llama3.2:1b` (smallest, per owner comment)
6. Fix Open WebUI startup timeout: RETRIES 40→100 (300 s), WEBUI_START_PERIOD 60s→120s

## Decisions Log
- [2026-04-06] Set default PROJECT_PREFIX to `olama-intelgpu` (matches GitHub repo name, lowercase with hyphens for Docker compatibility)
- [2026-04-06] Container naming: `${PROJECT_PREFIX}-ollama`, `${PROJECT_PREFIX}-open-webui`, etc. (hyphen-separated as specified in TDR)
- [2026-04-06] Image names (`ollama:latest`, `ollama-model-manager:latest`, etc.) left unchanged — only `container_name:` is prefixed, reducing scope of change
- [2026-04-06] deploy.sh sits alongside install.sh (not replacing it) — as owner said "you decide" on whether it replaces install.sh
- [2026-04-06] Port conflict coverage: all host-exposed ports checked (OLLAMA, WEBUI, MODEL_MANAGER, PORTAL, GHOST_RUNNER, MEMORY, FILE_CATALOG, DOZZLE); internal-only services skipped
- [2026-04-06] install.sh preserves user-set PROJECT_PREFIX on re-run (reads from .env before stamping)
- [2026-04-06] Default model changed from `mistral` (~4.1 GB) to `llama3.2:1b` (~770 MB) per owner's comment
- [2026-04-07] Open WebUI wait timeout increased from 40 retries (120 s) to 100 retries (300 s) — first install needs 3-5 min for DB migrations and embedding model downloads
- [2026-04-07] WEBUI_START_PERIOD default increased from 60s to 120s in both .env.example and docker-compose.yml

## Open Questions
- [ ] Should image names also use PROJECT_PREFIX (e.g. `${PROJECT_PREFIX}/app:latest` as TDR suggests)?
  Currently left as `ollama-model-manager:latest` etc. to minimize scope.
- [ ] Should deploy.sh eventually replace install.sh as the primary entry point, or remain a companion script?
