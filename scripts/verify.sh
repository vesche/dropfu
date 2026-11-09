#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== script syntax =="
bash -n scripts/dev_up.sh scripts/verify.sh

echo "== Zig formatting =="
zig fmt --check \
  dropfu-protocol/build.zig dropfu-protocol/src/*.zig \
  dropfu-server/build.zig dropfu-server/src/*.zig \
  dropfu-agent/build.zig dropfu-agent/src/*.zig

echo "== protocol tests =="
(cd dropfu-protocol && zig build test)

echo "== server build+test =="
(cd dropfu-server && zig build -Doptimize=Debug && zig build test)

echo "== agent build+test =="
(cd dropfu-agent && zig build -Doptimize=Debug && zig build test)

echo "== agent cross-compile (smoke) =="
CROSS_ROOT="$(mktemp -d)"
trap 'rm -rf "$CROSS_ROOT"' EXIT
(cd dropfu-agent && zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall \
  --cache-dir "$CROSS_ROOT/windows-cache" --prefix "$CROSS_ROOT/windows-out")
(cd dropfu-agent && zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSmall \
  --cache-dir "$CROSS_ROOT/linux-arm-cache" --prefix "$CROSS_ROOT/linux-arm-out")

echo "== plugins =="
python3 dropfu-plugins/tools/build_plugins.py
python3 -m unittest discover -s dropfu-plugins/tests -p 'test_*.py' -v

echo "== client =="
(cd dropfu-client && npm ci --no-fund --no-audit && npm test && npm run typecheck && npm run build)

echo "== end-to-end =="
python3 tests/e2e.py

echo "== npm audit (prod) =="
(cd dropfu-client && npm audit --omit=dev --audit-level=high)

echo "OK: verification complete"
