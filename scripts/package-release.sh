#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
ARCH_NAME="${ARCH_NAME:-$(uname -m)}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
PKG_NAME="mdir-macos-${ARCH_NAME}"
STAGE_DIR="$DIST_DIR/$PKG_NAME"
ARCHIVE_PATH="$DIST_DIR/$PKG_NAME.tar.gz"

cd "$ROOT_DIR"

echo "Building mdir (${BUILD_CONFIG})..."
swift build -c "$BUILD_CONFIG"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/bin"

install -m 0755 ".build/${BUILD_CONFIG}/mdir" "$STAGE_DIR/bin/mdir"
install -m 0644 "README.md" "$STAGE_DIR/README.md"

rm -f "$ARCHIVE_PATH"
tar -C "$DIST_DIR" -czf "$ARCHIVE_PATH" "$PKG_NAME"

echo "Archive: $ARCHIVE_PATH"
shasum -a 256 "$ARCHIVE_PATH"
