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
  echo "WARNING: plugin build failed (non-fatal)"
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

cleanup() {
  echo ""
  echo "Shutting down ..."
  kill "$SERVER_PID" "$AGENT_PID" "$CLIENT_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

echo "  Starting server on :$DROPFU_CLIENT_PORT (clients) / :$DROPFU_AGENT_PORT (agents) ..."
"$ROOT/dropfu-server/zig-out/bin/dropfu-server" &
SERVER_PID=$!
sleep 1

echo "  Starting agent (connecting to $DROPFU_SERVER_HOST:$DROPFU_SERVER_PORT) ..."
"$ROOT/dropfu-agent/zig-out/bin/dropfu-agent" &
AGENT_PID=$!
sleep 1

echo "  Starting client dev server ..."
(cd "$ROOT/dropfu-client" && npx vite --port 3000 --host 127.0.0.1) &
CLIENT_PID=$!

echo ""
echo "=== dropfu running ==="
echo "  Client UI   : http://127.0.0.1:3000"
echo "  Operator token: $DROPFU_OPERATOR_TOKEN"
echo "  Server (WS) : ws://127.0.0.1:$DROPFU_CLIENT_PORT"
echo "  Agent port  : $DROPFU_AGENT_PORT"
echo ""
echo "Press Ctrl+C to stop all services."
wait
