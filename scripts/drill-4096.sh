#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./zig build drill -Doptimize=ReleaseFast -- --grid 4096 --out out/drill-4096
./scripts/build-viewer.sh
exec zig-out/bin/menkh-viewer out/drill-4096/voxel-animation.json --smooth-lighting
