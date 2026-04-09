# 📋 Active Task List
**Last Updated**: 2026-04-09 21:36 UTC
**Current Session**: Copilot Enterprise Agent

## Current Tasks
| ID | Task Title | Status | Priority | Notes |
|:--:|-----------|--------|----------|-------|
| 1  | Change OLLAMA_KEEP_ALIVE default to -1 in .env.example + docker-compose.yml | ✅ completed | 🔴 HIGH | Eliminates cold-start penalty |
| 2  | Add OLLAMA_FLASH_ATTENTION=1 to .env.example + docker-compose.yml | ✅ completed | 🔴 HIGH | 2-3× faster inference |
| 3  | Add OLLAMA_KV_CACHE_TYPE=q8_0 to .env.example + docker-compose.yml | ✅ completed | 🔴 HIGH | ~50% VRAM reduction |
| 4  | Create scripts/keep-alive.sh heartbeat script | ✅ completed | 🟡 MEDIUM | Safety net against client-side eviction |
| 5  | Create .github/ollama-request-speed.md performance guide | ✅ completed | 🟡 MEDIUM | Documents all speed optimisations |
| 6  | Update .github/copilot-instructions.md with performance standards + new file refs | ✅ completed | 🟡 MEDIUM | References speed guide, new scripts entry |
| 7  | Research SQL MCP Server (Azure SQL Dev Corner) and plan integration | ✅ completed | 🟡 MEDIUM | See .github/sql-mcp-server-research.md |
| 8  | Implement MVP: add ollama-mcp-sql service to docker-compose.yml | ✅ completed | 🟡 MEDIUM | Phase 2 — docker/mcp-sql/ service added |
| 9  | Register MCP endpoint in Open WebUI Tools + document | 🔵 not-started | 🟢 LOW | Phase 3 — Admin → Tools → http://mcp-sql:8080/mcp |
| 10 | Evaluate SQL Server 2025 upgrade for vector search | 🔵 not-started | 🟢 LOW | Phase 4 — only if vector/semantic memory needed |

## Completed This Session
- ✅ Task 1: OLLAMA_KEEP_ALIVE default changed from `5m` → `-1` (keeps model in VRAM indefinitely)
- ✅ Task 2: OLLAMA_FLASH_ATTENTION=1 added to .env.example and docker-compose.yml
- ✅ Task 3: OLLAMA_KV_CACHE_TYPE=q8_0 added to .env.example and docker-compose.yml
- ✅ Task 4: scripts/keep-alive.sh created — heartbeat script to prevent client-side model eviction
- ✅ Task 5: .github/ollama-request-speed.md created — full explanation of cold-start problem and fixes
- ✅ Task 6: .github/copilot-instructions.md updated — performance standards section + new file references
- ✅ Task 7: .github/sql-mcp-server-research.md created — SQL MCP Server evaluation, architecture options, recommendation
- ✅ Task 8: docker/mcp-sql/ service created — lightweight Python FastAPI MCP JSON-RPC 2.0 server; added to docker-compose.yml
