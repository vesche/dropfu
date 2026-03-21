# dropfu

Cross-platform incident response toolkit. Deploy a lightweight agent on target
endpoints, coordinate operations through a relay server, and drive everything
from a fast web-based command interface.

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

## Components

| Component | Language | Purpose |
|-----------|----------|---------|
| [dropfu-agent](dropfu-agent/) | Zig | Endpoint agent — executes commands, streams shells, transfers files |
| [dropfu-server](dropfu-server/) | Zig | Relay server — routes messages between clients and agents, hosts plugins |
| [dropfu-client](dropfu-client/) | TypeScript/SolidJS | Web UI — command console with tiling pane manager |
| [dropfu-plugins](dropfu-plugins/) | Python | Extensible plugin library — compiled to bytecode zipapps |

## Quick Start

### Prerequisites

- [Zig](https://ziglang.org/download/) >= 0.15
- [Node.js](https://nodejs.org/) >= 20 (for the client)
- [Python](https://python.org/) >= 3.10 (for plugins)
- pip packages: `psutil` (required on agent for the ps plugin)
- npm

### Build Everything

```bash
# Build server
cd dropfu-server && zig build && cd ..

# Build agent
cd dropfu-agent && zig build && cd ..

# Build plugins
cd dropfu-plugins && python3 tools/build_plugins.py && cd ..

# Install client dependencies
cd dropfu-client && npm install && cd ..
```

### Run (Development)

The quickest way to get everything running locally:

```bash
bash scripts/dev_up.sh
```

This starts the server, one local agent, and the client dev server. Open
`http://localhost:3000` in your browser.

Or start each component manually:

```bash
# Terminal 1 — Server
cd dropfu-server
mkdir -p plugins && cp ../dropfu-plugins/dist/*.pyz plugins/
./zig-out/bin/dropfu-server

# Terminal 2 — Agent
cd dropfu-agent
DROPFU_SERVER_HOST=127.0.0.1 DROPFU_SERVER_PORT=9443 ./zig-out/bin/dropfu-agent

# Terminal 3 — Client
cd dropfu-client
npx vite --port 3000
```

### TLS (Production)

1. Generate certificates:
   ```bash
   bash scripts/gen_certs.sh ./certs
   ```

2. Place an nginx or caddy reverse proxy in front of the server for TLS
   termination. See [dropfu-server/README.md](dropfu-server/README.md) for
   an example nginx config.

3. Point the agent to the TLS endpoint and the client to the WSS URL.

## Cross-Platform Agent Builds

Zig makes cross-compilation straightforward:

```bash
cd dropfu-agent

# Windows x86_64
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall

# macOS ARM
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall

# Linux ARM
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSmall
```

### Running with Root/Admin Privileges

| Platform | Command |
|----------|---------|
| Linux / macOS | `sudo ./dropfu-agent` |
| Windows (cmd) | Run cmd as Administrator, then `dropfu-agent.exe` |
| Windows (PowerShell) | Run PowerShell as Administrator, then `.\dropfu-agent.exe` |

## Client UI

The web interface features:

- **Collapsible agent sidebar** — lists all connected agents with hostname, OS,
  arch, and privilege level.
- **Command console** — terminal-like interface bound to the selected agent.
- **Tiling pane manager** — split and manage panes with keyboard shortcuts:
  - `Shift + Arrow` split pane in that direction
  - `Shift + Delete` close active pane
  - `Shift + Ctrl + Arrow` navigate between panes
  - `Shift + Backspace` clear screen

## Agent Commands

See [dropfu-agent/README.md](dropfu-agent/README.md) for the full command
reference.

## Plugin Development

See [dropfu-plugins/README.md](dropfu-plugins/README.md) for instructions on
writing and packaging new plugins.

## Project Structure

```
dropfu/
├── dropfu-agent/        Zig agent binary
│   └── src/
├── dropfu-server/       Zig server binary
│   └── src/
├── dropfu-client/       SolidJS web frontend
│   └── src/
├── dropfu-plugins/      Python plugin library
│   ├── plugins/
│   ├── tools/
│   └── dist/            Built .pyz artifacts
├── scripts/
│   ├── gen_certs.sh     Generate self-signed TLS certs
│   └── dev_up.sh        Start all components locally
└── README.md
```
