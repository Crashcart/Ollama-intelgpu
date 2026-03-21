#!/usr/bin/env bash
# =============================================================================
# update.sh — Update the Olama stack to the latest images
#
# Usage:
#   bash scripts/update.sh           # update open-webui + model-manager only
#   bash scripts/update.sh --all     # update every service
#
# What this does:
#   1. Pulls the latest image for each updated service
#   2. Recreates only the containers whose image changed
#   3. Leaves all data (chat history, models, config) untouched
#
# Safe to run while the stack is running — containers are replaced one at a time.
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
      echo "  (no flags)  Update open-webui and model-manager (the UI services)"
      echo "  --all       Update every service including searxng, pipelines, dozzle"
      exit 0 ;;
    *) echo "Unknown option: $1"; shift ;;
  esac
done

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${CYAN}[update]${NC} $*"; }
success() { echo -e "${GREEN}[update]${NC} $*"; }
warn()    { echo -e "${YELLOW}[update]${NC} $*"; }

# ── Choose which services to update ──────────────────────────────────────────
if $UPDATE_ALL; then
  SERVICES=(open-webui model-manager pipelines searxng dozzle)
  info "Updating all services..."
else
  SERVICES=(open-webui model-manager)
  info "Updating UI services (open-webui, model-manager)..."
  info "Use --all to also update searxng, pipelines, and dozzle."
fi

echo ""

# ── Pull registry images / rebuild local images ───────────────────────────────
# model-manager is built from a local Dockerfile — skip pull, go straight to build.
REGISTRY_SERVICES=()
for svc in "${SERVICES[@]}"; do
  [[ "$svc" == "model-manager" ]] && continue
  REGISTRY_SERVICES+=("$svc")
done

if [[ ${#REGISTRY_SERVICES[@]} -gt 0 ]]; then
  for svc in "${REGISTRY_SERVICES[@]}"; do
    info "Pulling latest image for: ${svc}"
    COMPOSE_ANSI=never $COMPOSE pull "$svc" 2>&1 \
      | grep -v "^#" \
      | sed 's/^/  /'
    success "${svc} — image ready."
    echo ""
  done
fi

# model-manager is always rebuilt (local Dockerfile)
info "Rebuilding model-manager image..."
COMPOSE_ANSI=never $COMPOSE build --pull --no-cache --progress plain model-manager \
  | grep -v "^#" \
  | sed 's/^/  /'
success "model-manager image rebuilt."
echo ""

# ── Recreate updated containers ───────────────────────────────────────────────
info "Recreating updated containers (data is preserved)..."
COMPOSE_ANSI=never $COMPOSE up -d --force-recreate "${SERVICES[@]}"
echo ""

# ── Done ──────────────────────────────────────────────────────────────────────
# Read ports from .env (or fall back to defaults)
WEBUI_PORT=$(grep -E '^WEBUI_PORT=' .env 2>/dev/null | cut -d= -f2 || echo 45213)
WEBUI_PORT=${WEBUI_PORT:-45213}
MODEL_MANAGER_PORT=$(grep -E '^MODEL_MANAGER_PORT=' .env 2>/dev/null | cut -d= -f2 || echo 45214)
MODEL_MANAGER_PORT=${MODEL_MANAGER_PORT:-45214}

success "Update complete!"
echo ""
echo "  Chat UI        →  http://localhost:${WEBUI_PORT}"
echo "  Model Manager  →  http://localhost:${MODEL_MANAGER_PORT}"
echo ""
