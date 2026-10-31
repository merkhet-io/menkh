#!/bin/sh
# Zig 0.15.2 Mach-O archives can have members aligned to two rather than eight
# bytes. Extract without interpreting Mach-O, then use Apple's librarian.
set -eu
case "$1" in /*) source_archive=$1;; *) source_archive="$PWD/$1";; esac
case "$2" in /*) output_archive=$2;; *) output_archive="$PWD/$2";; esac
scratch=$(mktemp -d "${TMPDIR:-/tmp}/menkh-archive.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
cd "$scratch"
xcrun ar -x "$source_archive"
# Zig deterministic archives may store zero permission bits.
chmod 600 ./*.o
xcrun libtool -static ./*.o -o "$output_archive"
