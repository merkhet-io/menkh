#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./zig build -Doptimize=ReleaseFast
python3 scripts/pocket-demo.py
zig-out/bin/menkh job out/pocket-demo/job.json --out out/pocket-demo 2>out/pocket-demo/generation.log
./scripts/build-viewer.sh
exec zig-out/bin/menkh-viewer out/pocket-demo/voxel-animation.json --target-z 4 "$@"
