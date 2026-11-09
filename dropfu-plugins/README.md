# dropfu-plugins

Cross-platform Python plugins packaged as zipapps (`.pyz`) for dropfu-agent.

## Plugins

| Plugin | Deps | Description |
|--------|------|-------------|
| `file` | filetype | Magic-byte file identification |
| `ipconfig` | ifaddr | Network interfaces |
| `ping` | ping3 | ICMP ping |
| `ps` | psutil (system) | Process list |
| `gzip` | stdlib | tar+gzip compress/decompress (path-safe) |
| `hash` | stdlib | File digests (sha256/md5/sha1/sha512) |
| `portscan` | stdlib | Bounded TCP connect scanner |

## Build

```bash
python3 tools/build_plugins.py
python3 tests/test_plugins.py
```

Artifacts land in `dist/*.pyz`. Copy into the server plugin directory.

## Notes

- Bytecode is tied to the Python version that built the zipapp. Agents should run a matching `python3`.
- Embedded CPython / native wheel bundling is intentionally deferred.
