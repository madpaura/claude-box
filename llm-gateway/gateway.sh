#!/usr/bin/env bash
# Manage the LiteLLM sidecar that lets Claude Code talk to an in-house
# OpenAI-compatible LLM gateway.
#
#   ./llm-gateway/gateway.sh up       # start (or restart) the proxy
#   ./llm-gateway/gateway.sh status   # is it up, and does it answer?
#   ./llm-gateway/gateway.sh logs     # follow proxy logs
#   ./llm-gateway/gateway.sh down     # stop and remove it
#
# Then: claude-box --inhouse

set -euo pipefail
cd "$(dirname "$0")/.."

GW_DIR="llm-gateway"
ENV_FILE="${CLAUDE_BOX_GATEWAY_ENV:-$GW_DIR/gateway.env}"
NETWORK="${CLAUDE_BOX_NETWORK:-claude-box-net}"
NAME="${CLAUDE_BOX_GATEWAY_NAME:-claude-box-llm-gateway}"
PORT="${CLAUDE_BOX_GATEWAY_PORT:-4000}"
LITELLM_IMAGE="${LITELLM_IMAGE:-ghcr.io/berriai/litellm:v1.95.0}"
RENDERED="${CLAUDE_BOX_HOME:-$PWD/box-home}/litellm-config.yaml"

usage() { sed -n '2,12p' "$0"; exit "${1:-0}"; }

load_env() {
  [ -f "$ENV_FILE" ] || {
    echo "gateway: $ENV_FILE not found." >&2
    echo "  cp $GW_DIR/gateway.env.example $ENV_FILE && chmod 600 $ENV_FILE" >&2
    exit 1; }
  set -a; . "./$ENV_FILE"; set +a
  : "${INHOUSE_LLM_BASE_URL:?set in $ENV_FILE}"
  : "${INHOUSE_LLM_MODEL:?set in $ENV_FILE}"
  : "${LITELLM_MASTER_KEY:?set in $ENV_FILE}"
  export INHOUSE_LLM_SMALL_MODEL="${INHOUSE_LLM_SMALL_MODEL:-$INHOUSE_LLM_MODEL}"
  export INHOUSE_LLM_TOKEN="${INHOUSE_LLM_TOKEN:-}"
}

render_config() {
  # The model id has to be literal in the config (only api_base/api_key/master_key
  # support os.environ/ lookups), so render a copy with the names substituted.
  mkdir -p "$(dirname "$RENDERED")"
  sed -e "s|PLACEHOLDER_MAIN_MODEL|$INHOUSE_LLM_MODEL|" \
      -e "s|PLACEHOLDER_SMALL_MODEL|$INHOUSE_LLM_SMALL_MODEL|" \
      "$GW_DIR/config.yaml" > "$RENDERED"
}

case "${1:-up}" in
  up)
    load_env
    render_config
    docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null
    docker rm -f "$NAME" >/dev/null 2>&1 || true

    echo "==> starting $NAME ($LITELLM_IMAGE)"
    echo "    upstream: $INHOUSE_LLM_BASE_URL   model: $INHOUSE_LLM_MODEL"
    docker run -d --name "$NAME" --network "$NETWORK" \
      --restart unless-stopped \
      -p "127.0.0.1:$PORT:4000" \
      --add-host host.docker.internal:host-gateway \
      -v "$RENDERED:/app/config.yaml:ro" \
      -e "INHOUSE_LLM_BASE_URL=$INHOUSE_LLM_BASE_URL" \
      -e "INHOUSE_LLM_TOKEN=$INHOUSE_LLM_TOKEN" \
      -e "LITELLM_MASTER_KEY=$LITELLM_MASTER_KEY" \
      "$LITELLM_IMAGE" --config /app/config.yaml --port 4000 >/dev/null

    printf "==> waiting for proxy"
    for _ in $(seq 60); do
      if curl -fsS "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1; then
        echo " — ready on http://127.0.0.1:$PORT"
        echo
        echo "Now run:  claude-box --inhouse"
        exit 0
      fi
      printf .
      sleep 1
    done
    echo
    echo "gateway: proxy did not become ready; last logs:" >&2
    docker logs --tail 30 "$NAME" >&2
    exit 1
    ;;

  down)
    docker rm -f "$NAME" >/dev/null 2>&1 && echo "==> removed $NAME" || echo "==> $NAME not running"
    ;;

  status)
    if ! docker ps --filter "name=^$NAME$" --format '{{.Names}}' | grep -q .; then
      echo "proxy:    not running  (start it with: $0 up)"
      exit 1
    fi
    echo "proxy:    running as $NAME on http://127.0.0.1:$PORT"
    load_env
    echo "upstream: $INHOUSE_LLM_BASE_URL   model: $INHOUSE_LLM_MODEL"
    printf "health:   "
    curl -fsS "http://127.0.0.1:$PORT/health/liveliness" 2>&1 || echo "unreachable"
    echo
    printf "models:   "
    curl -fsS -H "Authorization: Bearer $LITELLM_MASTER_KEY" "http://127.0.0.1:$PORT/v1/models" 2>/dev/null \
      | python3 -c 'import sys,json;print(", ".join(m["id"] for m in json.load(sys.stdin).get("data",[])))' 2>/dev/null \
      || echo "could not list models"
    ;;

  logs)    docker logs -f --tail 100 "$NAME" ;;
  restart) "$0" down; "$0" up ;;
  -h|--help|help) usage 0 ;;
  *) echo "gateway: unknown command: $1" >&2; usage 2 ;;
esac
