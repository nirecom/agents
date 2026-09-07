#!/usr/bin/env bash
# Warn (non-blocking) when a sibling worktree in WORKTREE_NOTES.md
# `## SiblingWorktrees` has uncommitted or unpushed work (#1102).
#
# Usage: check-sibling-uncommitted.sh [worktree_notes_path] — the argument is
# optional so the prompt need not issue a `$(git rev-parse ...)` the bash-guard
# denies (#2132). Always exits 0; missing file / empty section is silent.
# Entry schema owner: hooks/lib/worktree-notes.js.
set -euo pipefail

NOTES_PATH="${1-}"
if [[ -z "$NOTES_PATH" ]]; then
  TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$TOPLEVEL" ]] || exit 0
  NOTES_PATH="$TOPLEVEL/WORKTREE_NOTES.md"
fi
[[ -f "$NOTES_PATH" ]] || exit 0

sibling_entries="$(awk '
  /^## SiblingWorktrees/{found=1; next}
  found && /^## /{exit}
  found && /^- repo: /{
    line=$0
    repo=line; sub(/^- repo: /, "", repo); sub(/, path: .*$/, "", repo)
    wt=line; sub(/^.*,[ ]*path: /, "", wt)
    if (repo != "") print repo "|" wt
  }
' "$NOTES_PATH")"

[[ -z "$sibling_entries" ]] && exit 0

while IFS='|' read -r sibling_repo sibling_wt_path; do
  [[ -z "$sibling_repo" ]] && continue
  [[ -d "$sibling_wt_path" ]] || continue
  dirty="$(git -C "$sibling_wt_path" status --porcelain 2>/dev/null || true)"
  unpushed="$(git -C "$sibling_wt_path" log '@{u}..HEAD' --oneline 2>/dev/null || true)"
  if [[ -n "$dirty" || -n "$unpushed" ]]; then
    printf 'Warning: sibling repo %s (%s) has uncommitted/unpushed changes. Commit and push that repo before merging this session PR to ensure history entry integrity.\n' \
      "$sibling_repo" "$sibling_wt_path" >&2
  fi
done <<< "$sibling_entries"

exit 0
