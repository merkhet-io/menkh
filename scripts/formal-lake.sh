#!/bin/sh
# Select an existing pinned toolchain. Never implicitly install a global tool.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
case "${1:-}" in
  core) PROJECT="$ROOT/formal" ;;
  veil) PROJECT="$ROOT/formal/veil" ;;
  *) echo 'Usage: formal-lake.sh core|veil [lake arguments]' >&2; exit 2 ;;
esac
shift
TOOLCHAIN=$(cat "$PROJECT/lean-toolchain")
VERSION=${TOOLCHAIN##*:}
LOCAL="$ROOT/.tools/elan/toolchains/leanprover--lean4---$VERSION/bin/lake"
if [ -x "$LOCAL" ]; then
  LAKE="$LOCAL"
elif command -v elan >/dev/null 2>&1 && LAKE=$(ELAN_TOOLCHAIN="$TOOLCHAIN" elan which lake 2>/dev/null); then
  :
else
  echo "Missing $TOOLCHAIN. Run ./scripts/bootstrap-formal.sh to install repository-local toolchains." >&2
  exit 1
fi
cd "$PROJECT"
exec "$LAKE" "$@"
