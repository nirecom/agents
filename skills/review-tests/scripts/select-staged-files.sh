#!/usr/bin/env bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
# Resolve session-bound linked worktree path (SSOT: bin/resolve-worktree-path).
WORKTREE="$("$AGENTS_CONFIG_DIR/bin/resolve-worktree-path")"
if [[ "$WORKTREE" == "NOSTATE" ]]; then
  # Test fixture / first-run: no session state. Use CWD as fallback.
  git diff --cached --name-only
  exit 0
elif [[ -z "$WORKTREE" ]]; then
  # Resolution failed (main worktree rejected or session state missing).
  # Do NOT fall back to CWD — emit explicit skip signal.
  exit 3
fi
# Linked worktree resolved: list staged files in that worktree only.
git -C "$WORKTREE" diff --cached --name-only
