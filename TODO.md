# 📋 Active Task List
**Last Updated**: 2026-04-07 05:00 UTC
**Current Session**: Copilot Enterprise Agent

## Current Tasks
| ID | Task Title | Status | Priority | Notes |
|:--:|-----------|--------|----------|-------|
| 1  | Add PROJECT_PREFIX to .env.example | ✅ completed | 🔴 HIGH | Done |
| 2  | Update docker-compose.yml container names to use ${PROJECT_PREFIX} | ✅ completed | 🔴 HIGH | 11 containers updated |
| 3  | Create scripts/deploy.sh pre-flight wrapper | ✅ completed | 🔴 HIGH | Container + port checks, --force/--down/--status flags |
| 4  | Update scripts/install.sh with PROJECT_PREFIX support | ✅ completed | 🔴 HIGH | Stamps to .env, preserves user value |
| 5  | Update scripts/pull-model.sh — dynamic container name + smallest default model | ✅ completed | 🟡 MEDIUM | Default changed to llama3.2:1b |
| 6  | Update scripts/uninstall.sh — PROJECT_PREFIX fallback container list | ✅ completed | 🟡 MEDIUM | All 11 containers covered |
| 7  | Update scripts/logs.sh — dynamic CNAME map + all 11 services | ✅ completed | 🟡 MEDIUM | Done |
| 8  | Validate all changes — shellcheck + manual review | ✅ completed | 🟡 MEDIUM | Changes reviewed |
| 9  | Fix scripts/update.sh — add ghost-runner, memory-browser, file-catalog, uds-proxy to LOCAL_BUILDS | ✅ completed | 🟡 MEDIUM | Done |
| 10 | Fix README — container table, counts (7→11), docker exec names, data dirs, proxy examples | ✅ completed | 🟡 MEDIUM | Done |

## Completed This Session
- ✅ Task 1–7: Implement Docker PROJECT_PREFIX naming convention (issue #59)
- ✅ Task 8: Validate changes + review
- ✅ Task 9: update.sh LOCAL_BUILDS now covers all 6 local services
- ✅ Task 10: README fully updated (container table with all 11 services, correct counts, fix docker exec examples)
