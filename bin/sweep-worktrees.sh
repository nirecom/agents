#!/usr/bin/env bash
#
# bin/sweep-worktrees.sh
#
# Reclaims zombie linked worktrees, their branches, and any
# pending-branch-delete- markers. Default is dry-run; pass --apply to delete.
#
# Usage:
#   sweep-worktrees.sh [--apply] [--min-age-hours N] [--ci-mode]
#                      [--dry-run] [--skip-gh-check] [--simulate-eperm]
#
# Exit code: 0 on normal completion (per-worktree EPERM is non-fatal).
#            1 only on fatal setup error (missing AGENTS_CONFIG_DIR, git, etc.).

set -euo pipefail

# ─── Defaults & flag parsing ────────────────────────────────────────────────

APPLY=0
MIN_AGE_HOURS=24
CI_MODE=0
SKIP_GH_CHECK=0
SIMULATE_EPERM=0

usage() {
  cat <<'EOF'
Usage: sweep-worktrees.sh [options]

Options:
  --apply               Actually delete (default is dry-run).
  --dry-run             Explicit dry-run (default).
  --min-age-hours N     Skip worktrees modified more recently than N hours
                        (default 24).
  --ci-mode             Emit JSON summary on stdout (instead of plain text).
  --skip-gh-check       Skip the gh PR merged-state check (testing only).
  --simulate-eperm      Pretend every worktree remove failed with EPERM
                        (testing only).
  -h, --help            Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --min-age-hours)
      shift
      MIN_AGE_HOURS="${1:?--min-age-hours requires a value}"
      ;;
    --ci-mode) CI_MODE=1 ;;
    --skip-gh-check) SKIP_GH_CHECK=1 ;;
    --simulate-eperm) SIMULATE_EPERM=1 ;;
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
PLANS_DIR="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
WORKTREE_BASE_DIR="${WORKTREE_BASE_DIR:-$HOME/git/worktrees}"

# Sanity check: git in path
if ! command -v git >/dev/null 2>&1; then
  printf 'ERROR: git not found in PATH\n' >&2
  exit 1
fi

# Resolve main worktree root (the cwd is expected to be inside it).
if ! MAIN_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  printf 'ERROR: not inside a git repository\n' >&2
  exit 1
fi

# ─── Counters ───────────────────────────────────────────────────────────────

scanned=0
candidates=0
worktree_removed=0
branch_deleted=0
marker_cleaned=0
skipped_eperm=0
skipped_unmerged=0
errors=()

# ─── Helpers ────────────────────────────────────────────────────────────────

# realpath -m equivalent that returns the input on failure (path may not exist).
norm_path() {
  local p="$1"
  if [[ -z "$p" ]]; then
    printf ''
    return
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$p" 2>/dev/null || printf '%s' "$p"
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
  if ! out="$(gh pr list --state merged --search "head:${branch}" \
      --json headRefName,number --limit 5 \
      --jq --arg branch "$branch" \
      'map(select(.headRefName==$branch)) | length > 0' \
      2>/dev/null)"; then
    printf 'WARN: gh pr list failed for branch %s; skipping\n' "$branch" >&2
    return 1
  fi
  [[ "$out" == "true" ]]
}

# URL-encode a string via node (agents repo dependency).
# Returns 1 silently when node is unavailable — callers must handle gracefully.
encode_branch() {
  local b="$1"
  if ! command -v node >/dev/null 2>&1; then
    return 1
  fi
  printf '%s' "$b" | node -e \
    'process.stdout.write(encodeURIComponent(require("fs").readFileSync(0,"utf8")))'
}

decode_branch() {
  local e="$1"
  if ! command -v node >/dev/null 2>&1; then
    return 1
  fi
  printf '%s' "$e" | node -e \
    'process.stdout.write(decodeURIComponent(require("fs").readFileSync(0,"utf8")))'
}

# Remove markers whose recorded worktree path matches the just-removed wt.
remove_matching_markers() {
  local branch="$1"
  local wt_path="$2"
  local encoded marker_dir marker recorded real_recorded real_path
  marker_dir="$PLANS_DIR/worktree-end"
  [[ -d "$marker_dir" ]] || return 0
  # node required for encoding; skip silently when unavailable.
  if ! encoded="$(encode_branch "$branch" 2>/dev/null)"; then
    printf 'WARN: node not available; skipping marker cleanup for %s\n' "$branch" >&2
    return 0
  fi
  shopt -s nullglob
  for marker in "$marker_dir"/pending-branch-delete-*--"$encoded"; do
    [[ -f "$marker" ]] || continue
    recorded="$(sed -n '2p' "$marker" | tr -d '\r' || true)"
    [[ -n "$recorded" ]] || continue
    real_recorded="$(norm_path "$recorded")"
    real_path="$(norm_path "$wt_path")"
    if [[ "$real_recorded" == "$real_path" ]]; then
      rm -f -- "$marker"
      marker_cleaned=$((marker_cleaned + 1)) || true
    fi
  done
  shopt -u nullglob
}

# ─── Main loop: enumerate linked worktrees ──────────────────────────────────

# Parse `git worktree list --porcelain` into records separated by blank lines.
porcelain="$(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null || true)"

main_root_norm="$(norm_path "$MAIN_ROOT")"

current_path=""
current_branch=""

process_record() {
  local wt_path="$1"
  local branch="$2"
  scanned=$((scanned + 1)) || true

  # Skip main worktree.
  local wt_norm
  wt_norm="$(norm_path "$wt_path")"
  if [[ "$wt_norm" == "$main_root_norm" ]]; then
    return 0
  fi

  # Detached HEAD: skip with warning.
  if [[ -z "$branch" ]]; then
    printf 'WARN: skipping detached worktree at %s; reclaim manually if intended\n' \
      "$wt_path" >&2
    return 0
  fi

  # PR merged check.
  if ! is_pr_merged "$branch"; then
    skipped_unmerged=$((skipped_unmerged + 1)) || true
    return 0
  fi

  # Clean working tree check.
  if ! is_clean_wt "$wt_path"; then
    return 0
  fi

  # mtime threshold check.
  if is_fresh "$wt_path"; then
    return 0
  fi

  # All 4 conditions met — candidate.
  candidates=$((candidates + 1)) || true

  if [[ "$APPLY" != "1" ]]; then
    printf 'DRY-RUN: candidate worktree=%s branch=%s\n' "$wt_path" "$branch"
    return 0
  fi

  # (a) git worktree remove.
  if [[ "$SIMULATE_EPERM" == "1" ]]; then
    printf 'WARN: simulated EPERM for %s\n' "$wt_path" >&2
    skipped_eperm=$((skipped_eperm + 1)) || true
    return 0
  fi

  local err_file
  err_file="$(mktemp 2>/dev/null || printf '%s' "/tmp/wt_remove_err.$$")"
  if git -C "$MAIN_ROOT" worktree remove "$wt_path" 2>"$err_file"; then
    worktree_removed=$((worktree_removed + 1)) || true
  else
    local err
    err="$(cat "$err_file" 2>/dev/null || true)"
    rm -f "$err_file"
    printf 'WARN: git worktree remove failed for %s: %s\n' "$wt_path" "$err" >&2
    skipped_eperm=$((skipped_eperm + 1)) || true
    return 0
  fi
  rm -f "$err_file"

  # (b) git branch -D (cascade rule: only after worktree gone).
  if git -C "$MAIN_ROOT" branch -D "$branch" 2>/dev/null; then
    branch_deleted=$((branch_deleted + 1)) || true
  else
    printf 'WARN: branch -D %s failed; marker will be reclaimed next cycle\n' \
      "$branch" >&2
  fi

  # (c) marker rm — wildcard glob + content matching.
  remove_matching_markers "$branch" "$wt_path"
}

while IFS= read -r line; do
  if [[ "$line" == worktree\ * ]]; then
    # End of previous record if any.
    if [[ -n "$current_path" ]]; then
      process_record "$current_path" "$current_branch"
    fi
    current_path="${line#worktree }"
    current_branch=""
  elif [[ "$line" == branch\ refs/heads/* ]]; then
    current_branch="${line#branch refs/heads/}"
  elif [[ -z "$line" ]]; then
    if [[ -n "$current_path" ]]; then
      process_record "$current_path" "$current_branch"
      current_path=""
      current_branch=""
    fi
  fi
done <<< "$porcelain"

# Handle trailing record (no terminating blank line).
if [[ -n "$current_path" ]]; then
  process_record "$current_path" "$current_branch"
fi

# ─── Orphan-marker 2nd pass ─────────────────────────────────────────────────

marker_dir="$PLANS_DIR/worktree-end"
if [[ -d "$marker_dir" ]]; then
  shopt -s nullglob
  for marker in "$marker_dir"/pending-branch-delete-*; do
    [[ -f "$marker" ]] || continue
    marker_name="$(basename "$marker")"
    encoded="${marker_name##*--}"
    [[ -n "$encoded" ]] || continue
    # node required for decoding; skip orphan pass silently when unavailable.
    if ! branch_name="$(decode_branch "$encoded" 2>/dev/null)"; then
      continue
    fi
    [[ -n "$branch_name" ]] || continue
    # Verify marker's recorded worktree path belongs to this repo before acting.
    orphan_marker_recorded="$(sed -n '2p' "$marker" | tr -d '\r' 2>/dev/null || true)"
    if [[ -n "$orphan_marker_recorded" ]]; then
      orphan_real_recorded="$(norm_path "$orphan_marker_recorded")"
      orphan_wt_base="${WORKTREE_BASE_DIR:-$HOME/git/worktrees}"
      orphan_real_wt_base="$(norm_path "$orphan_wt_base")"
      orphan_real_main="$(norm_path "$MAIN_ROOT")"
      case "$orphan_real_recorded" in
        "$orphan_real_wt_base"/*|"$orphan_real_main"/*) ;; # belongs to this repo
        *)
          # Marker recorded path is outside known paths — skip to avoid cross-repo branch -D.
          printf 'WARN: skipping orphan marker %s (recorded path outside known dirs)\n' \
            "$marker" >&2
          continue
          ;;
      esac
    fi

    # If branch is gone, the marker is orphan.
    if ! git -C "$MAIN_ROOT" show-ref --verify --quiet \
        "refs/heads/${branch_name}" 2>/dev/null; then
      if [[ "$APPLY" == "1" ]]; then
        rm -f -- "$marker"
        marker_cleaned=$((marker_cleaned + 1)) || true
      else
        printf 'DRY-RUN: would remove orphan marker (branch gone): %s\n' "$marker"
      fi
      continue
    fi

    # Branch exists — is it checked out in any worktree?
    if ! git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null \
        | grep -q "^branch refs/heads/${branch_name}\$"; then
      # Orphan branch (not in any worktree).
      if [[ "$APPLY" == "1" ]]; then
        if git -C "$MAIN_ROOT" branch -D "$branch_name" 2>/dev/null; then
          branch_deleted=$((branch_deleted + 1)) || true
          rm -f -- "$marker"
          marker_cleaned=$((marker_cleaned + 1)) || true
        fi
      else
        printf 'DRY-RUN: would delete orphan branch %s and its marker\n' \
          "$branch_name"
      fi
    fi
  done
  shopt -u nullglob
fi

# ─── Stale .worktree-backup cleanup ─────────────────────────────────────────

backup_base="$MAIN_ROOT/.worktree-backup"
if [[ -d "$backup_base" ]]; then
  backup_threshold=$((MIN_AGE_HOURS * 7))
  backup_threshold_mins=$((backup_threshold * 60))
  real_base="$(norm_path "$backup_base")"
  while IFS= read -r -d '' backup_dir; do
    real_backup="$(norm_path "$backup_dir")"
    # Reject paths containing ".."
    case "$real_backup" in
      *..*)
        printf 'WARN: path traversal rejected: %s\n' "$backup_dir" >&2
        continue
        ;;
    esac
    # Must be strictly under real_base.
    case "$real_backup" in
      "$real_base"/*) ;;
      *)
        printf 'WARN: unsafe path skipped: %s\n' "$backup_dir" >&2
        continue
        ;;
    esac
    if [[ "$APPLY" == "1" ]]; then
      rm -rf -- "$backup_dir"
    else
      printf 'DRY-RUN: would remove stale backup: %s\n' "$backup_dir"
    fi
  done < <(find "$backup_base" -maxdepth 1 -mindepth 1 -type d \
    -not -mmin "-$backup_threshold_mins" -print0 2>/dev/null)
fi

# ─── Summary output ─────────────────────────────────────────────────────────

if [[ "$CI_MODE" == "1" ]]; then
  errs_json="[]"
  if [[ ${#errors[@]} -gt 0 ]]; then
    errs_json="$(printf '%s\n' "${errors[@]}" | node -e \
      'const xs=require("fs").readFileSync(0,"utf8").split(/\r?\n/).filter(Boolean);process.stdout.write(JSON.stringify(xs))')"
  fi
  printf '{"scanned":%d,"candidates":%d,"worktree_removed":%d,"branch_deleted":%d,"marker_cleaned":%d,"skipped_eperm":%d,"skipped_unmerged":%d,"errors":%s}\n' \
    "$scanned" "$candidates" "$worktree_removed" "$branch_deleted" \
    "$marker_cleaned" "$skipped_eperm" "$skipped_unmerged" "$errs_json"
else
  printf 'sweep-worktrees summary:\n'
  printf '  scanned: %d\n' "$scanned"
  printf '  candidates: %d\n' "$candidates"
  printf '  worktree_removed: %d\n' "$worktree_removed"
  printf '  branch_deleted: %d\n' "$branch_deleted"
  printf '  marker_cleaned: %d\n' "$marker_cleaned"
  printf '  skipped_eperm: %d\n' "$skipped_eperm"
  printf '  skipped_unmerged: %d\n' "$skipped_unmerged"
  if [[ "$APPLY" != "1" ]]; then
    printf '  (dry-run; pass --apply to actually delete)\n'
  fi
fi

exit 0
