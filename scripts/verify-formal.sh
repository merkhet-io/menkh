#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p out
./scripts/formal-lake.sh core build
./scripts/formal-lake.sh core env lean Audit.lean
# Use the interpreter: linking all of mathlib into a fixture generator is unnecessary.
./scripts/formal-lake.sh core env lean --run Oracle.lean > out/formal-oracle.txt.tmp
mv out/formal-oracle.txt.tmp out/formal-oracle.txt
./zig build formal-test --summary all
./zig build formal-test -Doptimize=ReleaseFast --summary all
python3 scripts/test-proof-guards.py core
