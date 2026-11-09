# dropfu-agent

Zig 0.17 endpoint agent. Connects to `dropfu-server` with an agent token, executes commands, streams shell I/O, and transfers files.

## Build

```bash
# Requires Zig >= 0.17
zig build
zig build -Doptimize=ReleaseSmall
zig build test
```

### Cross-compilation

```bash
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall --prefix zig-out/windows-x86_64
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSmall --prefix zig-out/macos-x86_64
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall --prefix zig-out/macos-aarch64
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSmall --prefix zig-out/linux-x86_64
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSmall --prefix zig-out/linux-aarch64
```

## Run

```bash
export DROPFU_AGENT_TOKEN='…at least 16 chars…'
export DROPFU_SERVER_HOST=127.0.0.1
export DROPFU_SERVER_PORT=9443
export DROPFU_CLIENT_PORT=8443   # plugin downloads
./zig-out/bin/dropfu-agent
```

## Commands

`pwd`, `ls`, `cat`, `find`, `cp`, `mv`, `rm`, `download`, `upload`, `systeminfo`, `shell`, `seppuku`, `plugin list|install|uninstall|run`.

## Plugins

Plugins are `.pyz` zipapps fetched over authenticated HTTP from the server. System Python 3 is required on the endpoint for `plugin run`. Pure-Python deps are bundled; `psutil` must be installed on the host for the `ps` plugin.
