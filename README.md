# dropfu

Cross-platform incident response toolkit. Deploy a lightweight agent on target
endpoints, coordinate operations through a relay server, and drive everything
from a fast web-based command interface.

<https://github.com/user-attachments/assets/9497107e-3aa2-4ea1-acb8-12135ed9e6dc>

```
┌──────────────┐     WSS      ┌──────────────┐     WSS      ┌──────────────┐
│ dropfu-client│◄────────────►│ dropfu-server│◄────────────►│ dropfu-agent │
│  (SolidJS)   │  port 8443   │    (Zig)     │  port 9443   │    (Zig)     │
└──────────────┘              └──────┬───────┘              └──────────────┘
                                     │ hosts
                              ┌──────▼───────┐
                              │dropfu-plugins│
                              │  (Python)    │
                              └──────────────┘
```

Builds require **Zig 0.17**, Node.js ≥ 20, and CPython 3.14. Endpoints require
none of these runtimes: `dropfu-agent` is a self-contained executable.

## Security model (single operator)

- Separate **operator** and **agent** pre-shared tokens (`DROPFU_OPERATOR_TOKEN`, `DROPFU_AGENT_TOKEN`, min 16 chars; or `*_FILE`).
- Browser logs in via `POST /login` and receives an `HttpOnly` session cookie.
- Agents authenticate with `Authorization: Bearer <agent-token>` on WebSocket upgrade and plugin downloads.
- Server binds **loopback by default**. Set `DROPFU_BIND_ALL=1` only behind a TLS reverse proxy.
- Put Caddy/nginx in front for TLS. See [deploy/](deploy/).

## Quick Start (development)

```bash
export DROPFU_OPERATOR_TOKEN='dev-operator-token-change-me'
export DROPFU_AGENT_TOKEN='dev-agent-token-change-me'
export DROPFU_ALLOW_INSECURE=1
bash scripts/dev_up.sh
```

Open `http://127.0.0.1:3000` and paste the operator token.

## Build

```bash
cd dropfu-server && zig build && cd ..
cd dropfu-agent && zig build && cd ..
cd dropfu-plugins && python3 tools/build_plugins.py && cd ..
cd dropfu-client && npm install && npm run build && cd ..
```

Verify:

```bash
bash scripts/verify.sh
```

The verification suite runs Zig unit tests, native builds, isolated Windows and
Linux ARM cross-builds, plugin package/runtime tests, client protocol/state/WS
tests, production frontend compilation, dependency audit, and a black-box
server/agent test covering authentication, heartbeat, shell, plugin install/run,
binary upload/download, reconnect replacement, and duplicate-port rejection.

## Cross-platform agent builds

```bash
cd dropfu-agent
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall --prefix zig-out/windows-x86_64
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall --prefix zig-out/macos-aarch64
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSmall --prefix zig-out/linux-aarch64
```

| Platform | Elevated run |
|----------|----------------|
| Linux / macOS | `sudo ./dropfu-agent` |
| Windows | Administrator cmd/PowerShell |

## Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `DROPFU_OPERATOR_TOKEN` | required | Operator shared secret |
| `DROPFU_AGENT_TOKEN` | required | Agent shared secret |
| `DROPFU_CLIENT_PORT` | `8443` | Client WS + HTTP |
| `DROPFU_AGENT_PORT` | `9443` | Agent WS |
| `DROPFU_PLUGIN_DIR` | `./plugins` | Hosted `.pyz` plugins |
| `DROPFU_STATIC_DIR` | empty | Optional built client assets |
| `DROPFU_ALLOWED_ORIGINS` | localhost defaults | Comma-separated browser Origins |
| `DROPFU_BIND_ALL` | `0` | Bind `0.0.0.0` (use with TLS proxy) |
| `DROPFU_ALLOW_INSECURE` | `0` | Dev cleartext / non-Secure cookies |

## Implemented vs deferred

**Implemented now:** auth tokens, correlated routing, hardened transfers, shell (line mode), core FS commands, plugin install/run with limits, single-binary bundled CPython, `file`/`ipconfig`/`ping`/`ps`/`gzip`/`hash`/`portscan`, tiling panes, upload/download UI.

**Deferred:** camera/mic/bluetooth/ssh plugins, full PTY/ConPTY interactive terminal, memdump/procdump wrappers, multi-user RBAC.

## Project structure

```
dropfu/
├── dropfu-protocol/   Shared Zig wire protocol
├── dropfu-agent/      Zig endpoint agent
├── dropfu-server/     Zig relay + plugin host
├── dropfu-client/     SolidJS operator UI
├── dropfu-plugins/    Python plugins → .pyz
├── deploy/            Caddy/nginx examples
└── scripts/           dev_up, verify, certs
```
