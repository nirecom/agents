#!/bin/bash
#
# bin/sweep-worktrees/gates.sh
#
# Sourced by bin/sweep-worktrees.sh. Path normalization plus the per-worktree
# safety gates:
#
#   norm_path <path>              — realpath -m + cygpath -u, input on failure.
#   is_fresh <dir>                — directory mtime within --min-age-hours.
#   is_clean_wt <wt>              — no tracked changes AND no untracked files.
#   is_clean_tracked_only <wt>    — no tracked changes (untracked ignored).
#   is_pr_merged <branch>         — a PR with head == branch is merged.
#
# Must be `source`d, not executed directly — it reads caller-scope variables
# ($MIN_AGE_HOURS, $SKIP_GH_CHECK). bin/sweep-worktrees/empty-parent.sh also
# depends on norm_path, so this file must be sourced before it is used.

# realpath -m equivalent that returns the input on failure (path may not exist).
# On Windows Git Bash, mktemp -d yields POSIX form (/tmp/...) while
# `git worktree list --porcelain` returns Windows form (C:/Users/.../...).
# `cygpath -u` normalizes both to a single POSIX form so equality checks work.
norm_path() {
  local p="$1"
  if [[ -z "$p" ]]; then
    printf ''
    return
  fi
  if command -v realpath >/dev/null 2>&1; then
    p="$(realpath -m -- "$p" 2>/dev/null || printf '%s' "$p")"
  fi
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u -- "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

# True if a worktree directory is "fresh" (mtime newer than threshold).
is_fresh() {
  local dir="$1"
  local mins=$((MIN_AGE_HOURS * 60))
  if [[ ! -d "$dir" ]]; then
    return 1 # missing dir is never "fresh"
  fi
  if find "$dir" -maxdepth 0 -mmin "-$mins" 2>/dev/null | grep -q .; then
    return 0
  fi
  return 1
}

# True if working tree is clean (or directory missing — treat as clean).
is_clean_wt() {
  local wt="$1"
  if [[ ! -d "$wt" ]]; then
    return 0
  fi
  local status_out untracked_out
  status_out="$(git -C "$wt" status --porcelain 2>/dev/null || true)"
  untracked_out="$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true)"
  [[ -z "$status_out" ]] && [[ -z "$untracked_out" ]]
}

# True if tracked files are clean (ignores untracked files entirely).
is_clean_tracked_only() {
  local wt="$1"
  if [[ ! -d "$wt" ]]; then
    return 0
  fi
  local status_out
  status_out="$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null || true)"
  [[ -z "$status_out" ]]
}

# True if a PR with head exactly == branch is merged.
is_pr_merged() {
  local branch="$1"
  if [[ "$SKIP_GH_CHECK" == "1" ]]; then
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    printf 'WARN: gh CLI not available; cannot verify merged state for %s\n' \
      "$branch" >&2
    return 1
  fi
  local out
  if ! out="$(gh pr list -H "$branch" --state merged \
      --json number --jq 'length > 0' 2>/dev/null)"; then
    printf 'WARN: gh pr list failed for branch %s; skipping\n' "$branch" >&2
    return 1
  fi
  [[ "$out" == "true" ]]
}
