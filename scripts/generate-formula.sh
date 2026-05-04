#!/bin/zsh

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <version> <url> <sha256>" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORMULA_DIR="$ROOT_DIR/Formula"
FORMULA_PATH="$FORMULA_DIR/mdir.rb"
VERSION="$1"
URL="$2"
SHA256="$3"

mkdir -p "$FORMULA_DIR"

cat > "$FORMULA_PATH" <<EOF
class Mdir < Formula
  desc "DOS-style directory viewer for macOS"
  homepage "https://example.com/mdir-cli"
  url "${URL}"
  sha256 "${SHA256}"
  version "${VERSION}"

  def install
    bin.install "bin/mdir"
    doc.install "README.md"
  end

  test do
    assert_match "MDIR 1.0", shell_output("\#{bin}/mdir /h")
  end
end
EOF

echo "Generated: $FORMULA_PATH"
