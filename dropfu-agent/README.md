# dropfu-agent

Zig 0.17 endpoint agent. Connects to `dropfu-server` with an agent token, executes commands, streams shell I/O, and transfers files.

## Build

```bash
# Requires Zig >= 0.17 and Python >= 3.12 on the build machine only
zig build
zig build -Doptimize=ReleaseSmall
zig build test
```

The build downloads a checksum-pinned CPython 3.14.10 runtime for the selected
target and embeds it in the agent. For reproducible/offline builds, prepare the
archive separately and pass
`-Dpython-runtime-archive=/path/to/dropfu-python-runtime.tar.gz`.

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

Plugins are sourceless CPython 3.14 bytecode zipapps (`.pyz`) fetched over
authenticated HTTP from the server. The endpoint does **not** need Python
installed: a target-specific CPython 3.14.10 distribution is carried inside the
single agent executable and launched by absolute path in isolated mode.

For process isolation and enforceable time/output limits, every plugin still
runs as a child process. The runtime is expanded lazily into one random private
temporary directory, reused by later plugin runs, and removed when the agent
exits normally or self-destructs. `PYTHONHOME`, `PYTHONPATH`, user site
packages, and `python`/`python3` from `PATH` are ignored.

Only pure-Python plugin dependencies are accepted. Native dependencies must be
implemented as part of the bundled runtime or replaced with portable stdlib
code; the current plugins require no endpoint-installed Python packages.
