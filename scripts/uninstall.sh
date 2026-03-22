#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — Remove the Olama Intel GPU stack
#
# Usage (from a local clone):
#   bash scripts/uninstall.sh [OPTIONS]
#
# Usage (one-liner curl pipe — repo must be public):
#   bash <(curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/uninstall.sh) [OPTIONS]
#
# Options:
#   --data-dir    DIR   Where data was stored (default: /opt/olama)
#   --install-dir DIR   Where stack files were installed (default: /opt/olama-stack)
#   --purge             Also delete the data directory (models, history, config)
#   --keep-images       Keep Docker images (default: remove all olama images)
#   --yes / -y          Skip confirmation prompts
# =============================================================================

set -euo pipefail

# ── Survive terminal disconnect; capture all output ───────────────────────────
trap '' HUP

LOG_FILE="${LOG_FILE:-/tmp/olama-uninstall.log}"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/olama-uninstall-$(id -u).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Defaults ──────────────────────────────────────────────────────────────────
DATA_DIR="${DATA_DIR:-/opt/olama}"
INSTALL_DIR="${INSTALL_DIR:-/opt/olama-stack}"
PORTAL_PORT="${PORTAL_PORT:-45200}"
WEBUI_PORT="${WEBUI_PORT:-45213}"
MODEL_MANAGER_PORT="${MODEL_MANAGER_PORT:-45214}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
DOZZLE_PORT="${DOZZLE_PORT:-9999}"
PURGE_DATA=false
KEEP_IMAGES=false
YES=false

# ── Color helpers ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[olama]${NC} $*"; }
success() { echo -e "${GREEN}[olama]${NC} $*"; }
warn()    { echo -e "${YELLOW}[olama]${NC} $*"; }
error()   { echo -e "${RED}[olama]${NC} $*" >&2; echo -e "${RED}[olama]${NC} Full log: ${LOG_FILE}" >&2; exit 1; }
sep()     { echo "──────────────────────────────────────────────────────"; }

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --data-dir)    DATA_DIR="$2";    shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --purge)       PURGE_DATA=true;  shift ;;
    --keep-images) KEEP_IMAGES=true; shift ;;
    --yes|-y)      YES=true;         shift ;;
    --help|-h)
      echo "Usage: $0 [--data-dir DIR] [--install-dir DIR] [--purge] [--keep-images] [--yes]"
      echo
      echo "  --data-dir    DIR   Where data is stored   (default: /opt/olama)"
      echo "  --install-dir DIR   Where stack files live (default: /opt/olama-stack)"
      echo "  --purge             Also delete the data directory (models, history, config)"
      echo "  --keep-images       Keep Docker images     (default: remove all olama images)"
      echo "  --yes / -y          Skip confirmation prompts"
      exit 0 ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

# ── Read actual ports and dirs from .env ──────────────────────────────────────
_ENV_FILE=""
for _try in \
  "${INSTALL_DIR}/docker/.env" \
  "$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || echo ".")/../docker/.env"; do
  if [[ -f "$_try" ]]; then
    _ENV_FILE="$(realpath "$_try")"
    break
  fi
done

if [[ -n "$_ENV_FILE" ]]; then
  info "Reading installed config from ${_ENV_FILE}..."
  _env_read() { grep -E "^${1}=" "$_ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true; }
  _v=$(_env_read DATA_DIR);           [[ -n "$_v" ]] && DATA_DIR="$_v"
  _v=$(_env_read PORTAL_PORT);        [[ -n "$_v" ]] && PORTAL_PORT="$_v"
  _v=$(_env_read WEBUI_PORT);         [[ -n "$_v" ]] && WEBUI_PORT="$_v"
  _v=$(_env_read MODEL_MANAGER_PORT); [[ -n "$_v" ]] && MODEL_MANAGER_PORT="$_v"
  _v=$(_env_read OLLAMA_PORT);        [[ -n "$_v" ]] && OLLAMA_PORT="$_v"
  _v=$(_env_read DOZZLE_PORT);        [[ -n "$_v" ]] && DOZZLE_PORT="$_v"
  _v=$(_env_read OLLAMA_VERSION);     OLLAMA_VERSION="${_v:-latest}"
else
  OLLAMA_VERSION="latest"
fi

# ── Docker Compose detection ───────────────────────────────────────────────────
COMPOSE_CMD=""
if docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
fi

COMPOSE_FILE=""
for _try in \
  "${INSTALL_DIR}/docker/docker-compose.yml" \
  "$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || echo ".")/../docker/docker-compose.yml"; do
  if [[ -f "$_try" ]]; then
    COMPOSE_FILE="$(realpath "$_try")"
    break
  fi
done

# ── Gather what will actually be removed (for the summary) ───────────────────
# Collect all olama-related images across every tag (not just :latest)
_olama_imgs=()
while IFS= read -r _img; do
  [[ -n "$_img" ]] && _olama_imgs+=("$_img")
done < <(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null \
  | grep -E "^(olama|olama-model-manager|olama-portal):" || true)

# Collect Docker volumes with "olama" in the name
_olama_vols=()
while IFS= read -r _vol; do
  [[ -n "$_vol" ]] && _olama_vols+=("$_vol")
done < <(docker volume ls -q --filter "name=olama" 2>/dev/null || true)

# Collect Docker networks with "olama" in the name (plus docker_default from compose)
_olama_nets=()
while IFS= read -r _net; do
  [[ -n "$_net" ]] && _olama_nets+=("$_net")
done < <(docker network ls --format "{{.Name}}" 2>/dev/null \
  | grep -E "^(olama|docker_default$)" || true)

# ── Show what will happen ──────────────────────────────────────────────────────
sep
echo -e "${BOLD}Olama Stack — Uninstaller${NC}"
sep
echo
echo "  Uninstall log: ${LOG_FILE}"
echo "     → tail -f ${LOG_FILE}  (safe to close terminal)"
echo
echo "  This will:"
echo "    • Stop and remove all 7 Olama containers"

if ! $KEEP_IMAGES; then
  if [[ ${#_olama_imgs[@]} -gt 0 ]]; then
    echo "    • Remove Docker images:"
    for _i in "${_olama_imgs[@]}"; do echo "        - ${_i}"; done
  else
    echo "    • Remove Docker images  (none found — already clean)"
  fi
fi

if [[ ${#_olama_vols[@]} -gt 0 ]]; then
  echo "    • Remove Docker volumes:"
  for _v in "${_olama_vols[@]}"; do echo "        - ${_v}"; done
fi

if [[ ${#_olama_nets[@]} -gt 0 ]]; then
  echo "    • Remove Docker networks:"
  for _n in "${_olama_nets[@]}"; do echo "        - ${_n}"; done
fi

echo "    • Remove firewall rules added by the installer (if any)"
[[ -d "$INSTALL_DIR" ]] && echo "    • Delete stack files at ${INSTALL_DIR}"
echo
if $PURGE_DATA; then
  echo -e "  ${RED}${BOLD}--purge:  ALSO DELETE ${DATA_DIR}${NC}"
  echo -e "  ${RED}          This permanently removes all models, chat history, and config.${NC}"
  _data_size=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo "?")
  echo -e "  ${RED}          Estimated size: ${_data_size}${NC}"
else
  echo -e "  ${YELLOW}Data at ${DATA_DIR} will be KEPT.${NC}"
  echo    "  (use --purge to also delete models, history, and config)"
fi
echo
echo "  Public registry images will be left in place (open-webui, searxng, pipelines, dozzle)."
echo

# ── Confirmation prompt ────────────────────────────────────────────────────────
if ! $YES; then
  read -rp "  Proceed with uninstall? [y/N] " _confirm
  echo
  [[ "$_confirm" =~ ^[Yy]$ ]] || { info "Aborted — nothing was changed."; exit 0; }
fi

# ── Extra confirmation for --purge ────────────────────────────────────────────
if $PURGE_DATA && ! $YES; then
  echo -e "  ${RED}${BOLD}FINAL WARNING — this cannot be undone.${NC}"
  echo    "  All model weights, chat history, RAG documents, and config"
  echo    "  at ${DATA_DIR} will be permanently deleted."
  echo
  read -rp "  Type 'purge' to confirm: " _purge_confirm
  echo
  if [[ "$_purge_confirm" != "purge" ]]; then
    warn "Purge not confirmed — data will be kept. Continuing with container removal only."
    PURGE_DATA=false
  fi
fi

# ── Stop and remove containers + volumes ──────────────────────────────────────
sep
info "Stopping and removing Olama containers..."

if [[ -n "$COMPOSE_CMD" && -n "$COMPOSE_FILE" ]]; then
  info "Using compose file: ${COMPOSE_FILE}"
  cd "$(dirname "$COMPOSE_FILE")"
  # --volumes: removes any anonymous/named volumes declared in the compose file
  # --remove-orphans: cleans up containers not in the current compose definition
  $COMPOSE_CMD down --volumes --remove-orphans 2>/dev/null \
    && success "Containers, volumes, and networks removed (docker compose down)." \
    || warn "docker compose down reported an error — containers may already be gone."
else
  # Fallback: stop by known container names
  warn "Compose file not found — stopping containers by name..."
  _any_removed=false
  for cname in olama olama-open-webui olama-model-manager olama-portal \
                olama-searxng olama-pipelines olama-dozzle; do
    if docker inspect "$cname" &>/dev/null 2>&1; then
      docker stop "$cname" 2>/dev/null || true
      docker rm   "$cname" 2>/dev/null || true
      info "  Removed container: ${cname}"
      _any_removed=true
    fi
  done
  $_any_removed \
    && success "Containers removed." \
    || info "No running containers found — already clean."

  # Remove networks in fallback path (compose down handles this in normal path)
  for _net in olama_default docker_default; do
    if docker network inspect "$_net" &>/dev/null 2>&1; then
      docker network rm "$_net" 2>/dev/null \
        && info "  Removed network: ${_net}" || true
    fi
  done
fi

# ── Remove Docker volumes (any that compose down may have missed) ─────────────
if [[ ${#_olama_vols[@]} -gt 0 ]]; then
  sep
  info "Removing Docker volumes..."
  for _vol in "${_olama_vols[@]}"; do
    docker volume rm "$_vol" 2>/dev/null \
      && success "  Removed volume: ${_vol}" \
      || warn "  Could not remove volume ${_vol} — may still be in use."
  done
fi

# ── Remove Docker images ───────────────────────────────────────────────────────
if ! $KEEP_IMAGES; then
  sep
  info "Removing Docker images..."

  # Re-query images now that containers are stopped (removes "in use" blocks)
  _imgs_to_remove=()
  while IFS= read -r _img; do
    [[ -n "$_img" ]] && _imgs_to_remove+=("$_img")
  done < <(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null \
    | grep -E "^(olama|olama-model-manager|olama-portal):" || true)

  _imgs_removed=()
  for img in "${_imgs_to_remove[@]}"; do
    docker rmi "$img" 2>/dev/null \
      && _imgs_removed+=("$img") \
      || warn "  Could not remove ${img} — may still be referenced by another container."
  done

  # Also remove any dangling (untagged) layers left by our builds
  _dangling=$(docker images -q --filter "dangling=true" 2>/dev/null || true)
  if [[ -n "$_dangling" ]]; then
    echo "$_dangling" | xargs docker rmi 2>/dev/null || true
    info "  Removed dangling build layers."
  fi

  if [[ ${#_imgs_removed[@]} -gt 0 ]]; then
    success "Images removed: ${_imgs_removed[*]}"
  else
    info "No locally-built images found — already clean."
  fi

  echo
  info "Public registry images left in place (other stacks may use them):"
  info "  ghcr.io/open-webui/open-webui:main  ghcr.io/open-webui/pipelines:main"
  info "  searxng/searxng:latest  amir20/dozzle:latest"
  info "To remove them too:"
  info "  docker rmi ghcr.io/open-webui/open-webui:main ghcr.io/open-webui/pipelines:main \\"
  info "             searxng/searxng:latest amir20/dozzle:latest"
fi

# ── Remove remaining olama networks ───────────────────────────────────────────
# compose down removes the compose-managed network, but scan for any stragglers
_remaining_nets=$(docker network ls --format "{{.Name}}" 2>/dev/null \
  | grep -E "^olama" || true)
if [[ -n "$_remaining_nets" ]]; then
  sep
  info "Removing remaining Docker networks..."
  while IFS= read -r _net; do
    [[ -n "$_net" ]] && docker network rm "$_net" 2>/dev/null \
      && info "  Removed network: ${_net}" || true
  done <<< "$_remaining_nets"
fi

# ── Remove firewall rules ──────────────────────────────────────────────────────
sep
info "Removing firewall rules added by the installer..."
_fw_ports=("${PORTAL_PORT}" "${WEBUI_PORT}" "${MODEL_MANAGER_PORT}" "${OLLAMA_PORT}" "${DOZZLE_PORT}")
_fw_labels=("Portal (unified UI)" "Open WebUI (chat)" "Model Manager" "Ollama API" "Dozzle (logs)")
_fw_removed=()

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  info "ufw is active — removing olama rules..."
  for i in "${!_fw_ports[@]}"; do
    p="${_fw_ports[$i]}"
    if ufw status | grep -qE "^${p}[/ ]"; then
      ufw delete allow "${p}/tcp" >/dev/null 2>&1 \
        && _fw_removed+=("${p}/tcp (${_fw_labels[$i]})")
    else
      info "  Port ${p} not in ufw — skipping."
    fi
  done
  [[ ${#_fw_removed[@]} -gt 0 ]] \
    && success "ufw: removed rules for: ${_fw_removed[*]}" \
    || info "ufw: no olama rules found — already clean."

elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
  info "firewalld is active — removing olama rules..."
  for i in "${!_fw_ports[@]}"; do
    p="${_fw_ports[$i]}"
    if firewall-cmd --query-port="${p}/tcp" --permanent &>/dev/null; then
      firewall-cmd --permanent --remove-port="${p}/tcp" >/dev/null 2>&1 \
        && _fw_removed+=("${p}/tcp (${_fw_labels[$i]})")
    else
      info "  Port ${p} not in firewalld — skipping."
    fi
  done
  [[ ${#_fw_removed[@]} -gt 0 ]] && firewall-cmd --reload >/dev/null
  [[ ${#_fw_removed[@]} -gt 0 ]] \
    && success "firewalld: removed rules for: ${_fw_removed[*]}" \
    || info "firewalld: no olama rules found — already clean."

else
  info "No active ufw or firewalld detected — skipping firewall step."
fi

# ── Remove install directory (stack files, not data) ──────────────────────────
sep
if [[ -d "$INSTALL_DIR" ]]; then
  # Safety: never delete if install dir contains or overlaps the data dir
  if [[ "$DATA_DIR" == "${INSTALL_DIR}"* || "$INSTALL_DIR" == "${DATA_DIR}"* ]]; then
    warn "Install dir ${INSTALL_DIR} overlaps with data dir ${DATA_DIR} — skipping removal."
  else
    info "Removing stack files at ${INSTALL_DIR}..."
    sudo rm -rf "$INSTALL_DIR" \
      && success "Removed ${INSTALL_DIR}"
  fi
else
  info "Install directory ${INSTALL_DIR} not found — nothing to remove."
fi

# ── Purge data directory ───────────────────────────────────────────────────────
if $PURGE_DATA; then
  sep
  info "Purging data directory ${DATA_DIR}..."
  if [[ -d "$DATA_DIR" ]]; then
    _size=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo "?")
    sudo rm -rf "$DATA_DIR" \
      && success "Deleted ${DATA_DIR}  (freed ~${_size})"
  else
    info "Data directory ${DATA_DIR} not found — nothing to delete."
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
sep
success "Olama stack has been uninstalled."
echo

if ! $PURGE_DATA && [[ -d "$DATA_DIR" ]]; then
  echo -e "  ${YELLOW}Your data has been kept at: ${DATA_DIR}${NC}"
  echo    "    ├── models/     — downloaded AI model weights"
  echo    "    ├── webui/      — chat history, RAG documents, settings"
  echo    "    ├── searxng/    — SearXNG config"
  echo    "    └── pipelines/  — custom pipeline scripts"
  echo
  echo    "  To delete it now:  sudo rm -rf ${DATA_DIR}"
  echo    "  To reinstall:      bash <(curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/install.sh)"
  echo
fi

# Hint: free up build cache if the user wants to reclaim more disk space
echo    "  To also free Docker build cache (saves several GB):"
echo    "    docker builder prune --all"
echo
echo    "  Full uninstall log: ${LOG_FILE}"
sep
