#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — Remove the Ollama Intel GPU stack
#
# One-liner (mirrors install.sh — no local clone required):
#   bash <(curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/uninstall.sh)
#
# From a local clone:
#   bash scripts/uninstall.sh [OPTIONS]
#
# Options:
#   --data-dir    DIR   Where data was stored (default: /opt/ollama)
#   --install-dir DIR   Where stack files were installed (default: /opt/ollama-stack)
#   --keep-data         Keep the data directory (models, history, config)
#   --keep-images       Keep Docker images (default: remove all ollama images)
#   --yes / -y          Skip confirmation prompts
# =============================================================================

set -euo pipefail

# ── Survive terminal disconnect; capture all output ───────────────────────────
trap '' HUP

LOG_FILE="${LOG_FILE:-/tmp/ollama-uninstall.log}"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/ollama-uninstall-$(id -u).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Defaults ──────────────────────────────────────────────────────────────────
DATA_DIR="${DATA_DIR:-/opt/ollama}"
INSTALL_DIR="${INSTALL_DIR:-/opt/ollama-stack}"
PORTAL_PORT="${PORTAL_PORT:-45200}"
WEBUI_PORT="${WEBUI_PORT:-45213}"
MODEL_MANAGER_PORT="${MODEL_MANAGER_PORT:-45214}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
DOZZLE_PORT="${DOZZLE_PORT:-9999}"
ALLOW_FROM="${ALLOW_FROM:-any}"
PROJECT_PREFIX="${PROJECT_PREFIX:-olama-intelgpu}"
PURGE_DATA=true
KEEP_IMAGES=false
YES=false

# ── Color helpers ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[ollama]${NC} $*"; }
success() { echo -e "${GREEN}[ollama]${NC} $*"; }
warn()    { echo -e "${YELLOW}[ollama]${NC} $*"; }
error()   { echo -e "${RED}[ollama]${NC} $*" >&2; echo -e "${RED}[ollama]${NC} Full log: ${LOG_FILE}" >&2; exit 1; }
sep()     { echo "──────────────────────────────────────────────────────"; }

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --data-dir)    DATA_DIR="$2";    shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --keep-data)   PURGE_DATA=false; shift ;;
    --purge)       PURGE_DATA=true;  shift ;;  # kept for backwards compat; now the default
    --keep-images) KEEP_IMAGES=true; shift ;;
    --yes|-y)      YES=true;         shift ;;
    --help|-h)
      echo "Usage: $0 [--data-dir DIR] [--install-dir DIR] [--keep-data] [--keep-images] [--yes]"
      echo
      echo "  --data-dir    DIR   Where data is stored   (default: /opt/ollama)"
      echo "  --install-dir DIR   Where stack files live (default: /opt/ollama-stack)"
      echo "  --keep-data         Keep the data directory (models, history, config)"
      echo "  --keep-images       Keep Docker images     (default: remove all ollama images)"
      echo "  --yes / -y          Skip confirmation prompts"
      exit 0 ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

# ── Read installed config from .env ───────────────────────────────────────────
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
  _v=$(_env_read ALLOW_FROM);         [[ -n "$_v" ]] && ALLOW_FROM="$_v"
  _v=$(_env_read PROJECT_PREFIX);     [[ -n "$_v" ]] && PROJECT_PREFIX="$_v"
  OLLAMA_VERSION=$(_env_read OLLAMA_VERSION || echo "latest")
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

# ── Inventory what will be removed ────────────────────────────────────────────
_ollama_imgs=()
while IFS= read -r _img; do
  [[ -n "$_img" ]] && _ollama_imgs+=("$_img")
done < <(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null \
  | grep -E "^(ollama|ollama-model-manager|ollama-portal):" || true)

_ollama_vols=()
while IFS= read -r _vol; do
  [[ -n "$_vol" ]] && _ollama_vols+=("$_vol")
done < <(docker volume ls -q --filter "name=ollama" 2>/dev/null || true)

_ollama_nets=()
while IFS= read -r _net; do
  [[ -n "$_net" ]] && _ollama_nets+=("$_net")
done < <(docker network ls --format "{{.Name}}" 2>/dev/null \
  | grep -E "^(ollama|docker_default$)" || true)

# ── Show what will happen ──────────────────────────────────────────────────────
sep
echo -e "${BOLD}Ollama Stack — Uninstaller${NC}"
sep
echo
echo "  Uninstall log: ${LOG_FILE}"
echo "     → tail -f ${LOG_FILE}  (safe to close terminal)"
echo
echo "  This will:"
echo "    • Stop and remove all 7 Ollama containers"

if ! $KEEP_IMAGES; then
  if [[ ${#_ollama_imgs[@]} -gt 0 ]]; then
    echo "    • Remove Docker images:"
    for _i in "${_ollama_imgs[@]}"; do echo "        - ${_i}"; done
  else
    echo "    • Remove Docker images  (none found — already clean)"
  fi
fi

[[ ${#_ollama_vols[@]} -gt 0 ]] && \
  echo "    • Remove Docker volumes: ${_ollama_vols[*]}"
[[ ${#_ollama_nets[@]} -gt 0 ]] && \
  echo "    • Remove Docker networks: ${_ollama_nets[*]}"

echo "    • Remove firewall rules added by the installer"
[[ -d "$INSTALL_DIR" ]] && echo "    • Delete stack files at ${INSTALL_DIR}"
if $PURGE_DATA; then
  _data_size=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo "?")
  echo -e "    • ${RED}${BOLD}Delete data directory ${DATA_DIR}${NC}  ${RED}(~${_data_size} — models, history, config)${NC}"
else
  echo    "    • Leave data at ${DATA_DIR} untouched"
fi
echo
if $PURGE_DATA; then
  echo -e "  ${RED}${BOLD}WARNING: ${DATA_DIR} will be permanently deleted.${NC}"
  echo -e "  ${RED}This includes all model weights, chat history, and config.${NC}"
  echo -e "  ${YELLOW}Pass --keep-data to skip data removal.${NC}"
else
  echo -e "  ${YELLOW}Data at ${DATA_DIR} will be KEPT (pass --purge to delete it).${NC}"
fi
echo

# ── Confirmation prompt ────────────────────────────────────────────────────────
if ! $YES; then
  read -rp "  Proceed with uninstall? [y/N] " _confirm
  echo
  [[ "$_confirm" =~ ^[Yy]$ ]] || { info "Aborted — nothing was changed."; exit 0; }
fi

# ── Extra confirmation for data deletion ──────────────────────────────────────
if $PURGE_DATA && ! $YES; then
  echo -e "  ${RED}${BOLD}FINAL WARNING — this cannot be undone.${NC}"
  echo    "  All model weights, chat history, RAG documents, and config"
  echo    "  at ${DATA_DIR} will be permanently deleted."
  echo    "  (Run with --keep-data to skip this step.)"
  echo
  read -rp "  Type 'delete' to confirm data removal, or press Enter to keep data: " _purge_confirm
  echo
  if [[ "$_purge_confirm" != "delete" ]]; then
    warn "Data removal skipped — ${DATA_DIR} will be kept. Continuing with container removal only."
    PURGE_DATA=false
  fi
fi

# ── Stop and remove containers + volumes ──────────────────────────────────────
sep
info "Stopping and removing Ollama containers..."

if [[ -n "$COMPOSE_CMD" && -n "$COMPOSE_FILE" ]]; then
  info "Using compose file: ${COMPOSE_FILE}"
  cd "$(dirname "$COMPOSE_FILE")"
  $COMPOSE_CMD down --volumes --remove-orphans 2>/dev/null \
    && success "Containers, volumes, and networks removed (docker compose down)." \
    || warn "docker compose down reported an error — containers may already be gone."
  # Give the kernel a moment to release bind-mounts (e.g. the UDS socket volume)
  # before we attempt manual volume removal below.
  sleep 2
else
  warn "Compose file not found — stopping containers by name..."
  _any_removed=false
  for cname in "${PROJECT_PREFIX}-ollama" "${PROJECT_PREFIX}-open-webui" \
               "${PROJECT_PREFIX}-model-manager" "${PROJECT_PREFIX}-portal" \
               "${PROJECT_PREFIX}-searxng" "${PROJECT_PREFIX}-pipelines" \
               "${PROJECT_PREFIX}-dozzle"; do
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

  # Remove networks in fallback path
  for _net in ollama_default docker_default; do
    if docker network inspect "$_net" &>/dev/null 2>&1; then
      docker network rm "$_net" 2>/dev/null \
        && info "  Removed network: ${_net}" || true
    fi
  done
fi

# ── Remove any remaining Docker volumes ───────────────────────────────────────
# Re-query after compose down — compose may have created volumes under a
# project-prefixed name (e.g. docker_ollama_sockets) that weren't in the
# pre-run snapshot.
_remaining_vols=()
while IFS= read -r _vol; do
  [[ -n "$_vol" ]] && _remaining_vols+=("$_vol")
done < <(docker volume ls -q 2>/dev/null | grep -E "(^|_)ollama" || true)

if [[ ${#_remaining_vols[@]} -gt 0 ]]; then
  sep
  info "Removing Docker volumes..."
  for _vol in "${_remaining_vols[@]}"; do
    _removed=false
    for _try in 1 2 3; do
      if docker volume rm -f "$_vol" 2>/dev/null; then
        success "  Removed volume: ${_vol}"
        _removed=true
        break
      fi
      [[ $_try -lt 3 ]] && { info "  Volume ${_vol} busy — retrying in ${_try}s..."; sleep "$_try"; }
    done
    $_removed || warn "  Could not remove volume ${_vol} after 3 attempts — skipping."
  done
fi

# ── Remove Docker images ───────────────────────────────────────────────────────
if ! $KEEP_IMAGES; then
  sep
  info "Removing Docker images..."

  _imgs_to_remove=()
  while IFS= read -r _img; do
    [[ -n "$_img" ]] && _imgs_to_remove+=("$_img")
  done < <(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null \
    | grep -E "^(ollama|ollama-model-manager|ollama-portal):" || true)

  _imgs_removed=()
  for img in "${_imgs_to_remove[@]}"; do
    docker rmi "$img" 2>/dev/null \
      && _imgs_removed+=("$img") \
      || warn "  Could not remove ${img} — may still be referenced."
  done

  _dangling=$(docker images -q --filter "dangling=true" 2>/dev/null || true)
  [[ -n "$_dangling" ]] && echo "$_dangling" | xargs docker rmi 2>/dev/null || true \
    && info "  Removed dangling build layers."

  if [[ ${#_imgs_removed[@]} -gt 0 ]]; then
    success "Images removed: ${_imgs_removed[*]}"
  else
    info "No locally-built images found — already clean."
  fi

  echo
  info "Public registry images left in place:"
  info "  ghcr.io/open-webui/open-webui:main  ghcr.io/open-webui/pipelines:main"
  info "  searxng/searxng:latest  amir20/dozzle:latest"
  info "To remove them: docker rmi ghcr.io/open-webui/open-webui:main ghcr.io/open-webui/pipelines:main searxng/searxng:latest amir20/dozzle:latest"
fi

# ── Remove remaining ollama networks ───────────────────────────────────────────
_remaining_nets=$(docker network ls --format "{{.Name}}" 2>/dev/null \
  | grep -E "^ollama" || true)
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
_fw_labels=("Portal" "Open WebUI" "Model Manager" "Ollama API" "Dozzle (logs)")
_fw_removed=()

# Parse stored ALLOW_FROM back into a CIDR array
_parse_cidrs() {
  local raw="${1:-any}"
  IFS=',' read -ra _arr <<< "$raw"
  for c in "${_arr[@]}"; do
    c="${c// /}"
    [[ -z "$c" || "$c" == "any" || "$c" == "0.0.0.0/0" ]] && echo "any" || echo "$c"
  done | sort -u
}
mapfile -t _ALLOW_FROM_CIDRS < <(_parse_cidrs "${ALLOW_FROM:-any}")
[[ ${#_ALLOW_FROM_CIDRS[@]} -eq 0 ]] && _ALLOW_FROM_CIDRS=("any")

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  info "ufw is active — removing ollama rules..."

  for i in "${!_fw_ports[@]}"; do
    p="${_fw_ports[$i]}"
    for cidr in "${_ALLOW_FROM_CIDRS[@]}"; do
      if [[ "$cidr" == "any" ]]; then
        # Remove the simple open rule
        if ufw status | grep -qE "^${p}[/ ].*ALLOW"; then
          ufw delete allow "${p}/tcp" >/dev/null 2>&1 \
            && _fw_removed+=("${p}/tcp (${_fw_labels[$i]})")
        else
          info "  Port ${p} not in ufw — skipping."
        fi
      else
        # Remove the source-restricted rule
        if ufw status | grep -qE "${cidr}.*${p}|${p}.*${cidr}"; then
          ufw delete allow from "$cidr" to any port "$p" proto tcp >/dev/null 2>&1 \
            && _fw_removed+=("${p}/tcp from ${cidr} (${_fw_labels[$i]})")
        else
          info "  Rule for port ${p} from ${cidr} not in ufw — skipping."
        fi
      fi
    done
  done

  [[ ${#_fw_removed[@]} -gt 0 ]] \
    && success "ufw: removed rules for: ${_fw_removed[*]}" \
    || info "ufw: no ollama rules found — already clean."

elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
  info "firewalld is active — removing ollama rules..."

  for i in "${!_fw_ports[@]}"; do
    p="${_fw_ports[$i]}"
    for cidr in "${_ALLOW_FROM_CIDRS[@]}"; do
      if [[ "$cidr" == "any" ]]; then
        if firewall-cmd --query-port="${p}/tcp" --permanent &>/dev/null; then
          firewall-cmd --permanent --remove-port="${p}/tcp" >/dev/null 2>&1 \
            && _fw_removed+=("${p}/tcp (${_fw_labels[$i]})")
        else
          info "  Port ${p} not in firewalld — skipping."
        fi
      else
        _rich="rule family=\"ipv4\" source address=\"${cidr}\" port port=\"${p}\" protocol=\"tcp\" accept"
        if firewall-cmd --query-rich-rule="$_rich" --permanent &>/dev/null; then
          firewall-cmd --permanent --remove-rich-rule="$_rich" >/dev/null 2>&1 \
            && _fw_removed+=("${p}/tcp from ${cidr} (${_fw_labels[$i]})")
        else
          info "  Rich rule for port ${p} from ${cidr} not found — skipping."
        fi
      fi
    done
  done

  [[ ${#_fw_removed[@]} -gt 0 ]] && firewall-cmd --reload >/dev/null
  [[ ${#_fw_removed[@]} -gt 0 ]] \
    && success "firewalld: removed rules for: ${_fw_removed[*]}" \
    || info "firewalld: no ollama rules found — already clean."

else
  info "No active ufw or firewalld detected — skipping firewall step."
fi

# ── Remove install directory ───────────────────────────────────────────────────
sep
if [[ -d "$INSTALL_DIR" ]]; then
  # Use path-aware overlap check (require / boundary — /opt/ollama-stack must not match /opt/ollama)
  _inst_real="$(realpath -m "$INSTALL_DIR")"
  _data_real="$(realpath -m "$DATA_DIR")"
  if [[ "$_inst_real" == "$_data_real" || \
        "$_inst_real" == "$_data_real/"* || \
        "$_data_real" == "$_inst_real/"* ]]; then
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
success "Ollama stack has been uninstalled."
echo

if ! $PURGE_DATA && [[ -d "$DATA_DIR" ]]; then
  echo -e "  ${YELLOW}Your data has been kept at: ${DATA_DIR}${NC}"
  echo    "    ├── models/     — downloaded AI model weights"
  echo    "    ├── webui/      — chat history, RAG documents, settings"
  echo    "    ├── searxng/    — SearXNG config"
  echo    "    ├── pipelines/  — custom pipeline scripts"
  echo    "    └── memory/     — AI memory store"
  echo
  echo    "  To delete it now:  sudo rm -rf ${DATA_DIR}"
  echo    "  To reinstall:      bash <(curl -fsSL https://raw.githubusercontent.com/Crashcart/Olama-intelgpu/main/scripts/install.sh)"
  echo
fi

echo    "  To also free Docker build cache (saves several GB):"
echo    "    docker builder prune --all"
echo
echo    "  Full uninstall log: ${LOG_FILE}"
sep
