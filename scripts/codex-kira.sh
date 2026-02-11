#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SANDBOX_MODE="${CODEX_SANDBOX_MODE:-workspace-write}"
APPROVAL_POLICY="${CODEX_APPROVAL_POLICY:-on-failure}"

# Optional opt-in mode for commands that need outbound network access
# (for example: `git push` to GitHub). There is no per-domain allowlist
# in Codex CLI, so this relaxes sandboxing globally for the session.
#
# Usage:
#   CODEX_GIT_PUSH_MODE=1 ./scripts/codex-kira.sh
if [[ "${CODEX_GIT_PUSH_MODE:-0}" == "1" ]]; then
  if [[ -z "${CODEX_SANDBOX_MODE:-}" ]]; then
    SANDBOX_MODE="danger-full-access"
  fi
  if [[ -z "${CODEX_APPROVAL_POLICY:-}" ]]; then
    APPROVAL_POLICY="on-request"
  fi
  echo "codex-kira: CODEX_GIT_PUSH_MODE=1 enabled (sandbox=${SANDBOX_MODE}, approvals=${APPROVAL_POLICY})" >&2
fi

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
