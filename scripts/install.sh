#!/usr/bin/env bash
# =============================================================================
# install.sh — Install the full Ollama Intel GPU stack
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
#   --data-dir  DIR   Where to store models, chat history, config (default: /opt/ollama)
#   --port      PORT  Host port for the Ollama API              (default: 11434)
#   --webui-port PORT Host port for the Open WebUI chat UI      (default: 45213)
#   --version   TAG   Ollama version tag                        (default: latest)
#   --branch    NAME  Git branch to clone when running via curl (auto-detected if omitted)
#   --recreate        Force-recreate all containers even if they already exist
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
LOG_FILE="${LOG_FILE:-/tmp/ollama-install.log}"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/ollama-install-$(id -u).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Defaults ──────────────────────────────────────────────────────────────────
DATA_DIR="${DATA_DIR:-/opt/ollama}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
WEBUI_PORT="${WEBUI_PORT:-45213}"
OLLAMA_VERSION="${OLLAMA_VERSION:-latest}"
REPO_GIT="https://github.com/Crashcart/Olama-intelgpu"
# Branch is auto-detected below; override with --branch or the REPO_BRANCH env var.
REPO_BRANCH="${REPO_BRANCH:-}"
DOZZLE_PORT="${DOZZLE_PORT:-9999}"
MODEL_MANAGER_PORT="${MODEL_MANAGER_PORT:-45214}"
PORTAL_PORT="${PORTAL_PORT:-45200}"
PROJECT_PREFIX="${PROJECT_PREFIX:-olama-intelgpu}"
COMPOSE_PROJECT="ollama"
RECREATE_CONTAINERS=false
# Comma-separated CIDRs that may reach the UI ports (blank = any source = 0.0.0.0/0)
ALLOW_FROM="${ALLOW_FROM:-}"

# ── Color helpers ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[ollama]${NC} $*"; }
success() { echo -e "${GREEN}[ollama]${NC} $*"; }
warn()    { echo -e "${YELLOW}[ollama]${NC} $*"; }
error()   { echo -e "${RED}[ollama]${NC} $*" >&2; echo -e "${RED}[ollama]${NC} Full install log: ${LOG_FILE}" >&2; exit 1; }
sep()     { echo "──────────────────────────────────────────────────────"; }

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --data-dir)   DATA_DIR="$2";      shift 2 ;;
    --port)       OLLAMA_PORT="$2";   shift 2 ;;
    --webui-port) WEBUI_PORT="$2";    shift 2 ;;
    --version)    OLLAMA_VERSION="$2"; shift 2 ;;
    --branch)     REPO_BRANCH="$2";   shift 2 ;;
    --recreate)   RECREATE_CONTAINERS=true; shift ;;
    --allow-from) ALLOW_FROM="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--data-dir DIR] [--port PORT] [--webui-port PORT] [--version TAG] [--branch NAME] [--recreate] [--allow-from CIDR[,CIDR...]]"
      echo
      echo "  --data-dir   DIR            Storage root for models, chat history, config (default: /opt/ollama)"
      echo "  --port       PORT           Host port for Ollama API   (default: 11434)"
      echo "  --webui-port PORT           Host port for Open WebUI   (default: 45213)"
      echo "  --version    TAG            Ollama image tag           (default: latest)"
      echo "  --branch     NAME           Git branch for curl install (default: main)"
      echo "  --recreate                  Force-recreate all containers (default: preserve existing)"
      echo "  --allow-from CIDR[,CIDR...] Firewall: comma-separated source CIDRs allowed to reach UI ports"
      echo "                              Examples: 192.168.1.0/24   or   10.0.0.0/8,172.16.0.0/12"
      echo "                              Default: open to all sources (0.0.0.0/0)"
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

# ── Install Docker if missing ──────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  warn "Docker not found — installing via get.docker.com..."
  curl -fsSL https://get.docker.com | sudo sh \
    || error "Docker installation failed. Install manually: https://docs.docker.com/get-docker/"
  sudo usermod -aG docker "$USER" || true
  # The group change needs a re-login to take effect; for this session
  # make the socket accessible so the rest of the installer can proceed.
  sudo chmod 660 /var/run/docker.sock 2>/dev/null || true
  sudo systemctl enable docker 2>/dev/null || true
  success "Docker installed and enabled on boot."
  info "Note: log out and back in after install so docker works without sudo."
fi

# ── Start Docker daemon if not running ────────────────────────────────────────
if ! docker info &>/dev/null; then
  warn "Docker daemon is not running — attempting to start it..."
  if command -v systemctl &>/dev/null; then
    sudo systemctl start docker \
      || error "Failed to start Docker daemon. Run manually: sudo systemctl start docker"
    # Wait up to 15 s for the daemon to become ready
    _i=0
    until docker info &>/dev/null; do
      _i=$((_i + 1))
      [[ $_i -ge 15 ]] && error "Docker daemon did not become ready in time. Check: sudo systemctl status docker"
      sleep 1
    done
    success "Docker daemon started."
    info "To start Docker automatically on boot: sudo systemctl enable docker"
  else
    error "Docker daemon is not running. Start it manually and re-run this installer."
  fi
fi

# ── Install Docker Compose plugin if missing ───────────────────────────────────
if docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
else
  warn "Docker Compose not found — installing docker-compose-plugin..."
  if command -v apt-get &>/dev/null; then
    sudo apt-get install -y docker-compose-plugin \
      || error "Failed to install docker-compose-plugin. See https://docs.docker.com/compose/install/"
  elif command -v dnf &>/dev/null; then
    sudo dnf install -y docker-compose-plugin \
      || error "Failed to install docker-compose-plugin. See https://docs.docker.com/compose/install/"
  elif command -v yum &>/dev/null; then
    sudo yum install -y docker-compose-plugin \
      || error "Failed to install docker-compose-plugin. See https://docs.docker.com/compose/install/"
  else
    error "Docker Compose not found and could not be installed automatically. See https://docs.docker.com/compose/install/"
  fi
  success "Docker Compose installed."
  COMPOSE_CMD="docker compose"
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
# When running via curl, copy the repo files to /opt/ollama-stack so the stack
# can be managed after the temp clone is cleaned up.

if [[ -n "$CLONE_TEMPDIR" ]]; then
  INSTALL_DIR="${INSTALL_DIR:-/opt/ollama-stack}"
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

# Copy default SearXNG config if the data dir is empty.
# If the file already exists, preserve the user's customisations — but print a
# visible message so they know the repo's default was not applied and give them
# the manual re-sync command in case they need a new key or engine setting.
if [[ ! -f "${DATA_DIR}/searxng/settings.yml" ]] \
   && [[ -f "${DOCKER_DIR}/searxng/settings.yml" ]]; then
  cp "${DOCKER_DIR}/searxng/settings.yml" "${DATA_DIR}/searxng/settings.yml"
  info "Default searxng/settings.yml copied to ${DATA_DIR}/searxng/"
elif [[ -f "${DATA_DIR}/searxng/settings.yml" ]]; then
  info "SearXNG config already exists — your customisations are preserved."
  info "To apply any new defaults from the repo:"
  info "  cp ${DOCKER_DIR}/searxng/settings.yml ${DATA_DIR}/searxng/settings.yml"
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
# Generate secrets on first install (never overwrite if already set).
# PIPELINES_API_KEY — shared secret between open-webui and pipelines.
# WEBUI_SECRET_KEY  — JWT signing key; stable so sessions survive restarts.
_generate_secret_if_missing() {
  local key="$1" len="$2"
  local current
  current="$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
  if [[ -z "$current" ]]; then
    local secret
    secret="$(openssl rand -hex "$len")"
    _stamp_env "$ENV_FILE" "$key" "$secret"
    info "Generated ${key} (${len}-byte random key)."
  else
    info "${key} already set — keeping existing value."
  fi
}

_generate_secret_if_missing PIPELINES_API_KEY 20
_generate_secret_if_missing WEBUI_SECRET_KEY  32

# Preserve a user-customised PROJECT_PREFIX if already set in the .env file.
# Only write the default on a fresh install (key absent from the file).
_existing_prefix="$(grep -E "^PROJECT_PREFIX=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
if [[ -n "$_existing_prefix" ]]; then
  PROJECT_PREFIX="$_existing_prefix"
  info "PROJECT_PREFIX already set to '${PROJECT_PREFIX}' — keeping."
fi

# Always stamp install-time values so re-runs and upgrades stay consistent.
# Everything else in the file (API keys, model names, feature flags, etc.) is left untouched.
_stamp_env "$ENV_FILE" \
  DATA_DIR             "${DATA_DIR}" \
  OLLAMA_PORT          "${OLLAMA_PORT}" \
  WEBUI_PORT           "${WEBUI_PORT}" \
  DOZZLE_PORT          "${DOZZLE_PORT}" \
  MODEL_MANAGER_PORT   "${MODEL_MANAGER_PORT}" \
  PORTAL_PORT          "${PORTAL_PORT}" \
  OLLAMA_VERSION       "${OLLAMA_VERSION}" \
  VIDEO_GID            "${VIDEO_GID}" \
  RENDER_GID           "${RENDER_GID}" \
  PROJECT_PREFIX       "${PROJECT_PREFIX}" \
  ALLOW_FROM           "${ALLOW_FROM:-any}"
success ".env ready at ${ENV_FILE}"
info "Review and adjust ${ENV_FILE} at any time — then run: docker compose up -d"

# ── Check for port conflicts ───────────────────────────────────────────────────
# Runs after .env is written so we have the final port values.
# Any resolved alternatives are stamped back into .env before the
# firewall and container-start steps that depend on them.
sep
info "Checking for port conflicts..."

# Returns 0 if the port is already listening on the host, 1 if free.
_port_in_use() {
  local port="$1"
  if command -v ss &>/dev/null; then
    ss -tlnp 2>/dev/null | grep -qE ":${port}[ \t]"
  elif command -v netstat &>/dev/null; then
    netstat -tlnp 2>/dev/null | grep -qE ":${port}[ \t]"
  else
    # bash TCP fallback (may be unavailable in restricted shells)
    (echo "" >/dev/tcp/127.0.0.1/"$port") 2>/dev/null
  fi
}

# Returns a human-readable process name occupying the port (best-effort).
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

# Checks one port; if it is in use by a non-ollama process, prompts for
# an alternative and updates the named variable.
_resolve_port() {
  local var_name="$1"   # shell variable to read/write, e.g. PORTAL_PORT
  local label="$2"      # human label, e.g. "Portal"
  local flag_name="$3"  # flag the user can pass to avoid this, e.g. --portal-port
  local current="${!var_name}"

  if ! _port_in_use "$current"; then
    success "  :${current}  ${label} — free"
    return 0
  fi

  # Port is busy — check if it already belongs to one of our containers
  # (happens on re-install / --recreate).  If so, it is fine to reuse.
  local _owner
  _owner=$(_port_owner "$current")
  if echo "$_owner" | grep -qiE "ollama|docker(-proxy)?"; then
    info "  :${current}  ${label} — in use by existing Ollama container (ok)"
    return 0
  fi

  # Real conflict — tell the user what is using the port
  echo
  warn "┌─ PORT CONFLICT ─────────────────────────────────────────────"
  warn "│  :${current}  is already in use by: ${_owner}"
  warn "│  This port was requested for: ${label}"
  warn "└─────────────────────────────────────────────────────────────"
  echo

  # Non-interactive (curl-pipe without a tty) — cannot prompt, must abort
  if [[ ! -t 0 ]]; then
    error "Cannot resolve port conflict non-interactively.\nRerun with ${flag_name} PORT to choose a free port."
  fi

  while true; do
    read -rp "  Enter an alternative port for ${label} [or press Enter to abort]: " _alt
    echo
    [[ -z "$_alt" ]] && error "Aborted — port conflict on :${current} not resolved."

    if ! [[ "$_alt" =~ ^[0-9]+$ ]] || (( _alt < 1024 || _alt > 65535 )); then
      warn "  Invalid — enter a number between 1024 and 65535."
      continue
    fi

    if _port_in_use "$_alt"; then
      local _alt_owner
      _alt_owner=$(_port_owner "$_alt")
      warn "  :${_alt} is also in use by ${_alt_owner} — try another."
      continue
    fi

    printf -v "$var_name" '%s' "$_alt"
    success "  ${label} will use port ${_alt} instead of ${current}."
    break
  done
}

_conflicts=false
_resolve_port PORTAL_PORT        "Portal (unified UI)"  "--portal-port"    || _conflicts=true
_resolve_port WEBUI_PORT         "Open WebUI (chat)"    "--webui-port"     || _conflicts=true
_resolve_port MODEL_MANAGER_PORT "Model Manager"        "--model-manager-port" || _conflicts=true
_resolve_port OLLAMA_PORT        "Ollama API"           "--port"           || _conflicts=true
_resolve_port DOZZLE_PORT        "Dozzle (log viewer)"  "--dozzle-port"    || _conflicts=true

# If any port was reassigned, update .env so the rest of the install uses
# the new values (firewall rules, container start, final URL printout).
if [[ "$PORTAL_PORT$WEBUI_PORT$MODEL_MANAGER_PORT$OLLAMA_PORT$DOZZLE_PORT" != \
      "$(grep -E "^(PORTAL|WEBUI|MODEL_MANAGER|OLLAMA|DOZZLE)_PORT=" "$ENV_FILE" \
         | cut -d= -f2 | tr '\n' ' ' | xargs 2>/dev/null)" ]]; then
  _stamp_env "$ENV_FILE" \
    PORTAL_PORT          "${PORTAL_PORT}" \
    WEBUI_PORT           "${WEBUI_PORT}" \
    MODEL_MANAGER_PORT   "${MODEL_MANAGER_PORT}" \
    OLLAMA_PORT          "${OLLAMA_PORT}" \
    DOZZLE_PORT          "${DOZZLE_PORT}"
  info "Updated ${ENV_FILE} with reassigned ports."
fi

# ── Open firewall ports for LAN access ───────────────────────────────────────
# Docker binds to 0.0.0.0 (all interfaces) so remote machines can reach the
# ports at the network level — but most Linux distros block them by default
# with ufw or firewalld.  Open the host-facing ports for every CIDR in
# ALLOW_FROM (default: any source) so clients on all subnets can connect.
sep
info "Checking host firewall for LAN access..."
_fw_ports=("${PORTAL_PORT}" "${WEBUI_PORT}" "${MODEL_MANAGER_PORT}" "${OLLAMA_PORT}" "${DOZZLE_PORT}")
_fw_labels=("Portal (unified UI)" "Open WebUI (chat)" "Model Manager" "Ollama API" "Dozzle (logs)")
_fw_opened=()

# Parse ALLOW_FROM into an array of CIDRs; empty / "any" / "0.0.0.0/0" → open to all
_parse_cidrs() {
  local raw="${1:-any}"
  IFS=',' read -ra _arr <<< "$raw"
  for c in "${_arr[@]}"; do
    c="${c// /}"
    [[ -z "$c" || "$c" == "any" || "$c" == "0.0.0.0/0" ]] && echo "any" || echo "$c"
  done | sort -u
}
mapfile -t ALLOW_FROM_CIDRS < <(_parse_cidrs "${ALLOW_FROM:-}")

if [[ ${#ALLOW_FROM_CIDRS[@]} -eq 0 ]]; then
  ALLOW_FROM_CIDRS=("any")
fi

# Summarise what we are about to open
if [[ "${ALLOW_FROM_CIDRS[*]}" == "any" ]]; then
  info "Firewall: allowing from any source (pass --allow-from CIDR to restrict)."
else
  info "Firewall: restricting access to: ${ALLOW_FROM_CIDRS[*]}"
fi

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  info "ufw is active — opening ports..."

  for i in "${!_fw_ports[@]}"; do
    p="${_fw_ports[$i]}"
    lbl="${_fw_labels[$i]}"
    for cidr in "${ALLOW_FROM_CIDRS[@]}"; do
      if [[ "$cidr" == "any" ]]; then
        # Simple allow — source-agnostic; idempotent check via status
        if ! ufw status | grep -qE "^${p}[/ ].*ALLOW"; then
          ufw allow "${p}/tcp" comment "ollama — ${lbl}" > /dev/null \
            && _fw_opened+=("${p}/tcp from any (${lbl})")
        else
          info "  Port ${p} already open in ufw — skipping."
        fi
      else
        # Source-restricted rule
        if ! ufw status | grep -qE "^${p}[/ ].*${cidr}.*ALLOW|ALLOW.*${cidr}.*${p}"; then
          ufw allow from "$cidr" to any port "$p" proto tcp \
            comment "ollama — ${lbl}" > /dev/null \
            && _fw_opened+=("${p}/tcp from ${cidr} (${lbl})")
        else
          info "  Port ${p} from ${cidr} already open in ufw — skipping."
        fi
      fi
    done
  done

  [[ ${#_fw_opened[@]} -gt 0 ]] \
    && success "ufw: opened — ${_fw_opened[*]}" \
    || success "ufw: all required rules already present."

elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
  info "firewalld is active — opening ports..."

  for i in "${!_fw_ports[@]}"; do
    p="${_fw_ports[$i]}"
    lbl="${_fw_labels[$i]}"
    for cidr in "${ALLOW_FROM_CIDRS[@]}"; do
      if [[ "$cidr" == "any" ]]; then
        if ! firewall-cmd --query-port="${p}/tcp" --permanent &>/dev/null; then
          firewall-cmd --permanent --add-port="${p}/tcp" > /dev/null \
            && _fw_opened+=("${p}/tcp from any (${lbl})")
        else
          info "  Port ${p} already open in firewalld — skipping."
        fi
      else
        _rich="rule family=\"ipv4\" source address=\"${cidr}\" port port=\"${p}\" protocol=\"tcp\" accept"
        if ! firewall-cmd --query-rich-rule="$_rich" --permanent &>/dev/null; then
          firewall-cmd --permanent --add-rich-rule="$_rich" > /dev/null \
            && _fw_opened+=("${p}/tcp from ${cidr} (${lbl})")
        else
          info "  Port ${p} from ${cidr} already open in firewalld — skipping."
        fi
      fi
    done
  done

  [[ ${#_fw_opened[@]} -gt 0 ]] && firewall-cmd --reload > /dev/null
  [[ ${#_fw_opened[@]} -gt 0 ]] \
    && success "firewalld: opened — ${_fw_opened[*]}" \
    || success "firewalld: all required rules already present."

else
  info "No active ufw or firewalld detected — skipping firewall step."
  if [[ "${ALLOW_FROM_CIDRS[*]}" == "any" ]]; then
    info "If you are running another firewall, allow TCP from any source to ports:"
  else
    info "If you are running another firewall, allow TCP from ${ALLOW_FROM_CIDRS[*]} to ports:"
  fi
  info "  ${PORTAL_PORT} (portal)  ${WEBUI_PORT} (webui)  ${MODEL_MANAGER_PORT} (models)  ${OLLAMA_PORT} (ollama)  ${DOZZLE_PORT} (logs)"
fi

# ── Build Intel GPU image ──────────────────────────────────────────────────────
# COMPOSE_ANSI=never + --progress plain suppress ANSI spinners/color codes so
# the log file stays readable with `tail -f` or a plain text editor.
sep
info "Building Ollama Intel GPU image (first run: ~5 min, downloads Intel GPU drivers)..."
cd "$DOCKER_DIR"
COMPOSE_ANSI=never $COMPOSE_CMD build --pull --progress plain ollama
success "Intel GPU image built."

# ── Pull public images / build local images ───────────────────────────────────
# Services with a registry image use `compose pull`.
# Services built from a local Dockerfile use `compose build`.
sep
info "Checking service containers..."

# Public registry images
for svc in open-webui searxng pipelines dozzle; do
  cname="${PROJECT_PREFIX}-${svc}"
  if $RECREATE_CONTAINERS; then
    info "  $cname — --recreate set, pulling latest image..."
    COMPOSE_ANSI=never $COMPOSE_CMD pull "$svc"
    success "  $cname image ready."
  elif docker inspect "$cname" &>/dev/null; then
    info "  $cname — already installed, skipping"
  else
    info "  $cname — not found, pulling image..."
    COMPOSE_ANSI=never $COMPOSE_CMD pull "$svc"
    success "  $cname image ready."
  fi
done

# Locally-built images (no registry — must use build, not pull)
for svc in model-manager portal; do
  cname="${PROJECT_PREFIX}-${svc}"
  if $RECREATE_CONTAINERS; then
    info "  $cname — --recreate set, rebuilding image..."
    COMPOSE_ANSI=never $COMPOSE_CMD build --progress plain "$svc"
    success "  $cname image ready."
  elif docker image inspect "ollama-${svc}:latest" &>/dev/null; then
    info "  $cname — image already built, skipping"
  else
    info "  $cname — not found, building image..."
    COMPOSE_ANSI=never $COMPOSE_CMD build --progress plain "$svc"
    success "  $cname image ready."
  fi
done

# ── Start the full stack ───────────────────────────────────────────────────────
sep
info "Starting Ollama stack (7 containers)..."
if $RECREATE_CONTAINERS; then
  info "(--recreate: existing containers will be replaced)"
  $COMPOSE_CMD up -d --force-recreate
else
  $COMPOSE_CMD up -d --no-recreate
fi
echo

# ── Wait for Ollama to become ready ───────────────────────────────────────────
info "Waiting for Ollama to become ready..."
RETRIES=40
until curl -sf "http://localhost:${OLLAMA_PORT}/" &>/dev/null; do
  RETRIES=$((RETRIES - 1))
  if [[ $RETRIES -le 0 ]]; then
    error "Ollama did not become ready in time. Debug: docker logs ${PROJECT_PREFIX}-ollama"
  fi
  printf '.'
  sleep 3
done
echo
success "Ollama is ready."

# ── Wait for Open WebUI ────────────────────────────────────────────────────────
info "Waiting for Open WebUI to become ready (starts after Ollama + Pipelines)..."
# On first install Open WebUI must run DB migrations and download embedding
# models before serving requests — allow up to 5 minutes (100 × 3 s).
RETRIES=100
until curl -sf "http://localhost:${WEBUI_PORT}/" &>/dev/null; do
  RETRIES=$((RETRIES - 1))
  if [[ $RETRIES -le 0 ]]; then
    warn "Open WebUI did not become ready in time — it may still be starting."
    warn "Check: docker logs ${PROJECT_PREFIX}-open-webui"
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
success "Ollama stack is running!"
echo
echo "  ┌─ Unified portal (recommended bookmark) ──────────────────────┐"
echo "  │  http://localhost:${PORTAL_PORT}   (Chat + Models + Logs in one page)  │"
echo "  └───────────────────────────────────────────────────────────────┘"
echo
echo "  Individual services:"
echo "    Chat UI        →  http://localhost:${WEBUI_PORT}"
echo "    Model Manager  →  http://localhost:${MODEL_MANAGER_PORT}"
echo "    Log viewer     →  http://localhost:${DOZZLE_PORT}"
echo "    Ollama API     →  http://localhost:${OLLAMA_PORT}"
if [[ -n "$_lan_ip" ]]; then
  echo
  echo "  From other devices on your network:"
  echo "    Portal         →  http://${_lan_ip}:${PORTAL_PORT}   ← bookmark this"
  echo "    Chat UI        →  http://${_lan_ip}:${WEBUI_PORT}"
  echo "    Model Manager  →  http://${_lan_ip}:${MODEL_MANAGER_PORT}"
  echo "    Log viewer     →  http://${_lan_ip}:${DOZZLE_PORT}"
fi
echo
echo "  Manage      :  cd ${INSTALL_DIR}"
echo "  View logs   :  bash ${INSTALL_DIR}/scripts/logs.sh"
echo "  Status      :  bash ${INSTALL_DIR}/scripts/logs.sh status"
echo "  Update UI   :  bash ${INSTALL_DIR}/scripts/update.sh"
echo "  Stop        :  cd ${INSTALL_DIR}/docker && docker compose down"
echo
echo "  If Open WebUI shows a blank page or 'Ollama is running':"
echo "    bash ${INSTALL_DIR}/scripts/update.sh"
echo
echo "  Verify Intel GPU is in use (after pulling a model):"
echo "    docker exec ${PROJECT_PREFIX}-ollama clinfo | grep -i 'device name'"
sep
