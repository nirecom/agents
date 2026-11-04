#!/usr/bin/env bash
# skills/workflow-abort-verified/scripts/show-worktree-state.sh [<worktree>] — WAV-1.
# Shows what an abort would leave behind in <worktree> (default: cwd): uncommitted changes and
# commits on HEAD that no remote branch holds. Read-only; always exits 0 unless git fails.

set -euo pipefail

WT="${1:-.}"

echo "== uncommitted changes =="
CHANGES="$(git -C "$WT" status --short)"
if [ -n "$CHANGES" ]; then printf '%s\n' "$CHANGES"; else echo "(none)"; fi

echo "== commits not on any remote branch =="
UNPUSHED="$(git -C "$WT" log --oneline HEAD --not --remotes)"
if [ -n "$UNPUSHED" ]; then printf '%s\n' "$UNPUSHED"; else echo "(none)"; fi
