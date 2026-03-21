# dropfu-plugins

Cross-platform Python plugins for the dropfu-agent. Each plugin is a standalone
module packaged as a zipapp (`.pyz`) for deployment. Pure-Python dependencies
are bundled inside the zipapp automatically.

## Plugins

| Plugin | Library | Description |
|--------|---------|-------------|
| `file` | [filetype](https://github.com/h2non/filetype.py) | File type identification via magic bytes |
| `ipconfig` | [ifaddr](https://github.com/pydron/ifaddr) | Network interface enumeration (IP addresses, prefixes) |
| `ping` | [ping3](https://github.com/kyan001/ping3) | ICMP ping with configurable count and timeout |
| `ps` | [psutil](https://github.com/giampaolo/psutil) | Process listing with CPU/memory stats |
| `gzip` | stdlib | Compress/decompress files with tar+gzip |

## Running Standalone

Each plugin can be run directly for testing:

```bash
python3 plugins/file_plugin.py /bin/ls /etc/hosts
python3 plugins/ipconfig_plugin.py
python3 plugins/ping_plugin.py --count 3 8.8.8.8
python3 plugins/ps_plugin.py --sort mem --top 10
python3 plugins/gzip_plugin.py compress /tmp/mydir archive.tar.gz
python3 plugins/gzip_plugin.py decompress archive.tar.gz
```

Output is human-readable plain text (not JSON).

## Building

```bash
python3 tools/build_plugins.py
```

This compiles each plugin to `.pyc` bytecode, installs any pure-Python pip
dependencies into the bundle, and outputs zipapps (`.pyz`) to `dist/`. These
are hosted on the dropfu-server and installed by agents via `plugin install`.

### System dependencies

Some plugins require libraries installed on the agent system:

- **psutil** — has C extensions, must be installed via `pip install psutil` on
  the agent (not bundled in zipapp)

Pure-Python dependencies (filetype, ifaddr, ping3) are bundled automatically.

## Adding a New Plugin

1. Create `plugins/yourname_plugin.py`
2. Subclass `DropfuPlugin` from `base.py`
3. Implement `run(self, args)` — call `self.output(text)` or `self.error(msg)`
4. Add the standalone entry point at the bottom:

```python
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from base import DropfuPlugin, main

class YourPlugin(DropfuPlugin):
    name = "yourname"
    description = "What it does"

    def run(self, args):
        self.output("plain text output here")

if __name__ == "__main__":
    main(YourPlugin)
```

5. If the plugin needs pip dependencies, add them to the `PLUGIN_DEPS` dict
   in `tools/build_plugins.py`.
6. Run `python3 tools/build_plugins.py` to produce the zipapp.

## Requirements

- Python >= 3.10
- psutil (system-wide, for the ps plugin)
