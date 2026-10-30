#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .tools/swift-cache zig-out/bin
xcrun swiftc -O -target arm64-apple-macosx15.0 -module-cache-path "$PWD/.tools/swift-cache" viewer/main.swift viewer/DrillDemo.swift viewer/VoxelView.swift viewer/Findings.swift viewer/Provenance.swift viewer/JobRunner.swift -o zig-out/bin/menkh-viewer

cp viewer/Voxel.metal zig-out/bin/Voxel.metal
