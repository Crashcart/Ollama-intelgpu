# PLANNING — Session Notes

## Session Goal
Fix all open GitHub issues (#56, #55, #38), push to feature branch, create PR, comment on each ticket.

## Branch
`claude/llama-docker-intel-gpu-U5fE6`

## Issue Triage

### #56 — Crit (Tier 1)
**Problem**: `docker/Dockerfile` Intel GPU GPG key fetch fails.
`wget -qO- ... | gpg --dearmor` → `gpg: no valid OpenPGP data found`

**Root cause**: `wget` doesn't fail on HTTP errors (e.g. redirect to HTML page). If Intel's key URL returns non-GPG content, the pipe silently passes garbage to gpg.

**Fix**: Replace with `curl -fsSL --retry 3`. Save key to temp file before dearmoring so failures are visible. Remove `wget` from apt installs since `curl` already present.

### #55 — important change (Tier 2)
**Problem**: No pre-flight check for container name collisions. No PROJECT_PREFIX variable.

**Decision**: `install.sh` already has port conflict detection; add parallel container-name collision check after the port block. Add `--force` flag to bypass. Add `PROJECT_PREFIX=ollama` to `.env.example` as documentation (full docker-compose.yml plumbing is future work).

### #38 — Many bugs (Tier 2/3)
15 bugs audited. In-scope fixes:
1. Auto-generate `PIPELINES_API_KEY` in install.sh (replaces hardcoded `0p3n-w3bu!`)
2. `WEBUI_AUTH` default → `true`
3. Auto-generate `WEBUI_SECRET_KEY` in install.sh
4. `OLLAMA_VERSION` default → `0.6.5` (was `latest`)
5. SearXNG settings.yml placeholder secret_key warning
6. Health check `start_period` increase (open-webui 30s→60s, pipelines 20s→45s)
7. Runtipi app description filled in
8. DNS configurable via `.env`
9. Model catalog extracted to `catalog.json`

Out-of-scope: HTTPS/TLS (#4), Intel GPU driver URL fragility (#5, fixed separately as #56), logs.sh Runtipi compat (#9), undocumented differences (#11), backup/restore docs (#15), Dozzle log level (#14 stale).

## Open Questions
- None currently

## Decision Log
- Chose not to change container_name values in docker-compose.yml for PROJECT_PREFIX — would require regenerating all container names and break existing installations. `.env.example` documentation is sufficient for #55 MVP.
- `OLLAMA_VERSION` pinned to `0.6.5` (latest stable as of plan date) — users can override.
