# dropfu-server

Zig 0.17 relay between the operator UI and agents. Hosts authenticated plugin downloads and optional static UI assets.

## Build

```bash
zig build
zig build -Doptimize=ReleaseSafe
zig build test
```

## Run

```bash
export DROPFU_OPERATOR_TOKEN='…at least 16 chars…'
export DROPFU_AGENT_TOKEN='…at least 16 chars…'
./zig-out/bin/dropfu-server
```

Defaults bind to **loopback**. For reverse-proxy deployments:

```bash
DROPFU_BIND_ALL=1 DROPFU_STATIC_DIR=/var/www/dropfu ./zig-out/bin/dropfu-server
```

## Ports

| Port | Default | Purpose |
|------|---------|---------|
| Client | `8443` | Operator WebSocket, `/login`, `/plugins`, static |
| Agent | `9443` | Agent WebSocket |

## Auth

- Operator browser: `POST /login` with `{"token":"..."}` → `dropfu_session` cookie; WebSocket `/` or `/ws` must present that cookie.
- Agent: `Authorization: Bearer <agent-token>` on upgrade.
- Plugin HTTP requires agent or operator bearer / valid session.

## TLS

Terminate TLS with Caddy or nginx. Examples in [`../deploy/`](../deploy/).
