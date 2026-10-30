#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./zig build -Doptimize=ReleaseFast
zig-out/bin/menkh job examples/general.json --out out/general
./scripts/build-viewer.sh
exec zig-out/bin/menkh-viewer out/general/voxel-animation.json --smooth-lighting --compare-target
