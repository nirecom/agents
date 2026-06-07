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

usage() {
  cat <<'EOF'
Usage: sweep-branches.sh [options]

Options:
  --apply               Actually delete (default is dry-run).
  --dry-run             Explicit dry-run (default).
  --min-age-hours N     Skip local branches whose last commit is more recent
                        than N hours (default 24). Remote branches are not
                        age-gated — only the PR-merged check applies.
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
errors=()

# Lazily resolved from gh repo view.
REPO_OWNER=""
REPO_NAME=""

# ─── Helpers ────────────────────────────────────────────────────────────────

# True (return 0) if a PR with head == branch is merged.
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
  local out
  if ! out="$(gh pr list -H "$branch" --state merged \
      --json number --jq 'length > 0' 2>/dev/null)"; then
    printf 'WARN: gh pr list failed for branch %s; skipping\n' "$branch" >&2
    return 1
  fi
  [[ "$out" == "true" ]]
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

# Local branches
while IFS= read -r branch; do
  [[ -z "$branch" ]] && continue
  scanned=$((scanned + 1)) || true
  if is_protected "$branch"; then
    continue
  fi
  # Age gate for local branches.
  if is_fresh "refs/heads/$branch"; then
    skipped_young=$((skipped_young + 1)) || true
    continue
  fi
  # PR merged check.
  if ! is_pr_merged "$branch"; then
    skipped_unmerged=$((skipped_unmerged + 1)) || true
    continue
  fi
  local_candidates+=("$branch")
  candidates=$((candidates + 1)) || true
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
  printf '{"scanned":%d,"candidates":%d,"local_deleted":%d,"remote_deleted":%d,"remote_delete_failed":%d,"skipped_unmerged":%d,"skipped_young":%d,"errors":%s}\n' \
    "$scanned" "$candidates" "$local_deleted" "$remote_deleted" \
    "$remote_delete_failed" "$skipped_unmerged" "$skipped_young" \
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
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  (dry-run; pass --apply to actually delete)\n'
  fi
fi

exit 0
