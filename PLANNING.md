# 🗺️ Session Planning
**Date**: 2026-04-09
**Issue**: SQL MCP Server research — "would something like this be better?"
**Branch**: copilot/update-github-research-sql-mcp-server

## Approach
User asked whether a SQL MCP Server (as featured on Azure SQL Dev Corner) would be a better
fit for this stack than the current SQLite approach. Task is **planning only — no code changes**.

Research findings:
- Current stack uses `aiosqlite` SQLite in ghost-runner (tasks/tokens) and memory-browser (memories).
- AI agents currently have **zero visibility** into their own persisted data.
- SQL MCP Server / Model Context Protocol (MCP) would expose those SQLite databases to the LLM
  via a standardised JSON-RPC interface, enabling natural-language queries against stored data.
- Recommended Option A: add a lightweight SQLite MCP adapter container (mcp/sqlite or Data API
  Builder) that mounts the same `/data` volume — no DB migration, minimal risk, ~10 MB overhead.
- Option B (SQL Server 2025) is future-phase if vector search / semantic memory is needed.
- Models must support tool-calling (llama3.2:1b ✅ does).

Documentation:
- `.github/sql-mcp-server-research.md` — full research, options comparison, architecture diagram,
  model requirements, security considerations, and phased implementation plan.
- `TODO.md` — updated with tasks 8–10 for future implementation phases.

## Decisions Log
- [2026-04-09] Changed OLLAMA_KEEP_ALIVE default from `5m` to `-1` — eliminates cold-start
- [2026-04-09] Added OLLAMA_FLASH_ATTENTION=1 — safe default, falls back silently if unsupported
- [2026-04-09] Added OLLAMA_KV_CACHE_TYPE=q8_0 — best balance of VRAM savings vs quality
- [2026-04-09] Created scripts/keep-alive.sh — protects against client-side eviction overrides
- [2026-04-09] Created .github/ollama-request-speed.md — documents all speed levers for future agents
- [2026-04-09] Researched SQL MCP Server — recommend Option A (SQLite MCP shim) as MVP
- [2026-04-09] Created .github/sql-mcp-server-research.md — full evaluation + phased plan
- [2026-04-06] Set default PROJECT_PREFIX to `olama-intelgpu` (matches GitHub repo name, lowercase with hyphens for Docker compatibility)
- [2026-04-06] Container naming: `${PROJECT_PREFIX}-[service]`
- [2026-04-06] deploy.sh sits alongside install.sh
- [2026-04-07] CRITICAL fix: Open WebUI /health endpoint used, RETRIES 200, auto-pull llama3.2:1b
- [2026-04-08] Set DEFAULT_MODELS=llama3.2:1b in .env.example

## Open Questions
- [ ] Should image names also use PROJECT_PREFIX?
- [ ] Should deploy.sh eventually replace install.sh as the primary entry point?
- [ ] Human approval needed: proceed with Phase 2 (add ollama-mcp-sql to docker-compose)?
- [ ] Should MCP write access be enabled (allows agents to create memories) or read-only only?
