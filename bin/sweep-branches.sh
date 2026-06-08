#!/usr/bin/env bash
#
# bin/sweep-branches.sh
#
# Reclaims merged-but-undeleted local and remote branches. Local branches are
# age-gated (--min-age-hours); remote branches are only PR-merged checked.
# Default is dry-run; pass --apply to delete.
#
# Usage:
#   sweep-branches.sh [--apply] [--min-age-hours N] [--ci-mode]
#                     [--dry-run] [--skip-gh-check]
#
# Exit code: 0 on normal completion (per-branch failures are non-fatal).
#            1 only on fatal setup error (missing AGENTS_CONFIG_DIR, git, etc.).

set -euo pipefail

# ─── Defaults & flag parsing ────────────────────────────────────────────────

APPLY=0
MIN_AGE_HOURS=24
CI_MODE=0
SKIP_GH=0
DRY_RUN=1
DELETE_NO_PR=0
SWEEP_AGE_DAYS="${SWEEP_AGE_DAYS:-30}"

validate_sweep_age_days() {
  local v="$1"
  if [[ ! "$v" =~ ^[0-9]+$ ]] || [[ "$v" -lt 1 ]]; then
    printf 'ERROR: SWEEP_AGE_DAYS must be a positive integer (got: %s)\n' "$v" >&2
    exit 2
  fi
}

validate_sweep_age_days "$SWEEP_AGE_DAYS"

usage() {
  cat <<'EOF'
Usage: sweep-branches.sh [options]

Options:
  --apply               Actually delete (default is dry-run).
  --dry-run             Explicit dry-run (default).
  --min-age-hours N     Skip local branches whose last commit is more recent
                        than N hours (default 24). Remote branches are not
                        age-gated — only the PR-merged check applies.
  --delete-no-pr        Also delete local branches that have no PR at all
                        (requires --apply; age-gated by --sweep-age-days).
  --sweep-age-days N    Age threshold in days for no-PR detection
                        (default 30; env SWEEP_AGE_DAYS).
  --ci-mode             Emit JSON summary on stdout (instead of plain text).
  --skip-gh-check       Skip the gh PR merged-state check (testing only).
  -h, --help            Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; DRY_RUN=0 ;;
    --dry-run) APPLY=0; DRY_RUN=1 ;;
    --min-age-hours)
      shift
      MIN_AGE_HOURS="${1:?--min-age-hours requires a value}"
      if ! [[ "$MIN_AGE_HOURS" =~ ^[0-9]+$ ]] || [[ "$MIN_AGE_HOURS" -lt 1 ]]; then
        printf 'ERROR: --min-age-hours must be a positive integer, got: %s\n' "$MIN_AGE_HOURS" >&2
        exit 1
      fi
      ;;
    --delete-no-pr) DELETE_NO_PR=1 ;;
    --sweep-age-days)
      shift
      SWEEP_AGE_DAYS="${1:?--sweep-age-days requires a value}"
      validate_sweep_age_days "$SWEEP_AGE_DAYS"
      ;;
    --ci-mode) CI_MODE=1 ;;
    --skip-gh-check) SKIP_GH=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'ERROR: unknown flag: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

# ─── Required environment ───────────────────────────────────────────────────

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR must be set}"

# Sanity check: git in path
if ! command -v git >/dev/null 2>&1; then
  printf 'ERROR: git not found in PATH\n' >&2
  exit 1
fi

# Non-GitHub guard: skip gracefully on non-GitHub remotes.
if ! "$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote" >/dev/null 2>&1; then
  printf 'INFO: not a GitHub.com remote; sweep-branches skipped\n'
  exit 0
fi

# Resolve main worktree root.
if ! MAIN_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  printf 'ERROR: not inside a git repository\n' >&2
  exit 1
fi

# ─── Counters ───────────────────────────────────────────────────────────────

scanned=0
candidates=0
local_deleted=0
remote_deleted=0
remote_delete_failed=0
skipped_unmerged=0
skipped_young=0
no_pr_candidates=0
no_pr_deleted=0
no_pr_skipped_young=0
no_pr_skipped_unreachable=0
pr_state_unknown=0
unmerged_pr_skipped=0
no_pr_branches=()
errors=()

# Lazily resolved from gh repo view.
REPO_OWNER=""
REPO_NAME=""

# Cached default-branch ref (e.g. "origin/main"); resolved on first use.
DEFAULT_REMOTE_REF=""

# ─── Helpers ────────────────────────────────────────────────────────────────

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
  local out
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

# ─── Candidate collection ───────────────────────────────────────────────────

# Protected branch names — never deleted.
is_protected() {
  local branch="$1"
  case "$branch" in
    main|master|develop) return 0 ;;
    release/*) return 0 ;;
  esac
  return 1
}

local_candidates=()
remote_candidates=()

# Local branches — tri-state PR classification (#808).
while IFS= read -r branch; do
  [[ -z "$branch" ]] && continue
  scanned=$((scanned + 1)) || true
  if is_protected "$branch"; then
    continue
  fi
  pr_state="$(classify_pr_state "$branch")"
  case "$pr_state" in
    merged)
      # Age gate for merged-PR local branches.
      if is_fresh "refs/heads/$branch"; then
        skipped_young=$((skipped_young + 1)) || true
        continue
      fi
      local_candidates+=("$branch")
      candidates=$((candidates + 1)) || true
      ;;
    none)
      if is_old_enough_for_no_pr "refs/heads/$branch"; then
        # Reachability gate: if the branch is not reachable from the default
        # remote ref, skip now (both dry-run and apply) so that dry-run output
        # faithfully predicts what --apply --delete-no-pr will delete.
        if ! is_reachable_from_default "$branch"; then
          no_pr_skipped_unreachable=$(( no_pr_skipped_unreachable + 1 )) || true
          printf 'WARN: no-PR branch %s not reachable from default remote; skipping (commits may be unmerged)\n' "$branch" >&2
        else
          no_pr_branches+=("$branch")
          no_pr_candidates=$(( no_pr_candidates + 1 )) || true
          if [[ "$DRY_RUN" == "1" ]]; then
            printf 'NO-PR-CANDIDATE: %s (last commit older than %d days)\n' "$branch" "$SWEEP_AGE_DAYS"
          fi
        fi
      else
        no_pr_skipped_young=$(( no_pr_skipped_young + 1 )) || true
      fi
      ;;
    open)
      unmerged_pr_skipped=$(( unmerged_pr_skipped + 1 )) || true
      skipped_unmerged=$(( skipped_unmerged + 1 )) || true
      ;;
    unknown)
      # Transient gh failure or gh missing — never delete on unknown state.
      pr_state_unknown=$(( pr_state_unknown + 1 )) || true
      printf 'WARN: PR state unknown for %s; skipping (no deletion)\n' "$branch" >&2
      ;;
  esac
done < <(git -C "$MAIN_ROOT" branch --format='%(refname:short)' 2>/dev/null)

# Remote branches (no age gate — document: remote branches are only PR-merged checked)
while IFS= read -r branch; do
  [[ -z "$branch" ]] && continue
  scanned=$((scanned + 1)) || true
  if is_protected "$branch"; then
    continue
  fi
  # PR merged check only (no age gate for remote branches).
  if ! is_pr_merged "$branch"; then
    skipped_unmerged=$((skipped_unmerged + 1)) || true
    continue
  fi
  remote_candidates+=("$branch")
  candidates=$((candidates + 1)) || true
done < <(git ls-remote --heads origin 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||')

# ─── Local deletion pass ─────────────────────────────────────────────────────

for branch in "${local_candidates[@]+"${local_candidates[@]}"}"; do
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY-RUN: candidate branch=%s (local)\n' "$branch"
    continue
  fi
  if SWEEP_BRANCHES_SKILL=1 git -C "$MAIN_ROOT" branch -D "$branch" 2>/dev/null; then
    printf 'Deleted local branch: %s\n' "$branch"
    local_deleted=$((local_deleted + 1)) || true
  else
    printf 'WARN: local branch delete failed: %s\n' "$branch" >&2
    errors+=("local:$branch")
  fi
done

# ─── No-PR deletion pass (requires --apply AND --delete-no-pr) ──────────────

if [[ "$APPLY" == "1" ]] && [[ "$DELETE_NO_PR" == "1" ]] && [[ "${#no_pr_branches[@]}" -gt 0 ]]; then
  for branch in "${no_pr_branches[@]}"; do
    # Reachability was verified at classification time; every branch here is safe.
    if SWEEP_BRANCHES_SKILL=1 git -C "$MAIN_ROOT" branch -D "$branch" 2>/dev/null; then
      printf 'Deleted no-PR local branch: %s\n' "$branch"
      no_pr_deleted=$(( no_pr_deleted + 1 )) || true
    else
      printf 'WARN: no-PR local branch delete failed: %s\n' "$branch" >&2
      errors+=("no-pr:$branch")
    fi
  done
fi

# ─── Remote deletion pass ────────────────────────────────────────────────────

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

# ─── Summary output ─────────────────────────────────────────────────────────

if [[ "$CI_MODE" == "1" ]]; then
  errs_json="[]"
  if [[ ${#errors[@]} -gt 0 ]]; then
    errs_json="$(printf '%s\n' "${errors[@]}" | node -e \
      'const xs=require("fs").readFileSync(0,"utf8").split(/\r?\n/).filter(Boolean);process.stdout.write(JSON.stringify(xs))')"
  fi
  printf '{"scanned":%d,"candidates":%d,"local_deleted":%d,"remote_deleted":%d,"remote_delete_failed":%d,"skipped_unmerged":%d,"skipped_young":%d,"no_pr_candidates":%d,"no_pr_deleted":%d,"no_pr_skipped_young":%d,"no_pr_skipped_unreachable":%d,"pr_state_unknown":%d,"unmerged_pr_skipped":%d,"errors":%s}\n' \
    "$scanned" "$candidates" "$local_deleted" "$remote_deleted" \
    "$remote_delete_failed" "$skipped_unmerged" "$skipped_young" \
    "$no_pr_candidates" "$no_pr_deleted" "$no_pr_skipped_young" \
    "$no_pr_skipped_unreachable" "$pr_state_unknown" \
    "$unmerged_pr_skipped" \
    "$errs_json"
else
  printf 'sweep-branches summary:\n'
  printf '  scanned: %d\n' "$scanned"
  printf '  candidates: %d\n' "$candidates"
  printf '  local_deleted: %d\n' "$local_deleted"
  printf '  remote_deleted: %d\n' "$remote_deleted"
  printf '  remote_delete_failed: %d\n' "$remote_delete_failed"
  printf '  skipped_unmerged: %d\n' "$skipped_unmerged"
  printf '  skipped_young: %d\n' "$skipped_young"
  printf '  no_pr_candidates: %d\n' "$no_pr_candidates"
  printf '  no_pr_deleted: %d\n' "$no_pr_deleted"
  printf '  no_pr_skipped_young: %d\n' "$no_pr_skipped_young"
  printf '  no_pr_skipped_unreachable: %d\n' "$no_pr_skipped_unreachable"
  printf '  pr_state_unknown: %d\n' "$pr_state_unknown"
  printf '  unmerged_pr_skipped: %d\n' "$unmerged_pr_skipped"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  (dry-run; pass --apply to actually delete)\n'
  fi
fi

exit 0
