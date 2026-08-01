#!/bin/bash
#
# bin/sweep-branches/delete-passes.sh
#
# Sourced by bin/sweep-branches.sh. The three deletion passes, plus the two
# helpers they share:
#
#   resolve_worktree_path_for_branch <branch>       — "(unknown)" when unmapped.
#   delete_local_branch <branch> <label> <errtag>   — 0 = deleted; 1 = locked or
#                                                     failed (counters updated).
#   run_local_delete_pass    — merged-PR local candidates.
#   run_no_pr_delete_pass    — no-PR local candidates (--delete-no-pr).
#   run_remote_delete_pass   — merged-PR remote candidates.
#
# The local and no-PR passes previously carried byte-identical worktree-locked
# recovery blocks; they now share delete_local_branch so the two can never
# diverge (CPR-5). The only per-pass differences are the WARN wording and the
# `errors[]` tag, both of which are parameters.
#
# Must be `source`d, not executed directly — it reads and mutates caller-scope
# state ($DRY_RUN, $APPLY, $DELETE_NO_PR, $MAIN_ROOT, $TIMEOUT_SECONDS,
# local_candidates, no_pr_branches, remote_candidates, and the counters).

# Print the worktree directory that has <branch> checked out, or "(unknown)".
resolve_worktree_path_for_branch() {
  local branch="$1"
  local wt_path="" cand_path="" wt_line
  while IFS= read -r wt_line; do
    case "$wt_line" in
      worktree\ *)
        cand_path="${wt_line#worktree }"
        ;;
      branch\ refs/heads/"$branch")
        wt_path="$cand_path"
        ;;
      "")
        # end of record; reset
        cand_path=""
        ;;
    esac
  done <<< "$(git worktree list --porcelain 2>/dev/null || true)"
  if [[ -z "$wt_path" ]]; then
    wt_path="(unknown)"
  fi
  printf '%s\n' "$wt_path"
}

# Delete one local branch. Returns 0 when the branch is gone, 1 otherwise.
# On failure the appropriate counter / errors[] entry is recorded here, so the
# callers only have to count their own success case.
delete_local_branch() {
  local branch="$1" label="$2" errtag="$3"
  local err_file err wt_path
  err_file="$(mktemp 2>/dev/null || printf '%s' "/tmp/sweep_branch_err.$$")"
  if timeout "$TIMEOUT_SECONDS" git -C "$MAIN_ROOT" branch -D "$branch" 2>"$err_file"; then
    rm -f "$err_file" 2>/dev/null || true
    return 0
  fi
  err="$(cat "$err_file" 2>/dev/null || true)"
  rm -f "$err_file" 2>/dev/null || true
  if [[ "$err" == *"checked out"* ]]; then
    wt_path="$(resolve_worktree_path_for_branch "$branch")"
    # Skip fresh worktrees — hub SW-2b must not force-remove them (#1414).
    if [[ "$wt_path" != "(unknown)" ]] && wt_is_fresh "$wt_path"; then
      printf 'INFO: worktree %s is fresh (< %d hours); skipping WORKTREE-LOCKED\n' \
        "$wt_path" "$MIN_AGE_HOURS" >&2
    else
      printf 'WORKTREE-LOCKED: branch=%s wt=%s\n' "$branch" "$wt_path"
    fi
    skipped_worktree_locked=$((skipped_worktree_locked + 1)) || true
  else
    printf 'WARN: %s delete failed: %s\n' "$label" "$branch" >&2
    errors+=("$errtag:$branch")
  fi
  return 1
}

# ─── Local deletion pass ─────────────────────────────────────────────────────

run_local_delete_pass() {
  local branch
  for branch in "${local_candidates[@]+"${local_candidates[@]}"}"; do
    if [[ "$DRY_RUN" == "1" ]]; then
      printf 'DRY-RUN: candidate branch=%s (local)\n' "$branch"
      continue
    fi
    if delete_local_branch "$branch" "local branch" "local"; then
      printf 'Deleted local branch: %s\n' "$branch"
      local_deleted=$((local_deleted + 1)) || true
    fi
  done
}

# ─── No-PR deletion pass (write mode AND --delete-no-pr) ────────────────────

run_no_pr_delete_pass() {
  if [[ "$APPLY" != "1" ]] || [[ "$DELETE_NO_PR" != "1" ]]; then
    return 0
  fi
  if [[ "${#no_pr_branches[@]}" -eq 0 ]]; then
    return 0
  fi
  local branch
  for branch in "${no_pr_branches[@]}"; do
    # Reachability was verified at classification time; every branch here is safe.
    if delete_local_branch "$branch" "no-PR local branch" "no-pr"; then
      printf 'Deleted no-PR local branch: %s\n' "$branch"
      no_pr_deleted=$(( no_pr_deleted + 1 )) || true
    fi
  done
}

# ─── Remote deletion pass ────────────────────────────────────────────────────

run_remote_delete_pass() {
  local branch
  for branch in "${remote_candidates[@]+"${remote_candidates[@]}"}"; do
    if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
      printf 'WARN: skip invalid branch name: %s\n' "$branch" >&2
      errors+=("invalid-ref:$branch")
      continue
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
      printf 'DRY-RUN: candidate branch=%s (remote)\n' "$branch"
      continue
    fi
    if ! resolve_repo_identity; then
      remote_delete_failed=$((remote_delete_failed + 1)) || true
      errors+=("remote:$branch")
      continue
    fi
    if gh api -X DELETE "repos/$REPO_OWNER/$REPO_NAME/git/refs/heads/$branch" 2>/dev/null; then
      printf 'Deleted remote branch: %s\n' "$branch"
      remote_deleted=$((remote_deleted + 1)) || true
    else
      printf 'WARN: remote delete failed: %s\n' "$branch" >&2
      remote_delete_failed=$((remote_delete_failed + 1)) || true
      errors+=("remote:$branch")
    fi
  done
}
