#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Pre-flight validation and deployment wrapper
#
# Runs container-name and port conflict checks BEFORE starting the stack so
# that failures are caught early ("fail-fast") rather than mid-compose.
#
# Usage (from the repo root or the docker/ directory):
#   bash scripts/deploy.sh             # validate + start stack
#   bash scripts/deploy.sh --force     # stop existing containers, then start
#   bash scripts/deploy.sh --down      # stop and remove stack containers only
#   bash scripts/deploy.sh --status    # show pre-flight results only (no deploy)
#
# Pre-flight checks performed:
#   1. Container name collision — warns if any ${PROJECT_PREFIX}-* container
#      is already running.  Aborts unless --force is passed.
#   2. Port availability — aborts if any required host port is already bound
#      by a process that is NOT one of our own Docker containers.
# =============================================================================

set -euo pipefail

# ── Locate docker dir ─────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="${_SCRIPT_DIR}/../docker"
[[ -f "${DOCKER_DIR}/docker-compose.yml" ]] \
  || { echo "ERROR: docker-compose.yml not found in ${DOCKER_DIR}" >&2; exit 1; }
cd "${DOCKER_DIR}"

# ── Pick compose command ──────────────────────────────────────────────────────
if docker compose version &>/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
else
  echo "ERROR: Docker Compose not found. Install it first." >&2; exit 1
fi

# ── Color helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[deploy]${NC} $*"; }
success() { echo -e "${GREEN}[deploy]${NC} $*"; }
warn()    { echo -e "${YELLOW}[deploy]${NC} $*"; }
error()   { echo -e "${RED}[deploy]${NC} $*" >&2; exit 1; }
sep()     { echo "──────────────────────────────────────────────────────"; }

# ── Parse args ────────────────────────────────────────────────────────────────
FORCE=false
DOWN_ONLY=false
STATUS_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)    FORCE=true;       shift ;;
    --down)     DOWN_ONLY=true;   shift ;;
    --status)   STATUS_ONLY=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--force] [--down] [--status]"
      echo ""
      echo "  (no flags)  Run pre-flight checks then start the stack"
      echo "  --force     Stop existing stack containers first, then start fresh"
      echo "  --down      Stop and remove stack containers (docker compose down)"
      echo "  --status    Show pre-flight check results only — no deployment"
      exit 0 ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

# ── Read .env ─────────────────────────────────────────────────────────────────
ENV_FILE="${DOCKER_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  error ".env not found at ${ENV_FILE}.\nRun: bash scripts/install.sh\nOr:  cp .env.example docker/.env"
fi

_env_read() {
  grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true
}

PROJECT_PREFIX="$(_env_read PROJECT_PREFIX)"; PROJECT_PREFIX="${PROJECT_PREFIX:-olama-intelgpu}"
OLLAMA_PORT="$(_env_read OLLAMA_PORT)";             OLLAMA_PORT="${OLLAMA_PORT:-11434}"
WEBUI_PORT="$(_env_read WEBUI_PORT)";               WEBUI_PORT="${WEBUI_PORT:-45213}"
MODEL_MANAGER_PORT="$(_env_read MODEL_MANAGER_PORT)"; MODEL_MANAGER_PORT="${MODEL_MANAGER_PORT:-45214}"
PORTAL_PORT="$(_env_read PORTAL_PORT)";             PORTAL_PORT="${PORTAL_PORT:-45200}"
GHOST_RUNNER_PORT="$(_env_read GHOST_RUNNER_PORT)"; GHOST_RUNNER_PORT="${GHOST_RUNNER_PORT:-45215}"
MEMORY_PORT="$(_env_read MEMORY_PORT)";             MEMORY_PORT="${MEMORY_PORT:-45216}"
FILE_CATALOG_PORT="$(_env_read FILE_CATALOG_PORT)"; FILE_CATALOG_PORT="${FILE_CATALOG_PORT:-45217}"
DOZZLE_PORT="$(_env_read DOZZLE_PORT)";             DOZZLE_PORT="${DOZZLE_PORT:-9999}"

# ── Service table: "suffix:host_port:label"  (host_port=0 = internal only) ───
declare -a SERVICES=(
  "ollama:${OLLAMA_PORT}:Ollama API"
  "open-webui:${WEBUI_PORT}:Open WebUI (chat)"
  "model-manager:${MODEL_MANAGER_PORT}:Model Manager"
  "portal:${PORTAL_PORT}:Portal (unified UI)"
  "ghost-runner:${GHOST_RUNNER_PORT}:Ghost Runner"
  "memory-browser:${MEMORY_PORT}:Memory Browser"
  "file-catalog:${FILE_CATALOG_PORT}:File Catalog"
  "dozzle:${DOZZLE_PORT}:Dozzle (log viewer)"
  "searxng:0:SearXNG (internal)"
  "pipelines:0:Pipelines (internal)"
  "uds-proxy:0:UDS Proxy (internal)"
)

# ── --down: bring stack down and exit ─────────────────────────────────────────
if $DOWN_ONLY; then
  sep
  info "Stopping and removing ${PROJECT_PREFIX} stack containers..."
  $COMPOSE down --remove-orphans
  success "Stack stopped."
  sep
  exit 0
fi

# ── Pre-flight 1: container name collision check ──────────────────────────────
sep
info "Pre-flight check — container names (prefix: ${PROJECT_PREFIX})"
_container_conflicts=0
for entry in "${SERVICES[@]}"; do
  svc="${entry%%:*}"
  cname="${PROJECT_PREFIX}-${svc}"
  if docker ps -q -f "name=^${cname}$" 2>/dev/null | grep -q .; then
    warn "  CONFLICT  '${cname}' is already running"
    warn "            Pass --force to stop it first, or change PROJECT_PREFIX in docker/.env"
    _container_conflicts=$((_container_conflicts + 1))
  else
    success "  OK        '${cname}' — not running"
  fi
done

# ── Pre-flight 2: host port availability check ───────────────────────────────
sep
info "Pre-flight check — host port availability"

_port_in_use() {
  local port="$1"
  if command -v ss &>/dev/null; then
    ss -tlnp 2>/dev/null | grep -qE ":${port}[ \t]"
  elif command -v netstat &>/dev/null; then
    netstat -tlnp 2>/dev/null | grep -qE ":${port}[ \t]"
  else
    (echo "" >/dev/tcp/127.0.0.1/"$port") 2>/dev/null
  fi
}

_port_owner() {
  local port="$1"
  local _who=""
  if command -v ss &>/dev/null; then
    _who=$(ss -tlnp 2>/dev/null \
      | grep -E ":${port}[ \t]" \
      | grep -oP 'users:\(\("\K[^"]+' | head -1 || true)
  fi
  if [[ -z "$_who" ]] && command -v fuser &>/dev/null; then
    local _pid
    _pid=$(fuser "${port}/tcp" 2>/dev/null | awk '{print $1}' || true)
    [[ -n "$_pid" ]] && _who=$(ps -p "$_pid" -o comm= 2>/dev/null || true)
  fi
  echo "${_who:-unknown process}"
}

_port_conflicts=0
for entry in "${SERVICES[@]}"; do
  rest="${entry#*:}"
  port="${rest%%:*}"
  label="${rest#*:}"
  [[ "$port" == "0" ]] && continue   # internal-only service — no host port to check

  if _port_in_use "$port"; then
    _owner=$(_port_owner "$port")
    # Allow if it is already our own Docker proxy (re-deploy / --recreate scenario)
    if echo "$_owner" | grep -qiE "docker(-proxy)?"; then
      success "  OK        :${port}  ${label} — in use by Docker (our container)"
    else
      warn "  CONFLICT  :${port}  ${label} — already bound by: ${_owner}"
      warn "            Stop that process or change the port in docker/.env"
      _port_conflicts=$((_port_conflicts + 1))
    fi
  else
    success "  OK        :${port}  ${label} — free"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
sep
_total_conflicts=$((_container_conflicts + _port_conflicts))

if $STATUS_ONLY; then
  if [[ $_total_conflicts -eq 0 ]]; then
    success "Pre-flight passed — no conflicts found.  Stack is ready to deploy."
  else
    warn "Pre-flight found ${_total_conflicts} conflict(s)."
    warn "  Port conflicts   : ${_port_conflicts}  (must be resolved manually)"
    warn "  Container conflicts: ${_container_conflicts}  (use --force to auto-stop)"
  fi
  sep
  exit 0
fi

# Hard stop on port conflicts — cannot auto-resolve safely
if [[ $_port_conflicts -gt 0 ]]; then
  error "Aborting — ${_port_conflicts} port conflict(s) must be resolved before deploying.\n  Adjust ports in docker/.env or stop the conflicting process."
fi

# Container conflicts: --force auto-tears down; otherwise abort
if [[ $_container_conflicts -gt 0 ]]; then
  if $FORCE; then
    sep
    info "--force: stopping existing ${PROJECT_PREFIX} stack..."
    $COMPOSE down --remove-orphans
    success "Existing stack stopped."
  else
    error "Aborting — ${_container_conflicts} container conflict(s) detected.\n  Use --force to automatically stop the running stack first.\n  Or run: bash scripts/deploy.sh --down"
  fi
fi

# ── Deploy ────────────────────────────────────────────────────────────────────
sep
info "Deploying ${PROJECT_PREFIX} stack..."
$COMPOSE up -d --no-recreate
echo ""
success "Stack deployed successfully."
sep
