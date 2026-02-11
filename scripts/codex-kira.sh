#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SANDBOX_MODE="${CODEX_SANDBOX_MODE:-workspace-write}"
APPROVAL_POLICY="${CODEX_APPROVAL_POLICY:-on-failure}"

cmd=(
  codex
  -C "$ROOT_DIR"
  --sandbox "$SANDBOX_MODE"
  --ask-for-approval "$APPROVAL_POLICY"
  --add-dir /tmp
  --add-dir /opt/homebrew/Cellar/zig
  --add-dir /Users/mrphil/.cache/zig
)

# Optional extra writable roots, colon-separated:
#   CODEX_ADD_DIRS="/var/folders/...:/another/path"
if [[ -n "${CODEX_ADD_DIRS:-}" ]]; then
  IFS=':' read -r -a extra_dirs <<<"$CODEX_ADD_DIRS"
  for dir in "${extra_dirs[@]}"; do
    [[ -n "$dir" ]] && cmd+=(--add-dir "$dir")
  done
fi

exec "${cmd[@]}" "$@"
