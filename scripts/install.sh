#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="${BINDIR:-$PREFIX/bin}"
BUILD_CONFIG="${BUILD_CONFIG:-release}"

cd "$ROOT_DIR"

if [[ ! -x ".build/${BUILD_CONFIG}/mdir" && "${MDIR_SKIP_BUILD:-0}" != "1" ]]; then
  echo "Building mdir (${BUILD_CONFIG})..."
  swift build -c "$BUILD_CONFIG"
fi

mkdir -p "$BINDIR"
install -m 0755 ".build/${BUILD_CONFIG}/mdir" "$BINDIR/mdir"

echo "Installed: $BINDIR/mdir"
echo "Add to PATH if needed: export PATH=\"$BINDIR:\$PATH\""
