#!/usr/bin/env bash
# install.sh — Install Olama (Ollama + Intel GPU) via Docker
# Usage: curl -fsSL <url>/install.sh | bash
#        or: bash install.sh [--port PORT] [--data-dir DIR] [--version VERSION]

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_DATA_DIR="${OLLAMA_DATA_DIR:-/opt/olama}"
OLLAMA_VERSION="${OLLAMA_VERSION:-latest}"
COMPOSE_PROJECT="olama"
REPO_URL="https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main"

# ── Color helpers ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[olama]${NC} $*"; }
success() { echo -e "${GREEN}[olama]${NC} $*"; }
warn()    { echo -e "${YELLOW}[olama]${NC} $*"; }
error()   { echo -e "${RED}[olama]${NC} $*" >&2; exit 1; }

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)       OLLAMA_PORT="$2";     shift 2 ;;
    --data-dir)   OLLAMA_DATA_DIR="$2"; shift 2 ;;
    --version)    OLLAMA_VERSION="$2";  shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--port PORT] [--data-dir DIR] [--version VERSION]"
      echo "  --port        Host port to expose Olama on (default: 11434)"
      echo "  --data-dir    Directory to store models and config (default: /opt/olama)"
      echo "  --version     Ollama version tag to install (default: latest)"
      exit 0 ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

# ── Preflight checks ──────────────────────────────────────────────────────────
info "Checking prerequisites..."

command -v docker &>/dev/null || error "Docker is not installed. Install it from https://docs.docker.com/get-docker/"

docker info &>/dev/null || error "Docker daemon is not running. Start it with: sudo systemctl start docker"

# Check Docker Compose (v2 plugin or standalone v1)
if docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
else
  error "Docker Compose not found. Install it from https://docs.docker.com/compose/install/"
fi

# Check for Intel GPU render node
if ! ls /dev/dri/renderD* &>/dev/null; then
  warn "No /dev/dri/renderD* device found. Intel GPU passthrough may not work."
  warn "The container will still run but will use CPU only."
fi

# ── Setup directories ─────────────────────────────────────────────────────────
info "Creating data directories: ${OLLAMA_DATA_DIR}"
sudo mkdir -p \
  "${OLLAMA_DATA_DIR}/models" \
  "${OLLAMA_DATA_DIR}/webui" \
  "${OLLAMA_DATA_DIR}/searxng" \
  "${OLLAMA_DATA_DIR}/pipelines" \
  "${OLLAMA_DATA_DIR}/logs"
sudo chown -R "$USER:$USER" "${OLLAMA_DATA_DIR}" 2>/dev/null || true

# ── Write docker-compose.yml ──────────────────────────────────────────────────
COMPOSE_FILE="${OLLAMA_DATA_DIR}/docker-compose.yml"
info "Writing compose file to ${COMPOSE_FILE}..."

cat > "${COMPOSE_FILE}" <<EOF
version: "3.9"

services:
  olama:
    image: ollama/ollama:${OLLAMA_VERSION}
    container_name: olama
    restart: unless-stopped
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - video
      - render
    environment:
      - OLLAMA_HOST=0.0.0.0:11434
    ports:
      - "${OLLAMA_PORT}:11434"
    volumes:
      - ${OLLAMA_DATA_DIR}/models:/root/.ollama

volumes: {}
EOF

# ── Write .env file ───────────────────────────────────────────────────────────
cat > "${OLLAMA_DATA_DIR}/.env" <<EOF
OLLAMA_PORT=${OLLAMA_PORT}
OLLAMA_VERSION=${OLLAMA_VERSION}
OLLAMA_DATA_DIR=${OLLAMA_DATA_DIR}
EOF

# ── Pull image & start ────────────────────────────────────────────────────────
info "Pulling Ollama image (no model bundled — image is ~1 GB)..."
$COMPOSE_CMD -f "${COMPOSE_FILE}" -p "${COMPOSE_PROJECT}" pull

info "Starting Olama container..."
$COMPOSE_CMD -f "${COMPOSE_FILE}" -p "${COMPOSE_PROJECT}" up -d

# ── Wait for readiness ────────────────────────────────────────────────────────
info "Waiting for Olama to become ready..."
RETRIES=20
until curl -sf "http://localhost:${OLLAMA_PORT}/api/tags" &>/dev/null; do
  RETRIES=$((RETRIES - 1))
  [[ $RETRIES -le 0 ]] && error "Olama did not start in time. Check: docker logs olama"
  sleep 2
done

success "Olama is running at http://localhost:${OLLAMA_PORT}"
echo ""
echo "  Next steps:"
echo "  • Download a model:  bash pull-model.sh            (mistral recommended)"
echo "  • Or pull manually:  docker exec olama ollama pull mistral"
echo "  • Chat in browser:   http://localhost:${OLLAMA_PORT}"
echo "  • Stop:              docker stop olama"
echo "  • Remove:            docker rm olama"
echo ""
echo "  Verify Intel GPU is in use after pulling a model:"
echo "    docker exec olama clinfo | grep -i 'device name'"
