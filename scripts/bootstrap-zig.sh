#!/bin/sh
# Local, pinned toolchain only. Does not alter PATH or install global packages.
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo 'This project currently supports macOS on Apple Silicon only.' >&2
    exit 1
fi
mkdir -p .tools
if [ -x .tools/zig-aarch64-macos-0.15.2/zig ]; then
    .tools/zig-aarch64-macos-0.15.2/zig version
    exit 0
fi
curl -fL --retry 3 https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz -o .tools/zig.tar.xz
printf '%s\n' '3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b  .tools/zig.tar.xz' | shasum -a 256 -c -
tar -xJf .tools/zig.tar.xz -C .tools
.tools/zig-aarch64-macos-0.15.2/zig version
