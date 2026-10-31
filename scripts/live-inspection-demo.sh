#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./zig build -Doptimize=ReleaseFast
./scripts/build-viewer.sh
python3 scripts/live-demo.py --inspection --voxel "${MENKH_VOXEL_MM:-0.025}" --out out/live-inspection-demo.json
exec zig-out/bin/menkh-viewer out/live-inspection-demo.json --live --color-operation "$@"
