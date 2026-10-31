#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./zig build -Doptimize=ReleaseFast
./scripts/build-viewer.sh
# Each run owns a fresh directory; existing scene results are never overwritten.
out=$(mktemp -d "${TMPDIR:-/tmp}/menkh-scene.XXXXXX")
zig-out/bin/menkh scene examples/two-workpieces.json --out "$out/result"
exec zig-out/bin/menkh-viewer "$out/result/scene.json" "$@"
