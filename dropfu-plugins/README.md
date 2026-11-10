# dropfu-plugins

Cross-platform Python plugins packaged as zipapps (`.pyz`) for dropfu-agent.

## Plugins

| Plugin | Deps | Description |
|--------|------|-------------|
| `file` | filetype | Magic-byte file identification |
| `ipconfig` | ifaddr | Network interfaces |
| `ping` | ping3 | ICMP ping |
| `ps` | stdlib / native OS interfaces | Process list |
| `gzip` | stdlib | tar+gzip compress/decompress (path-safe) |
| `hash` | stdlib | File digests (sha256/md5/sha1/sha512) |
| `portscan` | stdlib | Bounded TCP connect scanner |

## Build

```bash
# Must be CPython 3.14, matching the interpreter embedded in dropfu-agent.
python3.14 tools/build_plugins.py
python3.14 tests/test_plugins.py
```

Artifacts land in `dist/*.pyz`. Copy into the server plugin directory.

## Notes

- Artifacts contain deterministic, sourceless CPython 3.14 bytecode plus a
  runtime compatibility manifest.
- Pure-Python dependencies are compiled and included in each `.pyz`.
- Native wheels/extensions are rejected because a zipapp cannot load them
  portably. Plugins must not depend on endpoint-installed Python packages.
- Agents execute plugins with their bundled CPython 3.14.10 runtime; endpoint
  Python installations and environment customization are ignored.
