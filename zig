#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export ZIG_GLOBAL_CACHE_DIR="$ROOT/.tools/cache"
export MENKH_SDK="${MENKH_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
if [ ! -d "$MENKH_SDK" ]; then
    echo "Compatible macOS SDK missing: set MENKH_SDK to an installed SDK with arm64-macos exports." >&2
    exit 1
fi
export PATH="$ROOT/scripts/sdk-bin:$PATH"
exec "$ROOT/.tools/zig-aarch64-macos-0.15.2/zig" "$@"
