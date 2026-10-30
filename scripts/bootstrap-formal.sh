#!/bin/sh
# Requires an existing elan binary. All additional toolchains stay in .tools/.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
ELAN=$(command -v elan) || { echo 'Install elan explicitly first; this script does not install a global tool manager.' >&2; exit 1; }
for PROJECT in "$ROOT/formal" "$ROOT/formal/veil"; do
  TOOLCHAIN=$(cat "$PROJECT/lean-toolchain")
  if ELAN_TOOLCHAIN="$TOOLCHAIN" "$ELAN" which lake >/dev/null 2>&1; then
    continue
  fi
  ELAN_HOME="$ROOT/.tools/elan" "$ELAN" toolchain install "$TOOLCHAIN"
done
"$ROOT/scripts/formal-lake.sh" core update
"$ROOT/scripts/formal-lake.sh" core exe cache get
"$ROOT/scripts/formal-lake.sh" veil update
