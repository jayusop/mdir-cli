#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/5] build"
if [[ ! -x ./.build/debug/mdir && "${MDIR_SKIP_BUILD:-0}" != "1" ]]; then
  swift build >/dev/null
fi

echo "[2/5] help"
./.build/debug/mdir /h | rg "Usage:" >/dev/null

echo "[3/5] single pane batch"
MDIR_FORCE_BATCH=1 ./.build/debug/mdir . | rg "Directory of" >/dev/null

echo "[4/5] dual pane batch"
MDIR_FORCE_BATCH=1 ./.build/debug/mdir . /Users/jayusop/Develop/codex/mdir | rg "^LEFT  " >/dev/null

echo "[5/5] file compare"
./.build/debug/mdir Package.swift README.md | rg "Compare files" >/dev/null

echo "smoke test passed"
