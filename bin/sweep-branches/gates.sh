#!/bin/bash
#
# bin/sweep-branches/gates.sh
#
# Sourced by bin/sweep-branches.sh. The pure, network-free safety gates that
# decide whether a branch may be considered at all:
#
#   is_protected <branch>              — never-delete name list.
#   is_fresh <ref>                     — last commit within --min-age-hours.
#   wt_is_fresh <dir>                  — worktree directory mtime freshness.
#   is_old_enough_for_no_pr <ref>      — older than SWEEP_AGE_DAYS.
#   resolve_default_remote_ref         — caches DEFAULT_REMOTE_REF.
#   is_reachable_from_default <branch> — salvage check before a no-PR delete.
#
# Must be `source`d, not executed directly — it reads and mutates caller-scope
# variables ($MAIN_ROOT, $MIN_AGE_HOURS, $SWEEP_AGE_DAYS, DEFAULT_REMOTE_REF).

# Protected branch names — never deleted.
is_protected() {
  local branch="$1"
  case "$branch" in
    main|master|develop) return 0 ;;
    release/*) return 0 ;;
  esac
  return 1
}

# True (return 0) if a no-PR branch's last commit is older than SWEEP_AGE_DAYS.
is_old_enough_for_no_pr() {
  local ref="$1"
  local commit_ts
  commit_ts="$(git -C "$MAIN_ROOT" log -1 --format='%ct' "$ref" 2>/dev/null || echo 0)"
  if [[ ! "$commit_ts" =~ ^[0-9]+$ ]]; then
    commit_ts=0
  fi
  local threshold_epoch
  threshold_epoch=$(( $(date +%s) - SWEEP_AGE_DAYS * 86400 ))
  [[ "$commit_ts" -lt "$threshold_epoch" ]]
}

# Resolve the default-branch remote ref (e.g. "origin/main"). Cached.
resolve_default_remote_ref() {
  if [[ -n "$DEFAULT_REMOTE_REF" ]]; then
    return 0
  fi
  local out cand
  if out="$(git -C "$MAIN_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    DEFAULT_REMOTE_REF="$out"
    return 0
  fi
  for cand in origin/main origin/master; do
    if git -C "$MAIN_ROOT" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
      DEFAULT_REMOTE_REF="$cand"
      return 0
    fi
  done
  return 1
}

# True (return 0) if every commit on <branch> is reachable from the default
# remote branch (i.e. preserved on origin). Used as a salvage check before
# the no-PR delete path. On any resolution failure, returns non-zero (skip).
is_reachable_from_default() {
  local branch="$1"
  if ! resolve_default_remote_ref; then
    return 1
  fi
  git -C "$MAIN_ROOT" merge-base --is-ancestor \
    "refs/heads/$branch" "$DEFAULT_REMOTE_REF" 2>/dev/null
}

# True (return 0) if the branch's last commit is within MIN_AGE_HOURS.
# ref is the full ref (e.g. refs/heads/<branch>) or a branch name resolvable
# by git log. Returns 0 (fresh/unknown = skip) when timestamp cannot be read.
is_fresh() {
  local ref="$1"
  local ts
  ts="$(git log -1 --format=%ct "$ref" 2>/dev/null || true)"
  if [[ -z "$ts" ]]; then
    return 0 # unknown age → treat as fresh to be safe
  fi
  local now threshold
  now="$(date +%s)"
  threshold=$((now - MIN_AGE_HOURS * 3600))
  [[ "$ts" -ge "$threshold" ]]
}

# True (return 0) if a worktree directory is "fresh" (mtime newer than threshold).
# Mirrors sweep-worktrees.sh is_fresh() for directory-based age check.
# Used before WORKTREE-LOCKED emission to prevent fresh worktrees from being
# force-removed by the hub (SW-2b). Returns 1 (not fresh) when dir is missing.
wt_is_fresh() {
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
