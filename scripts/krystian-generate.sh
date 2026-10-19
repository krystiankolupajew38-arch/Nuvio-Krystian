#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
git submodule update --init --recursive
if [[ -x "$repo_root/.tools/tuist/tuist" ]]; then
  tuist_bin="$repo_root/.tools/tuist/tuist"
elif command -v tuist >/dev/null 2>&1; then
  tuist_bin="$(command -v tuist)"
else
  echo 'Install Tuist 4.207.0 using mise install, then retry.' >&2
  exit 1
fi
cd tvosApp
exec "$tuist_bin" generate --no-open
