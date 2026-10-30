#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./zig build -Doptimize=ReleaseFast
python3 scripts/grinding-demo.py "$@" --out out/grinding/job.json
./zig-out/bin/menkh job out/grinding/job.json --out out/grinding/result
./scripts/build-viewer.sh
exec ./zig-out/bin/menkh-viewer out/grinding/result/voxel-animation.json --color-operation --hide-tool
