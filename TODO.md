# 📋 Active Task List
**Last Updated**: 2026-04-09 17:30 UTC
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

## Completed This Session
- ✅ Task 1: OLLAMA_KEEP_ALIVE default changed from `5m` → `-1` (keeps model in VRAM indefinitely)
- ✅ Task 2: OLLAMA_FLASH_ATTENTION=1 added to .env.example and docker-compose.yml
- ✅ Task 3: OLLAMA_KV_CACHE_TYPE=q8_0 added to .env.example and docker-compose.yml
- ✅ Task 4: scripts/keep-alive.sh created — heartbeat script to prevent client-side model eviction
- ✅ Task 5: .github/ollama-request-speed.md created — full explanation of cold-start problem and fixes
- ✅ Task 6: .github/copilot-instructions.md updated — performance standards section + new file references
