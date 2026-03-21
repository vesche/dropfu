# dropfu-server

Multi-purpose WebSocket relay and coordination server for the dropfu toolkit.
Bridges communication between `dropfu-client` (incident responder UI) and one
or more `dropfu-agent` instances deployed on target endpoints.

## Ports

| Port | Default | Purpose |
|------|---------|---------|
| Client port | `8443` | WebSocket for clients + HTTP for plugin downloads |
| Agent port | `9443` | WebSocket for agent connections |

Ports are configurable via environment variables.

## Build

```bash
# Requires Zig >= 0.15
zig build

# Optimised release build
zig build -Doptimize=ReleaseSafe
```

The binary is placed in `zig-out/bin/dropfu-server`.

## Run

```bash
# Defaults: client port 8443, agent port 9443, plugins in ./plugins
./zig-out/bin/dropfu-server

# Custom configuration
DROPFU_CLIENT_PORT=443 \
DROPFU_AGENT_PORT=9443 \
DROPFU_PLUGIN_DIR=/opt/dropfu/plugins \
  ./zig-out/bin/dropfu-server
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DROPFU_CLIENT_PORT` | `8443` | Port for client WebSocket + HTTP |
| `DROPFU_AGENT_PORT` | `9443` | Port for agent WebSocket |
| `DROPFU_PLUGIN_DIR` | `./plugins` | Directory containing `.pyz` plugin artifacts |

## TLS (Production)

The server itself runs plain TCP. For WSS/HTTPS, place an nginx or caddy
reverse proxy in front. Example nginx config:

```nginx
server {
    listen 443 ssl;
    ssl_certificate     /etc/dropfu/cert.pem;
    ssl_certificate_key /etc/dropfu/key.pem;

    location / {
        proxy_pass http://127.0.0.1:8443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

Generate self-signed certs for development with `../scripts/gen_certs.sh`.

## Plugin Hosting

Place compiled plugin `.pyz` files in the plugin directory. Agents fetch them
via `GET /plugins/<name>.pyz`. The build pipeline in `../dropfu-plugins/`
produces these artifacts.

## HTTP Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Returns `200 OK` with body `ok` |
| `GET /plugins/list` | Returns JSON array of available plugin names |
| `GET /plugins/<name>.pyz` | Download a plugin zipapp |
