#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./zig build -Doptimize=ReleaseFast
./scripts/build-viewer.sh
python3 scripts/live-demo.py
exec zig-out/bin/menkh-viewer out/live-demo-job.json --live "$@"
