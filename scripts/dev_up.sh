#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== dropfu dev environment ==="

# Dev tokens (override via env). Minimum 16 chars.
export DROPFU_OPERATOR_TOKEN="${DROPFU_OPERATOR_TOKEN:-dev-operator-token-change-me}"
export DROPFU_AGENT_TOKEN="${DROPFU_AGENT_TOKEN:-dev-agent-token-change-me}"
export DROPFU_ALLOW_INSECURE="${DROPFU_ALLOW_INSECURE:-1}"
export DROPFU_BIND_ALL="${DROPFU_BIND_ALL:-0}"

echo "[1/4] Building dropfu-server ..."
(cd "$ROOT/dropfu-server" && zig build -Doptimize=Debug) || {
  echo "ERROR: server build failed"; exit 1
}

echo "[2/4] Building dropfu-agent ..."
(cd "$ROOT/dropfu-agent" && zig build -Doptimize=Debug) || {
  echo "ERROR: agent build failed"; exit 1
}

echo "[3/4] Building plugins ..."
(cd "$ROOT/dropfu-plugins" && python3 tools/build_plugins.py) || {
  echo "ERROR: plugin build failed"; exit 1
}

PLUGIN_DIR="$ROOT/dropfu-server/plugins"
mkdir -p "$PLUGIN_DIR"
if [ -d "$ROOT/dropfu-plugins/dist" ]; then
  cp "$ROOT/dropfu-plugins/dist/"*.pyz "$PLUGIN_DIR/" 2>/dev/null && \
    echo "  plugins copied to $PLUGIN_DIR"
fi

echo "[4/4] Starting services ..."

export DROPFU_CLIENT_PORT="${DROPFU_CLIENT_PORT:-8443}"
export DROPFU_AGENT_PORT="${DROPFU_AGENT_PORT:-9443}"
export DROPFU_PLUGIN_DIR="$PLUGIN_DIR"
export DROPFU_SERVER_HOST="${DROPFU_SERVER_HOST:-127.0.0.1}"
export DROPFU_SERVER_PORT="${DROPFU_SERVER_PORT:-$DROPFU_AGENT_PORT}"

SERVER_PID=""
AGENT_PID=""
CLIENT_PID=""

cleanup() {
  echo ""
  echo "Shutting down ..."
  for pid in "$CLIENT_PID" "$AGENT_PID" "$SERVER_PID"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  for pid in "$CLIENT_PID" "$AGENT_PID" "$SERVER_PID"; do
    if [ -n "$pid" ]; then
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

wait_for_http() {
  local pid="$1"
  local url="$2"
  local label="$3"
  local attempt
  for attempt in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      echo "ERROR: $label exited before becoming ready"
      return 1
    fi
    if curl --fail --silent --max-time 1 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "ERROR: $label did not become ready: $url"
  return 1
}

echo "  Starting server on :$DROPFU_CLIENT_PORT (clients) / :$DROPFU_AGENT_PORT (agents) ..."
"$ROOT/dropfu-server/zig-out/bin/dropfu-server" &
SERVER_PID=$!
wait_for_http "$SERVER_PID" "http://127.0.0.1:$DROPFU_CLIENT_PORT/health" "server"

echo "  Starting agent (connecting to $DROPFU_SERVER_HOST:$DROPFU_SERVER_PORT) ..."
"$ROOT/dropfu-agent/zig-out/bin/dropfu-agent" &
AGENT_PID=$!
sleep 0.5
if ! kill -0 "$AGENT_PID" 2>/dev/null; then
  wait "$AGENT_PID" 2>/dev/null || true
  echo "ERROR: agent exited during startup"
  exit 1
fi

echo "  Starting client dev server ..."
(cd "$ROOT/dropfu-client" && exec npx vite --port 3000 --strictPort --host 127.0.0.1) &
CLIENT_PID=$!
wait_for_http "$CLIENT_PID" "http://127.0.0.1:3000/" "client"

echo ""
echo "=== dropfu running ==="
echo "  Client UI   : http://127.0.0.1:3000"
echo "  Operator token: $DROPFU_OPERATOR_TOKEN"
echo "  Server (WS) : ws://127.0.0.1:$DROPFU_CLIENT_PORT"
echo "  Agent port  : $DROPFU_AGENT_PORT"
echo ""
echo "Press Ctrl+C to stop all services."

set +e
wait -n "$SERVER_PID" "$AGENT_PID" "$CLIENT_PID"
STATUS=$?
set -e
echo "ERROR: a development service exited unexpectedly (status $STATUS)"
exit 1
