#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./zig build -Doptimize=ReleaseFast
for h in 0.25 0.1 0.05 0.025; do
    zig-out/bin/menkh bench --voxel "$h" --out "out/bench-$h" --repeats 7
done
