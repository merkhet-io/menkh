#!/bin/sh
# Build and generate the demo; then start the independent interactive player.
set -eu
cd "$(dirname "$0")/.."
./zig build drill -Doptimize=ReleaseFast -- --voxel 0.25 --out out/drill
./scripts/build-viewer.sh
exec zig-out/bin/menkh-viewer out/drill/animation.json
