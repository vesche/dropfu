# dropfu-agent

Minimal, cross-platform endpoint agent for incident response. Connects to
`dropfu-server` via WebSocket, receives commands from the responder's
`dropfu-client`, and executes them on the target system.

## Build

```bash
# Requires Zig >= 0.15
zig build

# Optimised release build (smaller binary)
zig build -Doptimize=ReleaseSmall
```

The binary is placed in `zig-out/bin/dropfu-agent`.

### Cross-compilation

Zig supports cross-compiling from any host to any target:

```bash
# Windows (exe)
zig build -Dtarget=x86_64-windows

# macOS (Mach-O)
zig build -Dtarget=x86_64-macos
zig build -Dtarget=aarch64-macos

# Linux (ELF)
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-linux
```

## Run

```bash
# Connect to server at 127.0.0.1:9443 (default)
./zig-out/bin/dropfu-agent

# Custom server
DROPFU_SERVER_HOST=10.0.0.5 DROPFU_SERVER_PORT=9443 ./zig-out/bin/dropfu-agent
```

### Running with elevated privileges

The agent benefits from root/admin access for full system visibility.

**Linux / macOS:**
```bash
sudo ./dropfu-agent
```

**Windows (cmd as Administrator):**
```cmd
dropfu-agent.exe
```

**Windows (PowerShell as Administrator):**
```powershell
.\dropfu-agent.exe
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DROPFU_SERVER_HOST` | `127.0.0.1` | Server hostname or IP |
| `DROPFU_SERVER_PORT` | `9443` | Server agent port |
| `DROPFU_CLIENT_PORT` | `8443` | Server client port (used for plugin downloads) |

## Built-in Commands

| Command | Description |
|---------|-------------|
| `pwd` | Print current working directory |
| `ls [path]` | List directory contents |
| `cat <file>` | Display first 1024 bytes of a file |
| `find <path> <pattern>` | Case-insensitive file search with wildcards (max 500) |
| `cp <src> <dst>` | Copy a file |
| `mv <src> <dst>` | Move / rename a file |
| `rm <file>` | Delete a file |
| `download <path>` | Transfer file from agent to client |
| `upload <path>` | Receive a file from client |
| `systeminfo` | Hostname, user, OS version, CPU, memory, network interfaces |
| `shell` | Start an interactive shell session |
| `seppuku` | Self-destruct: delete plugins and agent binary |

## Plugin Management

| Command | Description |
|---------|-------------|
| `plugin list` | List available plugins and install status |
| `plugin install <name>` | Download and install a plugin from the server |
| `plugin uninstall <name>` | Remove an installed plugin |
| `plugin run <name> [args]` | Execute an installed plugin |

Example:

```
plugin install ipconfig
plugin run ipconfig
plugin run ps --sort mem --top 10
```

## Stable System Identifier

On first run the agent computes a SHA-256 hash from:
- `/etc/machine-id` (Linux) or IOPlatformUUID (macOS) or MachineGuid (Windows)
- Primary network interface MAC address
- Hostname

This ID is deterministic: if the agent disconnects and reconnects, the server
recognises it as the same endpoint.
