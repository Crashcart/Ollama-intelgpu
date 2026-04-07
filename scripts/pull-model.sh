#!/usr/bin/env bash
# pull-model.sh — Download an LLM model into the running Ollama container
# Usage: bash pull-model.sh [MODEL_NAME]
# Examples:
#   bash pull-model.sh                  # interactive menu (default: llama3.2:1b)
#   bash pull-model.sh llama3.2:1b      # pull specific model
#   bash pull-model.sh llama3.2:3b      # pull specific tag
#   OLLAMA_PORT=11434 bash pull-model.sh phi3:mini

set -euo pipefail

OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_API="http://localhost:${OLLAMA_PORT}"

# Determine the container name from docker/.env (PROJECT_PREFIX) if available.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || echo ".")"
_ENV_FILE="${_SCRIPT_DIR}/../docker/.env"
_PREFIX=""
if [[ -f "$_ENV_FILE" ]]; then
  _PREFIX="$(grep -E "^PROJECT_PREFIX=" "$_ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
fi
# Use the prefix from .env, or fall back to the default project prefix.
_PREFIX="${_PREFIX:-olama-intelgpu}"
CONTAINER_NAME="${CONTAINER_NAME:-${_PREFIX}-ollama}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[ollama]${NC} $*"; }
success() { echo -e "${GREEN}[ollama]${NC} $*"; }
warn()    { echo -e "${YELLOW}[ollama]${NC} $*"; }
error()   { echo -e "${RED}[ollama]${NC} $*" >&2; exit 1; }

# ── Popular models menu ───────────────────────────────────────────────────────
show_menu() {
  echo ""
  echo "  Popular models (sorted by size — smallest first):"
  echo "  ─────────────────────────────────────────────────"
  echo "  1) llama3.2:1b       ~770 MB  — Very fast, basic tasks (default)"
  echo "  2) gemma2:2b         ~1.6 GB  — Google Gemma 2 2B"
  echo "  3) llama3.2:3b       ~2.0 GB  — Meta Llama 3.2 3B"
  echo "  4) phi3:mini         ~2.3 GB  — Microsoft Phi-3 mini"
  echo "  5) codellama:7b      ~3.8 GB  — Code-focused model"
  echo "  6) mistral           ~4.1 GB  — Well-rounded general model"
  echo "  7) llama3.1:8b       ~4.7 GB  — High quality, 8B params"
  echo "  8) llama3.1:70b      ~40 GB   — Very large, needs lots of VRAM"
  echo "  0) Enter custom model name"
  echo ""
  read -rp "  Select [0-8, Enter for default llama3.2:1b]: " CHOICE
  case "${CHOICE:-1}" in
    1) MODEL="llama3.2:1b" ;;
    2) MODEL="gemma2:2b" ;;
    3) MODEL="llama3.2:3b" ;;
    4) MODEL="phi3:mini" ;;
    5) MODEL="codellama:7b" ;;
    6) MODEL="mistral" ;;
    7) MODEL="llama3.1:8b" ;;
    8) MODEL="llama3.1:70b" ;;
    0)
      read -rp "  Enter model name (e.g. mistral): " MODEL
      [[ -z "$MODEL" ]] && error "No model name entered."
      ;;
    *) error "Invalid choice: ${CHOICE}" ;;
  esac
}

# ── Check Ollama is reachable ──────────────────────────────────────────────────
if ! curl -sf "${OLLAMA_API}/api/tags" &>/dev/null; then
  error "Ollama is not running at ${OLLAMA_API}. Start it first with install.sh"
fi

# ── Determine model to pull ───────────────────────────────────────────────────
MODEL="${1:-}"
if [[ -z "$MODEL" ]]; then
  show_menu
fi

info "Pulling model: ${MODEL}"
info "This may take several minutes depending on model size and connection speed."
echo ""

# Pull via docker exec (streams progress to terminal)
# Use -t only when a TTY is available; piped/SSH sessions have no TTY
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
  TTY_FLAG=; [ -t 0 ] && TTY_FLAG=t
  docker exec -i${TTY_FLAG} "${CONTAINER_NAME}" ollama pull "${MODEL}"
else
  # Fallback: use REST API directly (no docker exec needed)
  warn "Container '${CONTAINER_NAME}' not found, falling back to API pull..."
  curl -X POST "${OLLAMA_API}/api/pull" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${MODEL}\"}" \
    --no-buffer \
    | while IFS= read -r line; do
        STATUS=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
        [[ -n "$STATUS" ]] && echo "  $STATUS"
      done
fi

echo ""
success "Model '${MODEL}' is ready."
echo ""
echo "  Start a chat:"
echo "    docker exec -it ${CONTAINER_NAME} ollama run ${MODEL}"
echo ""
echo "  Or via API:"
echo "    curl http://localhost:${OLLAMA_PORT}/api/generate \\"
echo "      -d '{\"model\":\"${MODEL}\",\"prompt\":\"Hello!\",\"stream\":false}'"
