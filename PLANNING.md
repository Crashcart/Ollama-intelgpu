# 🗺️ Session Planning
**Date**: 2026-04-09
**Issue**: README container names stale after PROJECT_PREFIX rename (PR #59 / #75)
**Branch**: copilot/check-last-closed-ticket
**Tier**: TIER 2 — documentation regression

## Approach
Root cause: The previous PRs renamed all container names in `docker-compose.yml` from `ollama-*` to
`${PROJECT_PREFIX:-olama-intelgpu}-*`, but `README.md` was never updated.
Users following the README after upgrading got `Error: No such container: ollama` on every `docker exec` command.

Fix: Replace all stale container name references in `README.md`:
- "What's Included" table: `ollama-portal` → `olama-intelgpu-portal`, etc.
- Tagline "All containers carry the `ollama-` prefix" → `olama-intelgpu-` prefix
- `docker exec ollama` (×5) → `docker exec olama-intelgpu-ollama`
- `docker exec ollama-open-webui` → `docker exec olama-intelgpu-open-webui`
- `container_name: ollama-caddy` → `olama-intelgpu-caddy`
- Caddy/Nginx/Traefik example URLs

## Decisions Log
- [2026-04-06] Set default PROJECT_PREFIX to `olama-intelgpu` (matches GitHub repo name, lowercase with hyphens for Docker compatibility)
- [2026-04-06] Container naming: `${PROJECT_PREFIX}-[service]` (hyphen-separated as specified in TDR)
- [2026-04-06] Image names (`ollama:latest`, `ollama-model-manager:latest`, etc.) left unchanged — only `container_name:` is prefixed, reducing scope of change
- [2026-04-06] deploy.sh sits alongside install.sh (not replacing it) — as owner said "you decide" on whether it replaces install.sh
- [2026-04-06] Port conflict coverage: all host-exposed ports checked (OLLAMA, WEBUI, MODEL_MANAGER, PORTAL, GHOST_RUNNER, MEMORY, FILE_CATALOG, DOZZLE); internal-only services skipped
- [2026-04-06] install.sh preserves user-set PROJECT_PREFIX on re-run (reads from .env before stamping)
- [2026-04-06] Default model changed from `mistral` (~4.1 GB) to `llama3.2:1b` (~770 MB) per owner's comment
- [2026-04-07] CRITICAL fix: Open WebUI /health endpoint used instead of / — /health responds immediately on FastAPI startup, before embedding model downloads; RETRIES bumped to 200 (600s); WEBUI_START_PERIOD 300s; PIPELINES_START_PERIOD 60s; auto-pull llama3.2:1b if no models exist
- [2026-04-08] Set DEFAULT_MODELS=llama3.2:1b in .env.example — Open WebUI pre-selects the smallest model for new conversations; users can override by clearing the value
- [2026-04-09] README documentation updated to reflect new `olama-intelgpu-*` container names

## Open Questions
- [ ] Should image names also use PROJECT_PREFIX (e.g. `${PROJECT_PREFIX}/app:latest` as TDR suggests)?
  Currently left as `ollama-model-manager:latest` etc. to minimize scope.
- [ ] Should deploy.sh eventually replace install.sh as the primary entry point, or remain a companion script?

## Risk Assessment
Documentation-only change — no functional code modified, zero regression risk.
