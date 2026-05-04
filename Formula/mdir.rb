class Mdir < Formula
  desc "DOS-style directory viewer for macOS"
  homepage "https://example.com/mdir-cli"
  url "https://example.com/releases/mdir-macos-arm64.tar.gz"
  sha256 "ad9ff95176e236490c375df1be904d9c4de8f3b55095664edb8a82c5b83ac1ec"
  version "1.0.0"

  def install
    bin.install "bin/mdir"
    doc.install "README.md"
  end

  test do
    assert_match "MDIR 1.0", shell_output("\#{bin}/mdir /h")
  end
end
