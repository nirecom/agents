#!/bin/bash
#
# bin/sweep-branches/pr-state.sh
#
# Sourced by bin/sweep-branches.sh. Everything that asks GitHub "what is the PR
# state of this branch?" lives here, so the deletion passes never talk to `gh`
# directly.
#
#   is_pr_merged <branch>        — boolean gate used by the remote pass.
#   classify_pr_state <branch>   — tri-state (merged|open|none|unknown) used by
#                                  the local pass. Reads $SKIP_GH.
#   resolve_repo_identity        — lazily fills REPO_OWNER / REPO_NAME.
#
# Must be `source`d, not executed directly — it reads and mutates caller-scope
# variables ($SKIP_GH, REPO_OWNER, REPO_NAME).

# True (return 0) if a PR with head == branch is merged AND no open PR exists
# for the same head. Branch-name reuse (old merged + new open) must NOT report
# merged — that would let the remote-delete pass kill an active PR's head.
is_pr_merged() {
  local branch="$1"
  if [[ "$SKIP_GH" == "1" ]]; then
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    printf 'WARN: gh CLI not available; cannot verify merged state for %s\n' \
      "$branch" >&2
    return 1
  fi
  local open_count
  if ! open_count="$(gh pr list -H "$branch" --state open --json number --jq 'length' 2>/dev/null)"; then
    printf 'WARN: gh pr list (open) failed for branch %s; skipping\n' "$branch" >&2
    return 1
  fi
  if [[ "$open_count" =~ ^[0-9]+$ ]] && [[ "$open_count" -gt 0 ]]; then
    return 1
  fi
  local merged
  if ! merged="$(gh pr list -H "$branch" --state merged \
      --json number --jq 'length > 0' 2>/dev/null)"; then
    printf 'WARN: gh pr list (merged) failed for branch %s; skipping\n' "$branch" >&2
    return 1
  fi
  [[ "$merged" == "true" ]]
}

# Tri-state PR classification: prints one of merged | open | none | unknown.
# "unknown" means we could not determine state (gh missing/failed) — callers
# must treat unknown as skip (no deletion). This prevents transient gh failures
# from being misread as "no PR" and triggering destructive --delete-no-pr.
# Honors --skip-gh-check (returns "merged" for testing parity with is_pr_merged).
classify_pr_state() {
  local branch="$1"
  if [[ "$SKIP_GH" == "1" ]]; then
    printf 'merged\n'
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    printf 'unknown\n'
    return 0
  fi
  # Check open state first. Branch-name reuse (old merged PR + new open PR with
  # same head) must classify as "open" so the new work is not destroyed.
  local open_count
  if ! open_count="$(gh pr list -H "$branch" --state open --json number --jq 'length' 2>/dev/null)"; then
    printf 'unknown\n'
    return 0
  fi
  if [[ ! "$open_count" =~ ^[0-9]+$ ]]; then
    printf 'unknown\n'
    return 0
  fi
  if [[ "$open_count" -gt 0 ]]; then
    printf 'open\n'
    return 0
  fi
  local merged_count
  if ! merged_count="$(gh pr list -H "$branch" --state merged --json number --jq 'length' 2>/dev/null)"; then
    printf 'unknown\n'
    return 0
  fi
  if [[ ! "$merged_count" =~ ^[0-9]+$ ]]; then
    printf 'unknown\n'
    return 0
  fi
  if [[ "$merged_count" -gt 0 ]]; then
    printf 'merged\n'
  else
    printf 'none\n'
  fi
}

# Resolve REPO_OWNER and REPO_NAME lazily (only when a remote candidate exists).
resolve_repo_identity() {
  if [[ -n "$REPO_OWNER" ]]; then
    return 0
  fi
  local out
  out=$(gh repo view --json owner,name --jq '.owner.login + " " + .name' 2>/dev/null) || return 1
  REPO_OWNER="${out%% *}"
  REPO_NAME="${out##* }"
  if [[ -z "$REPO_OWNER" || -z "$REPO_NAME" ]]; then
    printf 'WARN: could not parse repo owner/name from gh repo view\n' >&2
    return 1
  fi
}
