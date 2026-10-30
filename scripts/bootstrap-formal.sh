#!/bin/sh
# Requires an existing elan binary. All additional toolchains stay in .tools/.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
ELAN=$(command -v elan) || { echo 'Install elan explicitly first; this script does not install a global tool manager.' >&2; exit 1; }
for PROJECT in "$ROOT/formal"; do
  TOOLCHAIN=$(cat "$PROJECT/lean-toolchain")
  if "$ELAN" toolchain list | awk -v t="$TOOLCHAIN" '$1 == t { found=1 } END { exit !found }'; then
    continue
  fi
  ELAN_HOME="$ROOT/.tools/elan" "$ELAN" toolchain install "$TOOLCHAIN"
done
"$ROOT/scripts/formal-lake.sh" core update
"$ROOT/scripts/formal-lake.sh" core exe cache get
