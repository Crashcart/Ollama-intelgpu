#!/usr/bin/env bash
# =============================================================================
# logs.sh — Olama log viewer, exporter, and debug mode manager
#
# Usage:
#   bash scripts/logs.sh                      # live tail all containers
#   bash scripts/logs.sh status               # container health, categories, debug state
#   bash scripts/logs.sh tail [name]          # live tail one or all containers
#   bash scripts/logs.sh show [name] [lines]  # dump recent logs to terminal
#   bash scripts/logs.sh errors [name]        # classify errors: CRITICAL / SELF-RESOLVING / UNKNOWN
#   bash scripts/logs.sh diagnose [lines]     # quick severity count across all containers
#   bash scripts/logs.sh export               # save all logs to DATA_DIR/logs/
#   bash scripts/logs.sh debug-on             # enable verbose logging, restart containers
#   bash scripts/logs.sh debug-off            # restore normal logging, restart containers
#
# Error severity levels (used by 'errors' and 'diagnose'):
#   CRITICAL       — GPU failure, OOM, database corruption, auth errors, crashes
#                    → Needs immediate attention; stack may be broken
#   SELF-RESOLVING — Startup races, transient timeouts, shutdown noise
#                    → Safe to ignore if not seen after containers are healthy
#   UNKNOWN        — Other warnings not in either category
#                    → Investigate if seen repeatedly after a healthy start
#
# Container names: olama | open-webui | searxng | pipelines | all (default)
#
# Debug mode changes per container:
#   olama      OLLAMA_DEBUG 0→1               GPU, model load, token traces
#   open-webui WEBUI_LOG_LEVEL INFO→DEBUG     every request, RAG, embed, search
#   searxng    SEARXNG_DEBUG false→true       per-engine calls, ranking details
#   pipelines  (always verbose — no separate debug flag)
#   rotation   LOG_MAX_SIZE 10m→50m / FILES 5→10  more headroom during debug
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config — reads values from docker/.env if present
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../docker/.env"
COMPOSE_DIR="${SCRIPT_DIR}/../docker"

_read_env() {
  # _read_env KEY [default]
  local key="$1" default="${2:-}"
  if [[ -f "$ENV_FILE" ]]; then
    local val
    val="$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
    echo "${val:-$default}"
  else
    echo "$default"
  fi
}

_set_env() {
  # _set_env KEY VALUE  — updates or appends the key in docker/.env
  local key="$1" val="$2"
  if [[ ! -f "$ENV_FILE" ]]; then
    err "docker/.env not found. Copy .env.example → docker/.env first."
    exit 1
  fi
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    # Replace existing line (BSD and GNU sed compatible)
    sed -i.bak "s|^${key}=.*|${key}=${val}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

DATA_DIR="$(_read_env DATA_DIR /opt/olama)"
DOZZLE_PORT="$(_read_env DOZZLE_PORT 9999)"
LOG_DIR="${DATA_DIR}/logs"
CONTAINERS=(olama open-webui searxng pipelines)
# Maps compose service name → actual container_name (as set in docker-compose.yml)
declare -A CNAME=(
  [olama]="olama"
  [open-webui]="olama-open-webui"
  [searxng]="olama-searxng"
  [pipelines]="olama-pipelines"
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
info()   { printf '\033[36m[INFO]\033[0m  %s\n' "$*"; }
warn()   { printf '\033[33m[WARN]\033[0m  %s\n' "$*"; }
err()    { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }
ok()     { printf '\033[32m[ OK ]\033[0m  %s\n' "$*"; }
debug()  { printf '\033[35m[DEBUG]\033[0m %s\n' "$*"; }
sep()    { printf '%s\n' "──────────────────────────────────────────────────────"; }

# Accepts a service name; looks up the actual container_name via CNAME.
container_running() {
  local cname="${CNAME[$1]:-$1}"
  docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null | grep -q true
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
# status — health, categories, disk usage, and current debug state
# ---------------------------------------------------------------------------
cmd_status() {
  bold "Olama Stack — Container Status"
  sep

  declare -A CATEGORY=(
    [olama]="AI CORE"
    [open-webui]="INTERFACE"
    [searxng]="SEARCH"
    [pipelines]="PIPELINES"
  )
  declare -A DATA_PATH=(
    [olama]="${DATA_DIR}/models"
    [open-webui]="${DATA_DIR}/webui"
    [searxng]="${DATA_DIR}/searxng"
    [pipelines]="${DATA_DIR}/pipelines"
  )

  # Read current debug state from .env
  local debug_mode ollama_debug webui_log searxng_debug
  debug_mode="$(_read_env DEBUG_MODE false)"
  ollama_debug="$(_read_env OLLAMA_DEBUG 0)"
  webui_log="$(_read_env WEBUI_LOG_LEVEL INFO)"
  searxng_debug="$(_read_env SEARXNG_DEBUG false)"
  local log_max_size log_max_files
  log_max_size="$(_read_env LOG_MAX_SIZE 10m)"
  log_max_files="$(_read_env LOG_MAX_FILES 5)"

  printf '\n'
  if [[ "$debug_mode" == "true" ]]; then
    debug "DEBUG MODE IS ON — logs are verbose; run 'debug-off' to restore normal levels"
  else
    info "Debug mode is OFF (normal INFO logging)"
  fi
  printf '\n'

  for c in "${CONTAINERS[@]}"; do
    printf '  %-12s  [%s]\n' "$c" "${CATEGORY[$c]}"

    if container_running "$c"; then
      # Show Docker health state (healthy / unhealthy / starting / none)
      local health
      health="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' "${CNAME[$c]:-$c}" 2>/dev/null || echo "unknown")"
      case "$health" in
        healthy)        ok "running — $health" ;;
        starting)       info "running — $health (waiting for healthcheck)" ;;
        unhealthy)      err "running — $health  ← check logs: bash scripts/logs.sh errors $c" ;;
        *)              warn "running — $health" ;;
      esac
    else
      warn "stopped / not found"
    fi

    printf '  data path : %s\n' "${DATA_PATH[$c]}"
    if [[ -d "${DATA_PATH[$c]}" ]]; then
      printf '  disk used : %s\n' "$(du -sh "${DATA_PATH[$c]}" 2>/dev/null | cut -f1)"
    fi

    # Per-container debug detail
    case "$c" in
      olama)      printf '  log level : OLLAMA_DEBUG=%s\n'    "$ollama_debug" ;;
      open-webui) printf '  log level : WEBUI_LOG_LEVEL=%s\n' "$webui_log" ;;
      searxng)    printf '  log level : SEARXNG_DEBUG=%s\n'   "$searxng_debug" ;;
      pipelines)  printf '  log level : always verbose (no separate debug flag)\n' ;;
    esac
    sep
  done

  printf '\nLog rotation  : max-size=%s  max-files=%s\n' "$log_max_size" "$log_max_files"
  printf 'Log export dir: %s\n' "$LOG_DIR"
  printf '\nWeb log viewer: http://localhost:%s  (Dozzle — live logs in browser)\n' "$DOZZLE_PORT"
  printf 'Toggle debug  : bash scripts/logs.sh debug-on | debug-off\n'
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
      docker logs --tail "$lines" "${CNAME[$c]:-$c}" 2>&1
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
    docker logs -f "${CNAME[${targets[0]}]:-${targets[0]}}" 2>&1
  else
    info "Following logs for all containers — Ctrl-C to stop"
    cd "$COMPOSE_DIR"
    docker compose logs -f --tail=50 "${targets[@]}"
  fi
}

# ---------------------------------------------------------------------------
# errors — filter for ERROR / WARN / CRITICAL / EXCEPTION lines
#          and classify as SELF-RESOLVING (benign) vs CRITICAL (needs action)
# ---------------------------------------------------------------------------

# Patterns that appear frequently in healthy operation and do NOT need action.
# These are startup races, transient timeouts, graceful-shutdown noise, etc.
# grep -E compatible.
BENIGN_PATTERNS=(
  # Startup races — services come up in order; these clear once healthy
  "connection refused"
  "connection reset by peer"
  "no such host"
  "context deadline exceeded"
  "dial tcp.*connection refused"
  # Ollama model-unload on idle (expected with OLLAMA_KEEP_ALIVE)
  "unloading model"
  # Dozzle graceful-shutdown stream close
  "failed to shut down"
  "stream closed"
  # Open WebUI embedding retry on cold start
  "retrying.*embedding"
  # SearXNG rate-limiter warm-up
  "Too Many Requests"
  "429"
  # Docker health-check during start_period (before pass/fail counts)
  "health_status: starting"
  # Pipelines first-run pip install noise
  "WARNING: pip"
  "DEPRECATION"
)

# Patterns that indicate a real problem requiring attention.
CRITICAL_PATTERNS=(
  # GPU / hardware
  "no GPU device"
  "GPU not found"
  "failed to initialize.*gpu"
  "OpenCL.*failed"
  "level_zero.*error"
  # Out of memory
  "out of memory"
  "OOM"
  "ENOMEM"
  "cannot allocate"
  # Model load hard failures
  "failed to load model"
  "model.*not found"
  "error loading"
  # Database / storage
  "database.*corrupt"
  "disk.*full"
  "no space left"
  "read-only file system"
  # Auth / secrets
  "invalid api key"
  "unauthorized"
  "permission denied"
  # Crash / panic
  "panic:"
  "SIGSEGV"
  "SIGABRT"
  "fatal error"
  "core dumped"
)

_build_pattern() {
  # Join array elements with | for use in grep -iE
  local IFS='|'
  echo "${*}"
}

cmd_errors() {
  local target="${1:-all}"
  local lines="${2:-500}"
  local targets
  read -ra targets <<< "$(resolve_containers "$target")"

  bold "Filtering for errors and warnings (last $lines lines each)"
  printf '  SELF-RESOLVING : known startup/shutdown noise — usually safe to ignore\n'
  printf '  CRITICAL       : hardware, memory, storage, auth, or crash failures\n'
  printf '  UNKNOWN        : other warnings/errors — investigate if persistent\n'
  sep

  local benign_pat critical_pat
  benign_pat="$(_build_pattern "${BENIGN_PATTERNS[@]}")"
  critical_pat="$(_build_pattern "${CRITICAL_PATTERNS[@]}")"

  for c in "${targets[@]}"; do
    if ! container_running "$c"; then
      warn "$c is not running"
      continue
    fi

    local raw_logs
    raw_logs=$(docker logs --tail "$lines" "${CNAME[$c]:-$c}" 2>&1)

    # All error/warn lines from this container
    local all_matches
    all_matches=$(echo "$raw_logs" \
      | grep -iE "(error|warn|warning|critical|exception|traceback|fatal)" || true)

    if [[ -z "$all_matches" ]]; then
      ok "$c — no errors/warnings in last $lines lines"
      continue
    fi

    bold "── $c ──"

    # --- CRITICAL ---
    local critical_lines
    critical_lines=$(echo "$all_matches" | grep -iE "$critical_pat" || true)
    if [[ -n "$critical_lines" ]]; then
      printf '\033[31m  [CRITICAL — needs attention]\033[0m\n'
      echo "$critical_lines" | sed 's/^/    /'
      echo
    fi

    # --- SELF-RESOLVING ---
    local benign_lines
    benign_lines=$(echo "$all_matches" | grep -iE "$benign_pat" || true)
    if [[ -n "$benign_lines" ]]; then
      printf '\033[33m  [SELF-RESOLVING — usually safe to ignore]\033[0m\n'
      echo "$benign_lines" | sed 's/^/    /'
      echo
    fi

    # --- UNKNOWN (matched errors but not in either category) ---
    local known_lines unknown_lines
    known_lines=$(echo "$all_matches" | grep -iE "$critical_pat|$benign_pat" || true)
    if [[ -n "$known_lines" ]]; then
      unknown_lines=$(comm -23 \
        <(echo "$all_matches" | sort) \
        <(echo "$known_lines"  | sort) || true)
    else
      unknown_lines="$all_matches"
    fi
    if [[ -n "$unknown_lines" ]]; then
      printf '\033[36m  [UNKNOWN — investigate if seen repeatedly]\033[0m\n'
      echo "$unknown_lines" | sed 's/^/    /'
      echo
    fi

    sep
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
      docker logs "${CNAME[$c]:-$c}" > "$out_file" 2>&1
      local size
      size=$(du -sh "$out_file" | cut -f1)
      ok "$c → ${out_file}  (${size})"
    else
      warn "$c is not running — skipped"
    fi
  done

  local summary="${LOG_DIR}/export-summary.txt"
  {
    echo "Olama Log Export"
    echo "Generated  : $(date)"
    echo "DATA_DIR   : ${DATA_DIR}"
    echo "DEBUG_MODE : $(_read_env DEBUG_MODE false)"
    echo
    echo "Files:"
    for c in "${CONTAINERS[@]}"; do
      local f="${LOG_DIR}/${c}.log"
      if [[ -f "$f" ]]; then
        printf '  %-24s  %s  %s lines\n' \
          "$f" \
          "$(du -sh "$f" | cut -f1)" \
          "$(wc -l < "$f")"
      fi
    done
  } > "$summary"

  echo
  info "Summary written to ${summary}"
  info "Search all logs: grep -iE 'error|warn' ${LOG_DIR}/*.log"
}

# ---------------------------------------------------------------------------
# debug-on — enable verbose logging on all containers then recreate them
# ---------------------------------------------------------------------------
cmd_debug_on() {
  if [[ ! -f "$ENV_FILE" ]]; then
    err "docker/.env not found. Copy .env.example → docker/.env first."
    exit 1
  fi

  bold "Enabling debug mode"
  sep

  # --- Apply verbose settings ---
  _set_env DEBUG_MODE    true
  _set_env OLLAMA_DEBUG  1
  _set_env WEBUI_LOG_LEVEL DEBUG
  _set_env SEARXNG_DEBUG true

  # Increase log rotation so verbose output is not truncated prematurely
  _set_env LOG_MAX_SIZE  50m
  _set_env LOG_MAX_FILES 10

  info "Settings written to docker/.env:"
  printf '  OLLAMA_DEBUG     = 1          (was 0)\n'
  printf '  WEBUI_LOG_LEVEL  = DEBUG      (was INFO)\n'
  printf '  SEARXNG_DEBUG    = true       (was false)\n'
  printf '  LOG_MAX_SIZE     = 50m        (was 10m)\n'
  printf '  LOG_MAX_FILES    = 10         (was 5)\n'
  echo

  # What each container now logs at DEBUG:
  bold "What you will see in debug mode:"
  printf '  olama      : GPU device selection, model layer loading, KV cache,\n'
  printf '               per-token generation timing, context window management\n'
  printf '  open-webui : every HTTP request/response, RAG document retrieval,\n'
  printf '               embedding API calls, web search queries and results,\n'
  printf '               ChromaDB vector store operations\n'
  printf '  searxng    : per-engine HTTP calls, response parsing, result\n'
  printf '               deduplication and ranking steps\n'
  echo

  warn "Log files will grow much faster in debug mode."
  warn "Disable with: bash scripts/logs.sh debug-off  when done investigating."
  echo

  # Recreate containers so they pick up the new env vars
  info "Recreating containers with updated environment..."
  cd "$COMPOSE_DIR"
  docker compose up -d --force-recreate olama open-webui searxng pipelines
  echo
  ok "Debug mode ON — follow logs with: bash scripts/logs.sh tail"
}

# ---------------------------------------------------------------------------
# debug-off — restore normal INFO logging and recreate containers
# ---------------------------------------------------------------------------
cmd_debug_off() {
  if [[ ! -f "$ENV_FILE" ]]; then
    err "docker/.env not found. Copy .env.example → docker/.env first."
    exit 1
  fi

  bold "Disabling debug mode — restoring normal log levels"
  sep

  # --- Restore defaults ---
  _set_env DEBUG_MODE    false
  _set_env OLLAMA_DEBUG  0
  _set_env WEBUI_LOG_LEVEL INFO
  _set_env SEARXNG_DEBUG false
  _set_env LOG_MAX_SIZE  10m
  _set_env LOG_MAX_FILES 5

  info "Settings restored in docker/.env:"
  printf '  OLLAMA_DEBUG     = 0\n'
  printf '  WEBUI_LOG_LEVEL  = INFO\n'
  printf '  SEARXNG_DEBUG    = false\n'
  printf '  LOG_MAX_SIZE     = 10m\n'
  printf '  LOG_MAX_FILES    = 5\n'
  echo

  info "Exporting final debug logs before restart..."
  cmd_export
  echo

  info "Recreating containers with normal environment..."
  cd "$COMPOSE_DIR"
  docker compose up -d --force-recreate olama open-webui searxng pipelines
  echo
  ok "Debug mode OFF — logs saved to ${LOG_DIR}/"
  info "Review debug logs: grep -iE 'error|warn' ${LOG_DIR}/*.log"
}

# ---------------------------------------------------------------------------
# diagnose — quick health summary: counts per severity, highlights CRITICAL
# ---------------------------------------------------------------------------
cmd_diagnose() {
  local lines="${1:-1000}"

  bold "Olama Stack — Diagnostic Summary (last $lines lines per container)"
  sep
  printf '  Scanning for CRITICAL / SELF-RESOLVING / UNKNOWN issues...\n\n'

  local benign_pat critical_pat
  benign_pat="$(_build_pattern "${BENIGN_PATTERNS[@]}")"
  critical_pat="$(_build_pattern "${CRITICAL_PATTERNS[@]}")"

  local any_critical=0

  for c in "${CONTAINERS[@]}"; do
    if ! container_running "$c"; then
      warn "$c  — NOT RUNNING"
      continue
    fi

    local health
    health="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${CNAME[$c]:-$c}" 2>/dev/null || echo "unknown")"

    local raw_logs all_matches
    raw_logs=$(docker logs --tail "$lines" "${CNAME[$c]:-$c}" 2>&1)
    all_matches=$(echo "$raw_logs" \
      | grep -iE "(error|warn|warning|critical|exception|traceback|fatal)" || true)

    local n_critical n_benign n_unknown total
    n_critical=0; n_benign=0; n_unknown=0; total=0

    if [[ -n "$all_matches" ]]; then
      n_critical=$(echo "$all_matches" | grep -icE "$critical_pat" || true)
      n_benign=$(echo "$all_matches"   | grep -icE "$benign_pat"   || true)
      total=$(echo "$all_matches" | wc -l)
      n_unknown=$(( total - n_critical - n_benign ))
      [[ $n_unknown -lt 0 ]] && n_unknown=0
    fi

    # Health icon
    local health_tag
    case "$health" in
      healthy)   health_tag="\033[32mhealthy\033[0m" ;;
      unhealthy) health_tag="\033[31mUNHEALTHY\033[0m" ;;
      starting)  health_tag="\033[33mstarting\033[0m" ;;
      *)         health_tag="\033[36m$health\033[0m" ;;
    esac

    printf "  %-14s  health: ${health_tag}\n" "$c"

    if [[ "$total" -eq 0 ]]; then
      ok "  no warnings/errors found"
    else
      [[ $n_critical -gt 0 ]] && { printf "\033[31m    CRITICAL      : %d lines\033[0m\n" "$n_critical"; any_critical=1; }
      [[ $n_unknown  -gt 0 ]] && printf "\033[36m    UNKNOWN        : %d lines\033[0m\n" "$n_unknown"
      [[ $n_benign   -gt 0 ]] && printf "\033[33m    SELF-RESOLVING : %d lines (startup/shutdown noise)\033[0m\n" "$n_benign"
    fi
    echo
  done

  sep
  if [[ $any_critical -eq 1 ]]; then
    printf '\033[31m  ACTION REQUIRED: CRITICAL issues found.\033[0m\n'
    printf '  Run to see details:\n'
    printf '    bash scripts/logs.sh errors          # classify all containers\n'
    printf '    bash scripts/logs.sh errors <name>   # focus on one container\n'
    printf '    bash scripts/logs.sh debug-on        # capture full traces\n'
  else
    ok "No CRITICAL errors detected — stack looks healthy"
    printf '  SELF-RESOLVING or UNKNOWN warnings may still appear; use:\n'
    printf '    bash scripts/logs.sh errors          # see full classification\n'
  fi
  echo
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
CMD="${1:-tail}"
shift || true

case "$CMD" in
  status)    cmd_status   "$@" ;;
  show)      cmd_show     "$@" ;;
  tail)      cmd_tail     "$@" ;;
  errors)    cmd_errors   "$@" ;;
  diagnose)  cmd_diagnose "$@" ;;
  export)    cmd_export   "$@" ;;
  debug-on)  cmd_debug_on  ;;
  debug-off) cmd_debug_off ;;
  *)
    bold "Olama log helper"
    echo
    echo "  bash scripts/logs.sh status                # health, categories, debug state"
    echo "  bash scripts/logs.sh tail [name]           # live follow logs (Ctrl-C to stop)"
    echo "  bash scripts/logs.sh show [name] [lines]   # dump recent lines to terminal"
    echo "  bash scripts/logs.sh errors [name]         # classify errors: CRITICAL / SELF-RESOLVING / UNKNOWN"
    echo "  bash scripts/logs.sh diagnose [lines]      # quick severity summary across all containers"
    echo "  bash scripts/logs.sh export                # save all logs to ${LOG_DIR}/"
    echo
    echo "  bash scripts/logs.sh debug-on              # verbose logging, restart containers"
    echo "  bash scripts/logs.sh debug-off             # normal logging, export + restart"
    echo
    echo "  name: olama | open-webui | searxng | pipelines | all (default: all)"
    echo "  (these are compose service names; container names have the olama- prefix)"
    exit 1
    ;;
esac
