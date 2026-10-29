#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./zig build -Doptimize=ReleaseFast
mkdir -p out/benchmark-4096
# Fresh CLI process and original cylinder each time, one warm-up then three measured runs.
for run in 0 1 2 3; do
    zig-out/bin/menkh drill --grid 4096 --out out/drill-4096 2> "out/benchmark-4096/run-$run.log"
    cp out/drill-4096/voxel-animation.json "out/benchmark-4096/run-$run.json"
done
