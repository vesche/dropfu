#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== protocol tests =="
(cd dropfu-protocol && zig build test)

echo "== server build+test =="
(cd dropfu-server && zig build -Doptimize=Debug && zig build test)

echo "== agent build+test =="
(cd dropfu-agent && zig build -Doptimize=Debug && zig build test)

echo "== agent cross-compile (smoke) =="
(cd dropfu-agent && zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall)
(cd dropfu-agent && zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSmall)

echo "== plugins =="
python3 dropfu-plugins/tests/test_plugins.py
python3 dropfu-plugins/tools/build_plugins.py

echo "== client =="
(cd dropfu-client && npm install --no-fund --no-audit && npm run typecheck && npm run build)

echo "== npm audit (prod) =="
(cd dropfu-client && npm audit --omit=dev --audit-level=high || true)

echo "OK: verification complete"
