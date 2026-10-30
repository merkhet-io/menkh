#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./scripts/formal-lake.sh veil build
./scripts/formal-lake.sh veil env lean Audit.lean
python3 scripts/test-proof-guards.py veil
python3 scripts/test-proof-guards.py veil-pool
