#!/usr/bin/env bash
# =============================================================================
# update.sh — Update the Ollama stack to the latest images
#
# Usage:
#   bash scripts/update.sh           # update open-webui + all local services
#   bash scripts/update.sh --all     # update every service
#
# What this does:
#   1. Pulls latest registry images (open-webui, searxng, pipelines, dozzle)
#   2. Rebuilds locally-built images (model-manager, portal, ghost-runner,
#      memory-browser, file-catalog, uds-proxy) from source
#   3. Recreates updated containers; all data (chat history, models) is preserved
#
# Safe to run while the stack is running.
# =============================================================================
set -euo pipefail

# ── Locate the docker directory ───────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="${_SCRIPT_DIR}/../docker"
[[ -f "${DOCKER_DIR}/docker-compose.yml" ]] \
  || { echo "ERROR: docker-compose.yml not found in ${DOCKER_DIR}"; exit 1; }
cd "${DOCKER_DIR}"

# ── Pick compose command ──────────────────────────────────────────────────────
if docker compose version &>/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
else
  echo "ERROR: Docker Compose not found." >&2; exit 1
fi

# ── Parse args ────────────────────────────────────────────────────────────────
UPDATE_ALL=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --all) UPDATE_ALL=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--all]"
      echo ""
      echo "  (no flags)  Update open-webui and all locally-built services"
      echo "  --all       Update every service including searxng, pipelines, dozzle"
      exit 0 ;;
    *) echo "Unknown option: $1"; shift ;;
  esac
done

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${CYAN}[update]${NC} $*"; }
success() { echo -e "${GREEN}[update]${NC} $*"; }
warn()    { echo -e "${YELLOW}[update]${NC} $*"; }

# ── Classify services ─────────────────────────────────────────────────────────
# LOCAL_BUILDS  — have a local Dockerfile; must be rebuilt (not pulled)
# REGISTRY_SVCS — pulled from a public registry
if $UPDATE_ALL; then
  LOCAL_BUILDS=(model-manager portal ghost-runner memory-browser file-catalog uds-proxy)
  REGISTRY_SVCS=(open-webui pipelines searxng dozzle)
  ALL_SERVICES=(open-webui model-manager portal ghost-runner memory-browser file-catalog uds-proxy pipelines searxng dozzle)
  info "Updating all services..."
else
  LOCAL_BUILDS=(model-manager portal ghost-runner memory-browser file-catalog uds-proxy)
  REGISTRY_SVCS=(open-webui)
  ALL_SERVICES=(open-webui model-manager portal ghost-runner memory-browser file-catalog uds-proxy)
  info "Updating open-webui and all locally-built services..."
  info "Use --all to also update searxng, pipelines, and dozzle."
fi
echo ""

# ── Pull registry images ──────────────────────────────────────────────────────
for svc in "${REGISTRY_SVCS[@]}"; do
  info "Pulling latest image for: ${svc}"
  COMPOSE_ANSI=never $COMPOSE pull "$svc" 2>&1 \
    | grep -v "^#" \
    | sed 's/^/  /'
  success "${svc} — image ready."
  echo ""
done

# ── Rebuild local images ──────────────────────────────────────────────────────
# --pull  : refresh the base image (nginx:alpine, python:*) while building
# --no-cache: ensure the latest source files are copied in (template changes etc.)
for svc in "${LOCAL_BUILDS[@]}"; do
  info "Rebuilding ${svc} image from source..."
  COMPOSE_ANSI=never $COMPOSE build --pull --no-cache --progress plain "$svc" \
    | grep -v "^#" \
    | sed 's/^/  /'
  success "${svc} image rebuilt."
  echo ""
done

# ── Recreate updated containers ───────────────────────────────────────────────
info "Recreating updated containers (data is preserved)..."
COMPOSE_ANSI=never $COMPOSE up -d --force-recreate "${ALL_SERVICES[@]}"
echo ""

# ── Done ──────────────────────────────────────────────────────────────────────
_env_read() { grep -E "^${1}=" .env 2>/dev/null | tail -1 | cut -d= -f2 || echo "${2}"; }
PORTAL_PORT=$(_env_read PORTAL_PORT 45200)
WEBUI_PORT=$(_env_read WEBUI_PORT 45213)
MODEL_MANAGER_PORT=$(_env_read MODEL_MANAGER_PORT 45214)

success "Update complete!"
echo ""
echo "  Portal         →  http://localhost:${PORTAL_PORT}"
echo "  Chat UI        →  http://localhost:${WEBUI_PORT}"
echo "  Model Manager  →  http://localhost:${MODEL_MANAGER_PORT}"
echo ""
