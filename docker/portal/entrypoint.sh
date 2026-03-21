#!/bin/sh
# Inject port numbers from env vars into the HTML template at container start.
# The HTML uses window.location.hostname so no host is hardcoded.
set -e

export WEBUI_PORT="${WEBUI_PORT:-45213}"
export MODEL_MANAGER_PORT="${MODEL_MANAGER_PORT:-45214}"
export DOZZLE_PORT="${DOZZLE_PORT:-9999}"

envsubst '${WEBUI_PORT} ${MODEL_MANAGER_PORT} ${DOZZLE_PORT}' \
  < /tmp/index.html.template \
  > /usr/share/nginx/html/index.html

exec "$@"
