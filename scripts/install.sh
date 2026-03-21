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
#   --webui-port PORT Host port for the Open WebUI chat UI      (default: 45213)
#   --version   TAG   Ollama version tag                        (default: latest)
#   --branch    NAME  Git branch to clone when running via curl (auto-detected if omitted)
# =============================================================================

set -euo pipefail

# ── Survive terminal disconnect; capture all output ───────────────────────────
# SIGHUP is sent when the controlling terminal (SSH session, etc.) closes.
# Ignoring it lets the script keep running.  Docker builds already run inside
# the daemon and continue regardless; this ensures the post-build steps
# (image pulls, container start, health-checks) also survive a disconnect.
#
# IMPORTANT: trap '' HUP must be set BEFORE exec > >(tee ...) so that the tee
# subprocess inherits the ignore disposition.  If tee is forked first, it keeps
# the default SIGHUP handler and dies on terminal disconnect, breaking the pipe.
trap '' HUP

# All stdout + stderr are mirrored to LOG_FILE from this point forward.
# If the install fails the file can be reviewed or posted for support.
LOG_FILE="${LOG_FILE:-/tmp/olama-install.log}"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/olama-install-$(id -u).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Defaults ──────────────────────────────────────────────────────────────────
DATA_DIR="${DATA_DIR:-/opt/olama}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
WEBUI_PORT="${WEBUI_PORT:-45213}"
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
error()   { echo -e "${RED}[olama]${NC} $*" >&2; echo -e "${RED}[olama]${NC} Full install log: ${LOG_FILE}" >&2; exit 1; }
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
      echo "  --webui-port PORT  Host port for Open WebUI   (default: 45213)"
      echo "  --version    TAG   Ollama image tag           (default: latest)"
      echo "  --branch     NAME  Git branch for curl install (default: main)"
      exit 0 ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

# ── Preflight checks ──────────────────────────────────────────────────────────
sep
info "Install log  : ${LOG_FILE}"
info "             → tail -f ${LOG_FILE}  (safe to close terminal)"
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

# Detect host GIDs for Intel GPU device access.
# Docker's group_add uses these as numbers so it never needs to look up group
# names in the container's /etc/group (the 'render' group is not present in
# the Ubuntu 22.04 base image by default, causing "no matching entries" errors).
VIDEO_GID=$(getent group video  2>/dev/null | cut -d: -f3 || true)
RENDER_GID=$(getent group render 2>/dev/null | cut -d: -f3 || true)
# Fall back to the GID of the first renderD device node if the named group
# doesn't exist yet (e.g. GPU drivers not yet installed on the host).
if [[ -z "$RENDER_GID" ]] && ls /dev/dri/renderD* &>/dev/null; then
  RENDER_GID=$(stat -c %g /dev/dri/renderD* 2>/dev/null | head -1 || true)
fi
VIDEO_GID="${VIDEO_GID:-44}"
RENDER_GID="${RENDER_GID:-993}"
info "GPU group IDs: video=${VIDEO_GID}  render=${RENDER_GID}"

# ── Sudo keepalive ────────────────────────────────────────────────────────────
# Prompt for sudo once now, before any background phase, so the script never
# stalls mid-run waiting for a password (e.g. when creating ${DATA_DIR}).
# A background loop refreshes the credential every 50 s for the duration of
# the install; sudo's default cache window is 5-15 min so 50 s is safe.
# The loop is killed on EXIT via the unified trap below.
info "Requesting sudo credentials (needed to create ${DATA_DIR})..."
sudo -v || error "sudo access is required to create data directories"
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
_SUDO_KEEPALIVE_PID=$!

# Unified EXIT trap — kills the sudo keepalive and cleans up the temp clone dir
# (if this is a curl-pipe install).  _CLONE_TEMPDIR is set in the clone section
# below; it stays empty for local-clone installs so the rm is a no-op.
_CLONE_TEMPDIR=""
trap 'kill "$_SUDO_KEEPALIVE_PID" 2>/dev/null; [[ -n "$_CLONE_TEMPDIR" ]] && rm -rf "$_CLONE_TEMPDIR"' EXIT

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
  _CLONE_TEMPDIR="$CLONE_TEMPDIR"   # picked up by the unified EXIT trap above
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
# _stamp_env applies (or updates) a set of key=value lines in the .env file.
# It replaces existing keys in-place and appends any key that is missing.
# User-customised values for keys not in this list are always preserved.
_stamp_env() {
  local file="$1"; shift
  while [[ $# -ge 2 ]]; do
    local key="$1" val="$2"; shift 2
    if grep -q "^${key}=" "$file" 2>/dev/null; then
      sed -i.bak "s|^${key}=.*|${key}=${val}|" "$file" && rm -f "${file}.bak"
    else
      echo "${key}=${val}" >> "$file"
    fi
  done
}

ENV_FILE="${DOCKER_DIR}/.env"
sep
if [[ ! -f "$ENV_FILE" ]]; then
  info "Creating ${ENV_FILE} from .env.example..."
  cp "${REPO_ROOT}/.env.example" "$ENV_FILE"
  success ".env created at ${ENV_FILE}"
else
  info "Updating ${ENV_FILE} with current settings..."
fi
# Always stamp install-time values so re-runs and upgrades stay consistent.
# Everything else in the file (API keys, model names, feature flags, etc.) is left untouched.
_stamp_env "$ENV_FILE" \
  DATA_DIR        "${DATA_DIR}" \
  OLLAMA_PORT     "${OLLAMA_PORT}" \
  WEBUI_PORT      "${WEBUI_PORT}" \
  DOZZLE_PORT     "${DOZZLE_PORT}" \
  OLLAMA_VERSION  "${OLLAMA_VERSION}" \
  VIDEO_GID       "${VIDEO_GID}" \
  RENDER_GID      "${RENDER_GID}"
success ".env ready at ${ENV_FILE}"
info "Review and adjust ${ENV_FILE} at any time — then run: docker compose up -d"

# ── Open firewall ports for LAN access ───────────────────────────────────────
# Docker binds to 0.0.0.0 (all interfaces) so remote machines can reach the
# ports at the network level — but most Linux distros block them by default
# with ufw or firewalld.  Open just the three host-facing ports so other
# devices on the same network can connect.
sep
info "Checking host firewall for LAN access..."
_fw_ports=("${WEBUI_PORT}" "${OLLAMA_PORT}" "${DOZZLE_PORT}")
_fw_labels=("Open WebUI (chat)" "Ollama API" "Dozzle (logs)")
_fw_opened=()

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  info "ufw is active — opening ports..."
  for i in "${!_fw_ports[@]}"; do
    p="${_fw_ports[$i]}"
    if ! ufw status | grep -qE "^${p}[/ ]"; then
      ufw allow "${p}/tcp" comment "olama — ${_fw_labels[$i]}" > /dev/null
      _fw_opened+=("${p}/tcp (${_fw_labels[$i]})")
    else
      info "  Port ${p} already allowed in ufw — skipping."
    fi
  done
  [[ ${#_fw_opened[@]} -gt 0 ]] && \
    success "ufw: opened ${_fw_opened[*]}" || \
    success "ufw: all required ports were already open."

elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
  info "firewalld is active — opening ports..."
  for i in "${!_fw_ports[@]}"; do
    p="${_fw_ports[$i]}"
    if ! firewall-cmd --query-port="${p}/tcp" --permanent &>/dev/null; then
      firewall-cmd --permanent --add-port="${p}/tcp" > /dev/null
      _fw_opened+=("${p}/tcp (${_fw_labels[$i]})")
    else
      info "  Port ${p} already allowed in firewalld — skipping."
    fi
  done
  [[ ${#_fw_opened[@]} -gt 0 ]] && firewall-cmd --reload > /dev/null
  [[ ${#_fw_opened[@]} -gt 0 ]] && \
    success "firewalld: opened ${_fw_opened[*]}" || \
    success "firewalld: all required ports were already open."

else
  info "No active ufw or firewalld detected — skipping firewall step."
  info "If you are running another firewall, allow TCP ports: ${WEBUI_PORT}, ${OLLAMA_PORT}, ${DOZZLE_PORT}"
fi

# ── Build Intel GPU image ──────────────────────────────────────────────────────
# COMPOSE_ANSI=never + --progress plain suppress ANSI spinners/color codes so
# the log file stays readable with `tail -f` or a plain text editor.
sep
info "Building Olama Intel GPU image (first run: ~5 min, downloads Intel GPU drivers)..."
cd "$DOCKER_DIR"
COMPOSE_ANSI=never $COMPOSE_CMD build --pull --progress plain olama
success "Intel GPU image built."

# ── Pull remaining images ──────────────────────────────────────────────────────
info "Pulling service images (open-webui, searxng, pipelines, dozzle)..."
COMPOSE_ANSI=never $COMPOSE_CMD pull open-webui searxng pipelines dozzle
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
    warn "Check: docker logs olama-open-webui"
    break
  fi
  printf '.'
  sleep 3
done
echo

# ── Done ──────────────────────────────────────────────────────────────────────
# Detect the primary LAN IP for the "access from other devices" hint.
_lan_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')

sep
success "Olama stack is running!"
echo
echo "  Chat UI     :  http://localhost:${WEBUI_PORT}"
echo "  Ollama API  :  http://localhost:${OLLAMA_PORT}"
echo "  Log viewer  :  http://localhost:${DOZZLE_PORT}  (Dozzle — live logs for all containers)"
if [[ -n "$_lan_ip" ]]; then
  echo
  echo "  From other devices on your network:"
  echo "    Chat UI    →  http://${_lan_ip}:${WEBUI_PORT}"
  echo "    Ollama API →  http://${_lan_ip}:${OLLAMA_PORT}"
  echo "    Log viewer →  http://${_lan_ip}:${DOZZLE_PORT}"
fi
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
