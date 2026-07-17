#!/usr/bin/env bash
# Warn (non-blocking) when a sibling worktree listed in WORKTREE_NOTES.md
# `## SiblingWorktrees` has uncommitted or unpushed work, before the session's
# own PR is merged (#1102 — extracted from commit-push CP-2 so the prompt does
# not inline a multi-step procedure; rules/prompt.md §1.3).
#
# Usage: check-sibling-uncommitted.sh <worktree_notes_path>
# Always exits 0 — this is advisory. Missing file / empty section → silent.
#
# Note: parses the single-line `- repo: <r>, path: <p>` form written by
# hooks/lib/worktree-notes.js. The same awk parse also lives in
# skills/worktree-end/scripts/capture-env.sh — unifying both behind a canonical
# SiblingWorktrees parser is the deferred schema-harmonization follow-up.
set -euo pipefail

NOTES_PATH="${1:?worktree_notes_path required}"
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
