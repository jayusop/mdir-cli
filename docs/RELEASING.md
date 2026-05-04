# Releasing mdir

## Checklist

1. Update [CHANGELOG.md](/Users/jayusop/Develop/codex/mdir-cli/CHANGELOG.md) with the new version and release date.
2. Verify local behavior:
   ```bash
   swift build
   ./scripts/smoke-test.sh
   ```
3. Create the release archive:
   ```bash
   zsh scripts/package-release.sh
   ```
4. Note the printed `sha256` for `dist/mdir-macos-<arch>.tar.gz`.
5. Upload the `.tar.gz` file to your release host, such as GitHub Releases.
6. Generate the Homebrew formula with the final URL and `sha256`:
   ```bash
   zsh scripts/generate-formula.sh <version> <url> <sha256>
   ```
7. Review [Formula/mdir.rb](/Users/jayusop/Develop/codex/mdir-cli/Formula/mdir.rb) and replace the placeholder homepage if needed.
8. Tag the release:
   ```bash
   git tag v<version>
   git push origin v<version>
   ```
9. Publish release notes using the matching `CHANGELOG.md` entry.

## Example

```bash
zsh scripts/package-release.sh
zsh scripts/generate-formula.sh 1.0.0 \
  https://github.com/<owner>/<repo>/releases/download/v1.0.0/mdir-macos-arm64.tar.gz \
  <sha256>
```
