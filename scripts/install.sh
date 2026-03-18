#!/usr/bin/env bash
# =============================================================================
# install.sh — Install the full Olama Intel GPU stack
#
# Usage (from a local clone):
#   bash scripts/install.sh [OPTIONS]
#
# Usage (one-liner curl pipe — repo must be public):
#   bash <(curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/install.sh) [OPTIONS]
#
#   If main branch is not yet available (e.g. PR not merged), target the branch:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/<branch>/scripts/install.sh) --branch <branch>
#
# Options:
#   --data-dir  DIR   Where to store models, chat history, config (default: /opt/olama)
#   --port      PORT  Host port for the Ollama API              (default: 11434)
#   --webui-port PORT Host port for the Open WebUI chat UI      (default: 3000)
#   --version   TAG   Ollama version tag                        (default: latest)
#   --branch    NAME  Git branch to clone when running via curl (auto-detected if omitted)
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
DATA_DIR="${DATA_DIR:-/opt/olama}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
WEBUI_PORT="${WEBUI_PORT:-3000}"
OLLAMA_VERSION="${OLLAMA_VERSION:-latest}"
REPO_GIT="https://github.com/Crashcart/Olama-intelgpu"
# Branch is auto-detected below; override with --branch or the REPO_BRANCH env var.
REPO_BRANCH="${REPO_BRANCH:-}"
DOZZLE_PORT="${DOZZLE_PORT:-9999}"
COMPOSE_PROJECT="olama"

# ── Color helpers ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[olama]${NC} $*"; }
success() { echo -e "${GREEN}[olama]${NC} $*"; }
warn()    { echo -e "${YELLOW}[olama]${NC} $*"; }
error()   { echo -e "${RED}[olama]${NC} $*" >&2; exit 1; }
sep()     { echo "──────────────────────────────────────────────────────"; }

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --data-dir)   DATA_DIR="$2";      shift 2 ;;
    --port)       OLLAMA_PORT="$2";   shift 2 ;;
    --webui-port) WEBUI_PORT="$2";    shift 2 ;;
    --version)    OLLAMA_VERSION="$2"; shift 2 ;;
    --branch)     REPO_BRANCH="$2";   shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--data-dir DIR] [--port PORT] [--webui-port PORT] [--version TAG] [--branch NAME]"
      echo
      echo "  --data-dir   DIR   Storage root for models, chat history, config (default: /opt/olama)"
      echo "  --port       PORT  Host port for Ollama API   (default: 11434)"
      echo "  --webui-port PORT  Host port for Open WebUI   (default: 3000)"
      echo "  --version    TAG   Ollama image tag           (default: latest)"
      echo "  --branch     NAME  Git branch for curl install (default: main)"
      exit 0 ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

# ── Preflight checks ──────────────────────────────────────────────────────────
sep
info "Checking prerequisites..."

command -v docker &>/dev/null \
  || error "Docker is not installed. See https://docs.docker.com/get-docker/"

docker info &>/dev/null \
  || error "Docker daemon is not running. Start it: sudo systemctl start docker"

if docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
else
  error "Docker Compose not found. See https://docs.docker.com/compose/install/"
fi

if ! ls /dev/dri/renderD* &>/dev/null; then
  warn "No /dev/dri/renderD* found — Intel GPU passthrough may not work."
  warn "The stack will still run, falling back to CPU inference."
fi

# ── Locate or clone the repo ──────────────────────────────────────────────────
# Detect whether we are running from inside a local clone or being piped from
# curl. When piped, BASH_SOURCE[0] is empty or 'bash', so dirname gives '.'.
# We test for the presence of docker/docker-compose.yml to distinguish.

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || echo ".")"
REPO_ROOT=""

if [[ -f "${_SCRIPT_DIR}/../docker/docker-compose.yml" ]]; then
  # Running from inside a local clone
  REPO_ROOT="$(cd "${_SCRIPT_DIR}/.." && pwd)"
  CLONE_TEMPDIR=""
  info "Using local clone at ${REPO_ROOT}"
else
  # Running via curl pipe — clone the repo
  command -v git &>/dev/null \
    || error "git is required for the curl-pipe install. Install git and retry."

  # Auto-detect branch if not explicitly set: try main, then master.
  if [[ -z "$REPO_BRANCH" ]]; then
    info "Auto-detecting default branch..."
    for _try in main master; do
      if git ls-remote --exit-code --heads "$REPO_GIT" "$_try" &>/dev/null 2>&1; then
        REPO_BRANCH="$_try"
        break
      fi
    done
    if [[ -z "$REPO_BRANCH" ]]; then
      error "Could not find branch 'main' or 'master' in ${REPO_GIT}.\nUse --branch NAME to specify the branch explicitly."
    fi
  fi

  info "Cloning ${REPO_GIT} (branch: ${REPO_BRANCH})..."
  CLONE_TEMPDIR="$(mktemp -d)"
  trap 'rm -rf "$CLONE_TEMPDIR"' EXIT
  git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_GIT" "$CLONE_TEMPDIR" \
    || error "Clone failed. Check that the repo is public and branch '${REPO_BRANCH}' exists."
  REPO_ROOT="$CLONE_TEMPDIR"
  info "Cloned to ${REPO_ROOT}"
fi

DOCKER_DIR="${REPO_ROOT}/docker"
[[ -f "${DOCKER_DIR}/docker-compose.yml" ]] \
  || error "docker/docker-compose.yml not found in ${REPO_ROOT}"

# ── Choose install directory ──────────────────────────────────────────────────
# When running from a clone, use that clone in-place (no copy needed).
# When running via curl, copy the repo files to /opt/olama-stack so the stack
# can be managed after the temp clone is cleaned up.

if [[ -n "$CLONE_TEMPDIR" ]]; then
  INSTALL_DIR="${INSTALL_DIR:-/opt/olama-stack}"
  info "Copying stack files to ${INSTALL_DIR}..."
  sudo mkdir -p "$INSTALL_DIR"
  sudo chown "$USER:$USER" "$INSTALL_DIR"
  cp -r "${REPO_ROOT}/." "${INSTALL_DIR}/"
  REPO_ROOT="$INSTALL_DIR"
  DOCKER_DIR="${INSTALL_DIR}/docker"
else
  INSTALL_DIR="$REPO_ROOT"
fi

# ── Set up data directories ────────────────────────────────────────────────────
sep
info "Creating data directories under ${DATA_DIR}..."
sudo mkdir -p \
  "${DATA_DIR}/models" \
  "${DATA_DIR}/webui" \
  "${DATA_DIR}/searxng" \
  "${DATA_DIR}/pipelines" \
  "${DATA_DIR}/logs"
sudo chown -R "$USER:$USER" "${DATA_DIR}" 2>/dev/null || true
success "Directories ready."

# Copy default SearXNG config if the data dir is empty
if [[ ! -f "${DATA_DIR}/searxng/settings.yml" ]] \
   && [[ -f "${DOCKER_DIR}/searxng/settings.yml" ]]; then
  cp "${DOCKER_DIR}/searxng/settings.yml" "${DATA_DIR}/searxng/settings.yml"
  info "Default searxng/settings.yml copied to ${DATA_DIR}/searxng/"
fi

# ── Write docker/.env ─────────────────────────────────────────────────────────
ENV_FILE="${DOCKER_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  sep
  info "Creating ${ENV_FILE} from .env.example..."
  cp "${REPO_ROOT}/.env.example" "$ENV_FILE"
  # Stamp in user-provided values
  sed -i.bak \
    -e "s|^DATA_DIR=.*|DATA_DIR=${DATA_DIR}|" \
    -e "s|^OLLAMA_PORT=.*|OLLAMA_PORT=${OLLAMA_PORT}|" \
    -e "s|^WEBUI_PORT=.*|WEBUI_PORT=${WEBUI_PORT}|" \
    -e "s|^OLLAMA_VERSION=.*|OLLAMA_VERSION=${OLLAMA_VERSION}|" \
    "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  success ".env written to ${ENV_FILE}"
  info "Review and adjust ${ENV_FILE} at any time — then run: docker compose up -d"
else
  warn ".env already exists at ${ENV_FILE} — not overwriting."
  warn "To reset: rm ${ENV_FILE} && bash ${INSTALL_DIR}/scripts/install.sh"
fi

# ── Build Intel GPU image ──────────────────────────────────────────────────────
sep
info "Building Olama Intel GPU image (first run: ~5 min, downloads Intel GPU drivers)..."
cd "$DOCKER_DIR"
$COMPOSE_CMD build --pull olama
success "Intel GPU image built."

# ── Pull remaining images ──────────────────────────────────────────────────────
info "Pulling service images (open-webui, searxng, pipelines, dozzle)..."
$COMPOSE_CMD pull open-webui searxng pipelines dozzle
success "Images pulled."

# ── Start the full stack ───────────────────────────────────────────────────────
sep
info "Starting Olama stack (5 containers)..."
$COMPOSE_CMD up -d
echo

# ── Wait for Ollama to become ready ───────────────────────────────────────────
info "Waiting for Ollama to become ready..."
RETRIES=40
until curl -sf "http://localhost:${OLLAMA_PORT}/" &>/dev/null; do
  RETRIES=$((RETRIES - 1))
  if [[ $RETRIES -le 0 ]]; then
    error "Ollama did not become ready in time. Debug: docker logs olama"
  fi
  printf '.'
  sleep 3
done
echo
success "Ollama is ready."

# ── Wait for Open WebUI ────────────────────────────────────────────────────────
info "Waiting for Open WebUI to become ready (starts after Ollama + Pipelines)..."
RETRIES=40
until curl -sf "http://localhost:${WEBUI_PORT}/" &>/dev/null; do
  RETRIES=$((RETRIES - 1))
  if [[ $RETRIES -le 0 ]]; then
    warn "Open WebUI did not become ready in time — it may still be starting."
    warn "Check: docker logs open-webui"
    break
  fi
  printf '.'
  sleep 3
done
echo

# ── Done ──────────────────────────────────────────────────────────────────────
sep
success "Olama stack is running!"
echo
echo "  Chat UI     :  http://localhost:${WEBUI_PORT}"
echo "  Ollama API  :  http://localhost:${OLLAMA_PORT}"
echo "  Log viewer  :  http://localhost:${DOZZLE_PORT}  (Dozzle — live logs for all containers)"
echo
echo "  Manage      :  cd ${INSTALL_DIR}"
echo "  View logs   :  bash ${INSTALL_DIR}/scripts/logs.sh"
echo "  Status      :  bash ${INSTALL_DIR}/scripts/logs.sh status"
echo "  Stop        :  cd ${INSTALL_DIR}/docker && docker compose down"
echo
echo "  Pull a model (example):"
echo "    docker exec olama ollama pull mistral"
echo "    docker exec olama ollama pull llama3.2:3b"
echo "    docker exec olama ollama pull llava          # vision model"
echo
echo "  Verify Intel GPU is in use (after pulling a model):"
echo "    docker exec olama clinfo | grep -i 'device name'"
sep
