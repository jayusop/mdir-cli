# mdir-cli

`mdir` 0.2 is a macOS CLI inspired by the direction of the reference project at `/Users/jayusop/Develop/codex/mdir`.
It combines the feel of classic DOS-era `MDIR` with a shell-oriented file manager, built around a pane-based terminal UI.

Key features:

- Runs as an interactive pane-based file manager in a TTY
- When given one path, opens both left and right panes at the same starting location
- When given two directories, uses them as the initial left and right pane paths
- In Apple Terminal, renders only the active pane for compatibility
- When given two files, compares file size and the offset of the first difference
- Displays POSIX permissions, owner, group, modified time, and size
- Recognizes `.app` directories as application bundles and can launch them
- Supports hidden-file toggle and sort cycling through key input
- Prints a snapshot in non-interactive environments or when `MDIR_FORCE_BATCH=1`
- Uses Swift Package Manager, so you can open `Package.swift` directly in Xcode and build immediately

## Build

```bash
swift build
./.build/debug/mdir
./scripts/smoke-test.sh
```

In Xcode, open `Package.swift` and it will be recognized as a package project. Select the `mdir` target in the run scheme to build and run it.

## Install

The default install path is `~/.local/bin/mdir`.

```bash
zsh scripts/install.sh
export PATH="$HOME/.local/bin:$PATH"
mdir /h
```

To install to a different location:

```bash
PREFIX="$HOME/tools" zsh scripts/install.sh
BINDIR="/usr/local/bin" zsh scripts/install.sh
```

To reuse an already-built binary instead of creating a release build:

```bash
MDIR_SKIP_BUILD=1 BUILD_CONFIG=debug zsh scripts/install.sh
```

To uninstall:

```bash
zsh scripts/uninstall.sh
```

## Release

To create a release archive:

```bash
zsh scripts/package-release.sh
```

The output is written to `dist/mdir-macos-<arch>.tar.gz`, and the final line prints the `sha256`.

To generate a Homebrew formula:

```bash
zsh scripts/generate-formula.sh 1.0.0 \
  https://example.com/mdir-macos-arm64.tar.gz \
  <sha256>
```

The generated formula is `Formula/mdir.rb`.

For the full release process, see [docs/RELEASING.md](/Users/jayusop/Develop/codex/mdir-cli/docs/RELEASING.md). For version history, see [CHANGELOG.md](/Users/jayusop/Develop/codex/mdir-cli/CHANGELOG.md).

## Usage

```bash
./.build/debug/mdir
./.build/debug/mdir /path/to/directory
./.build/debug/mdir /left/path /right/path
./.build/debug/mdir left.bin right.bin
MDIR_FORCE_BATCH=1 ./.build/debug/mdir /path/to/directory
./.build/debug/mdir /a:h
./.build/debug/mdir /o:s /left/path /right/path
./.build/debug/mdir /h
```

## Interactive Keys

- `Left`: Activate the left pane
- `Right`: Activate the right pane
- `Tab`: Switch the active pane
- `Up` / `Down`: Move the selection
- `Enter`: Enter a directory, launch a `.app`, or run an executable file for the current user after entering arguments, then wait for `[Press Anykey]`
- `O`: Open the contents of the selected `.app` directory
- `Backspace`: Go to the parent directory
- `E`: Edit the selected file with `vi`
- `P`: Start permission input mode (enter `644`, `755`, etc. and press `Enter` to apply, `Esc` to cancel)
- `H`: Toggle hidden files
- `S`: Cycle the sort mode
- `C`: Compare the selected files in the left and right panes
- `R`: Refresh
- `Q`: Quit

Apple Terminal compatibility:

- In macOS built-in Terminal, `mdir` shows only one pane at a time
- `Left`, `Right`, and `Tab` still switch the active pane behind that single-view layout

## Startup Options

- `/h` or `/?`: Show help
- `/a:h`: Show hidden files at startup
- `/o:n`: Start with name sorting
- `/o:s`: Start with size sorting
- `/o:d`: Start with modified-time sorting

## Batch Mode

- `MDIR_FORCE_BATCH=1` forces non-interactive snapshot output
- In CI or piped environments, batch mode is enabled automatically

## Compare

- When given two directories, displays them side by side in a left/right pane layout when the terminal supports it
- When given two files, compares their sizes and the position of the first difference
