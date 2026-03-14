#!/usr/bin/env bash
# =============================================================================
# logs.sh — Olama log viewer and exporter
#
# Usage:
#   bash scripts/logs.sh                  # live tail all containers
#   bash scripts/logs.sh tail [name]      # live tail one container
#   bash scripts/logs.sh show [name]      # dump recent logs to terminal
#   bash scripts/logs.sh export           # save all logs to DATA_DIR/logs/
#   bash scripts/logs.sh errors [name]    # show only ERROR/WARN lines
#   bash scripts/logs.sh status           # show container health and categories
#
# Container names: olama | open-webui | searxng | all (default)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config — reads DATA_DIR from docker/.env if present
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../docker/.env"

DATA_DIR="/opt/olama"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  DATA_DIR="$(grep -E '^DATA_DIR=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)"
  DATA_DIR="${DATA_DIR:-/opt/olama}"
fi

LOG_DIR="${DATA_DIR}/logs"
CONTAINERS=(olama open-webui searxng)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[33m[WARN]\033[0m  %s\n' "$*"; }
err()   { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }
ok()    { printf '\033[32m[ OK ]\033[0m  %s\n' "$*"; }
sep()   { printf '%s\n' "──────────────────────────────────────────────────────"; }

container_running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}

resolve_containers() {
  local target="${1:-all}"
  if [[ "$target" == "all" ]]; then
    echo "${CONTAINERS[@]}"
  elif printf '%s\n' "${CONTAINERS[@]}" | grep -qx "$target"; then
    echo "$target"
  else
    err "Unknown container: $target"
    err "Valid names: ${CONTAINERS[*]} | all"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# status — show categories, running state, and data paths
# ---------------------------------------------------------------------------
cmd_status() {
  bold "Olama Stack — Container Status"
  sep

  declare -A CATEGORY=(
    [olama]="AI CORE"
    [open-webui]="INTERFACE"
    [searxng]="SEARCH"
  )
  declare -A DATA_PATH=(
    [olama]="${DATA_DIR}/models"
    [open-webui]="${DATA_DIR}/webui"
    [searxng]="${DATA_DIR}/searxng"
  )

  for c in "${CONTAINERS[@]}"; do
    printf '\n  %-12s  [%s]\n' "$c" "${CATEGORY[$c]}"
    if container_running "$c"; then
      ok "running"
    else
      warn "stopped / not found"
    fi
    printf '  data path : %s\n' "${DATA_PATH[$c]}"
    if [[ -d "${DATA_PATH[$c]}" ]]; then
      printf '  disk used : %s\n' "$(du -sh "${DATA_PATH[$c]}" 2>/dev/null | cut -f1)"
    fi
    sep
  done

  printf '\nLogs export directory: %s\n' "$LOG_DIR"
}

# ---------------------------------------------------------------------------
# show — dump the last N log lines to the terminal
# ---------------------------------------------------------------------------
cmd_show() {
  local target="${1:-all}"
  local lines="${2:-100}"
  local targets
  read -ra targets <<< "$(resolve_containers "$target")"

  for c in "${targets[@]}"; do
    bold "── $c (last $lines lines) ──────────────────────────"
    if container_running "$c"; then
      docker logs --tail "$lines" "$c" 2>&1
    else
      warn "$c is not running — cannot fetch live logs"
    fi
    echo
  done
}

# ---------------------------------------------------------------------------
# tail — follow logs in real time (Ctrl-C to stop)
# ---------------------------------------------------------------------------
cmd_tail() {
  local target="${1:-all}"
  local targets
  read -ra targets <<< "$(resolve_containers "$target")"

  if [[ ${#targets[@]} -eq 1 ]]; then
    info "Following logs for ${targets[0]} — Ctrl-C to stop"
    docker logs -f "${targets[0]}" 2>&1
  else
    info "Following logs for all containers — Ctrl-C to stop"
    # Use docker compose logs for multi-container tail (prefixes each line)
    cd "${SCRIPT_DIR}/../docker"
    docker compose logs -f --tail=50 "${targets[@]}"
  fi
}

# ---------------------------------------------------------------------------
# errors — filter for ERROR, WARNING, WARN, CRITICAL lines
# ---------------------------------------------------------------------------
cmd_errors() {
  local target="${1:-all}"
  local lines="${2:-500}"
  local targets
  read -ra targets <<< "$(resolve_containers "$target")"

  bold "Filtering for errors and warnings"
  sep

  for c in "${targets[@]}"; do
    local out
    if container_running "$c"; then
      out=$(docker logs --tail "$lines" "$c" 2>&1 \
        | grep -iE "(error|warn|warning|critical|exception|traceback|fatal)" || true)
    else
      warn "$c is not running"
      continue
    fi

    if [[ -n "$out" ]]; then
      bold "── $c ──"
      echo "$out"
      echo
    else
      ok "$c — no errors/warnings in last $lines lines"
    fi
  done
}

# ---------------------------------------------------------------------------
# export — save all logs to DATA_DIR/logs/<container>.log
# ---------------------------------------------------------------------------
cmd_export() {
  mkdir -p "$LOG_DIR"
  info "Saving logs to $LOG_DIR/"
  sep

  for c in "${CONTAINERS[@]}"; do
    local out_file="${LOG_DIR}/${c}.log"
    if container_running "$c"; then
      docker logs "$c" > "$out_file" 2>&1
      local size
      size=$(du -sh "$out_file" | cut -f1)
      ok "$c → ${out_file}  (${size})"
    else
      warn "$c is not running — skipped"
    fi
  done

  # Write a summary file with timestamps and container info
  local summary="${LOG_DIR}/export-summary.txt"
  {
    echo "Olama Log Export"
    echo "Generated : $(date)"
    echo "DATA_DIR  : ${DATA_DIR}"
    echo
    echo "Files:"
    for c in "${CONTAINERS[@]}"; do
      local f="${LOG_DIR}/${c}.log"
      if [[ -f "$f" ]]; then
        printf '  %-20s  %s  %s lines\n' \
          "$f" \
          "$(du -sh "$f" | cut -f1)" \
          "$(wc -l < "$f")"
      fi
    done
  } > "$summary"

  echo
  info "Summary written to ${summary}"
  info "To search for errors: grep -iE 'error|warn' ${LOG_DIR}/*.log"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
CMD="${1:-tail}"
shift || true

case "$CMD" in
  status)  cmd_status "$@" ;;
  show)    cmd_show "$@" ;;
  tail)    cmd_tail "$@" ;;
  errors)  cmd_errors "$@" ;;
  export)  cmd_export "$@" ;;
  *)
    bold "Usage:"
    echo "  bash scripts/logs.sh status              # container health + categories"
    echo "  bash scripts/logs.sh show [name] [lines] # dump recent logs"
    echo "  bash scripts/logs.sh tail [name]         # live follow logs"
    echo "  bash scripts/logs.sh errors [name]       # errors and warnings only"
    echo "  bash scripts/logs.sh export              # save all logs to ${LOG_DIR}/"
    echo
    echo "  name: olama | open-webui | searxng | all (default: all)"
    exit 1
    ;;
esac
