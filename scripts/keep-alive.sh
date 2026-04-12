#!/usr/bin/env bash
# keep-alive.sh — Prevent Ollama models from being evicted from VRAM
#
# By default Ollama unloads models after OLLAMA_KEEP_ALIVE idle time (default 5 m).
# Every request after an eviction incurs a 10–45 s cold-start penalty.
#
# This script sends a silent "warmup" request to Ollama at a regular interval,
# keeping the active model in VRAM so every real request gets a sub-second TTFT.
#
# Usage:
#   bash scripts/keep-alive.sh                   # ping every 4 minutes (default)
#   bash scripts/keep-alive.sh --interval 60     # ping every 60 seconds
#   bash scripts/keep-alive.sh --model llama3.2:1b
#   OLLAMA_PORT=11434 bash scripts/keep-alive.sh
#
# Background (systemd / cron alternative):
#   The recommended approach is to set OLLAMA_KEEP_ALIVE=-1 in docker/.env so the
#   model is NEVER evicted.  This script is provided as a safety net for setups
#   where KEEP_ALIVE cannot be set to -1 (e.g. shared servers with VRAM pressure).
#
# Reference:
#   https://www.msn.com/en-us/technology/artificial-intelligence/
#     ollama-is-still-the-easiest-way-to-start-local-llms-but-it-s-the-worst-way-to-keep-running-them

set -euo pipefail

OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_API="http://localhost:${OLLAMA_PORT}"
INTERVAL=240   # seconds between heartbeats (default: 4 min, well under the 5 min default)
MODEL=""       # auto-detect from running models if empty

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[keep-alive]${NC} $*"; }
success() { echo -e "${GREEN}[keep-alive]${NC} $*"; }
warn()    { echo -e "${YELLOW}[keep-alive]${NC} $*"; }
error()   { echo -e "${RED}[keep-alive]${NC} $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval|-i) INTERVAL="$2"; shift 2 ;;
    --model|-m)    MODEL="$2";    shift 2 ;;
    --port|-p)     OLLAMA_PORT="$2"; OLLAMA_API="http://localhost:${OLLAMA_PORT}"; shift 2 ;;
    --help|-h)
      grep '^#' "$0" | head -30 | sed 's/^# \?//'
      exit 0
      ;;
    *) error "Unknown option: $1 (try --help)" ;;
  esac
done

# ── Dependency checks ─────────────────────────────────────────────────────────
if ! command -v curl &>/dev/null; then
  error "curl is required. Install with: sudo apt-get install -y curl"
fi
if ! command -v jq &>/dev/null; then
  warn "jq not found — model auto-detection disabled. Install with: sudo apt-get install -y jq"
fi

# ── Verify Ollama is reachable ────────────────────────────────────────────────
if ! curl -sf "${OLLAMA_API}/" -o /dev/null; then
  error "Ollama is not reachable at ${OLLAMA_API}. Start the stack first: docker compose up -d"
fi

# ── Resolve model ─────────────────────────────────────────────────────────────
_resolve_model() {
  if [[ -n "$MODEL" ]]; then
    echo "$MODEL"
    return
  fi

  # Try auto-detection: first running model, then first available model
  if command -v jq &>/dev/null; then
    local running
    running="$(curl -sf "${OLLAMA_API}/api/ps" | jq -r '.models[0].name // empty' 2>/dev/null || true)"
    if [[ -n "$running" ]]; then
      echo "$running"
      return
    fi

    local first
    first="$(curl -sf "${OLLAMA_API}/api/tags" | jq -r '.models[0].name // empty' 2>/dev/null || true)"
    if [[ -n "$first" ]]; then
      echo "$first"
      return
    fi
  fi

  error "No model is loaded and jq is not installed. Specify a model with --model <name>."
}

# ── Heartbeat loop ────────────────────────────────────────────────────────────
TARGET_MODEL="$(_resolve_model)"
info "Keeping '${TARGET_MODEL}' alive — heartbeat every ${INTERVAL}s (Ctrl-C to stop)"
info "TIP: Set OLLAMA_KEEP_ALIVE=-1 in docker/.env for a permanent solution."

_ping() {
  local resp http_code
  # Send a single empty-prompt generate request.
  # keep_alive=-1 in the body also pins the model for THIS request's lifetime,
  # providing a double safety net even if KEEP_ALIVE is misconfigured server-side.
  resp="$(curl -sf -X POST "${OLLAMA_API}/api/generate" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${TARGET_MODEL}\",\"prompt\":\"\",\"keep_alive\":-1}" \
    -w "\n%{http_code}" 2>&1 || true)"
  http_code="$(echo "$resp" | tail -1)"

  if [[ "$http_code" == "200" ]]; then
    success "$(date '+%H:%M:%S') — heartbeat OK (model in VRAM)"
  else
    warn "$(date '+%H:%M:%S') — heartbeat returned ${http_code} — model may have been evicted"
    # Re-detect model in case user switched
    TARGET_MODEL="$(_resolve_model)"
  fi
}

# Run once immediately, then on the interval
_ping
while true; do
  sleep "$INTERVAL"
  _ping
done
