#!/bin/sh
# Inject port numbers from env vars into the HTML template at container start.
# The HTML uses window.location.hostname so no host is hardcoded.
set -e

export WEBUI_PORT="${WEBUI_PORT:-45213}"
export MODEL_MANAGER_PORT="${MODEL_MANAGER_PORT:-45214}"
export GHOST_RUNNER_PORT="${GHOST_RUNNER_PORT:-45215}"
export MEMORY_PORT="${MEMORY_PORT:-45216}"
export FILE_CATALOG_PORT="${FILE_CATALOG_PORT:-45217}"
export DOZZLE_PORT="${DOZZLE_PORT:-9999}"
export OLLAMA_PORT="${OLLAMA_PORT:-11434}"

envsubst '${WEBUI_PORT} ${MODEL_MANAGER_PORT} ${GHOST_RUNNER_PORT} ${MEMORY_PORT} ${FILE_CATALOG_PORT} ${DOZZLE_PORT} ${OLLAMA_PORT}' \
  < /tmp/index.html.template \
  > /usr/share/nginx/html/index.html

exec "$@"
