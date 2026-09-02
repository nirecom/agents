#!/usr/bin/env bash
#
# bin/sweep-worktrees.sh — reclaims zombie linked worktrees and their branches,
# and scans WORKTREE_BASE_DIR for orphan directories git's worktree registry
# does not track. Deletes by default; pass --dry-run to preview.
# Usage: sweep-worktrees.sh [--dry-run] [--min-age-hours N] [--ci-mode]
#                           [--apply] [--skip-gh-check] [--simulate-eperm]
# Entrypoint only — flag parsing, environment checks, the registered-worktree
# main loop, and pass sequencing; the passes live in bin/sweep-worktrees/
# (rules/coding/file-split.md Pattern A). Exit 0 on normal completion (a
# per-worktree EPERM is non-fatal), 1 only on a fatal setup error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sweep-write-mode.sh
source "$SCRIPT_DIR/lib/sweep-write-mode.sh"
# gates.sh defines norm_path, which empty-parent.sh and orphan-dirs.sh both
# call — it must be sourced first.
# shellcheck source=./sweep-worktrees/gates.sh
source "$SCRIPT_DIR/sweep-worktrees/gates.sh"
# shellcheck source=./sweep-worktrees/empty-parent.sh
source "$SCRIPT_DIR/sweep-worktrees/empty-parent.sh"
# shellcheck source=./sweep-worktrees/orphan-dirs.sh
source "$SCRIPT_DIR/sweep-worktrees/orphan-dirs.sh"
# shellcheck source=./sweep-worktrees/summary.sh
source "$SCRIPT_DIR/sweep-worktrees/summary.sh"

# ─── Defaults & flag parsing ────────────────────────────────────────────────

# DRY_RUN is the mirror of !APPLY, used by the orphan-dir scan for readability.
sweep_write_mode_init
MIN_AGE_HOURS=24
CI_MODE=0
SKIP_GH_CHECK=0
SIMULATE_EPERM=0
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
Usage: sweep-worktrees.sh [options]

Options:
EOF
  sweep_write_mode_usage_lines
  cat <<'EOF'
  --min-age-hours N     Skip worktrees modified more recently than N hours
                        (default 24).
  --sweep-age-days N    Age threshold in days for the empty-parent pass
                        (default 30; env SWEEP_AGE_DAYS).
  --ci-mode             Emit JSON summary on stdout (instead of plain text).
  --skip-gh-check       Skip the gh PR merged-state check (testing only).
  --simulate-eperm      Pretend every worktree remove failed with EPERM
                        (testing only).
  -h, --help            Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) sweep_write_mode_apply ;;
    --dry-run) sweep_write_mode_dry_run ;;
    --min-age-hours)
      shift
      MIN_AGE_HOURS="${1:?--min-age-hours requires a value}"
      ;;
    --sweep-age-days)
      shift
      SWEEP_AGE_DAYS="${1:?--sweep-age-days requires a value}"
      validate_sweep_age_days "$SWEEP_AGE_DAYS"
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
if [[ -z "${WORKTREE_BASE_DIR:-}" ]]; then
  WORKTREE_BASE_DIR="$(cd "$AGENTS_CONFIG_DIR" && get-config-var WORKTREE_BASE_DIR 2>/dev/null || echo "")"
fi
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
skipped_eperm=0
skipped_unmerged=0
skipped_dirty=0
orphan_dirs_removed=0
orphan_dirs_skipped_has_git=0
orphan_dirs_skipped_young=0
orphan_dirs_skipped_registered=0
orphan_dirs_skipped_failed=0
orphan_dirs_skipped_has_files=0
orphan_dirs_skipped_repo_mismatch=0
empty_parents_candidates=0
empty_parents_removed=0
empty_parents_skipped_young=0
empty_parents_skipped_nonempty=0
empty_parents_skipped_registered=0
errors=()

# ─── Main loop: enumerate linked worktrees ──────────────────────────────────

# Parse `git worktree list --porcelain` into records separated by blank lines.
porcelain="$(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null || true)"

main_root_norm="$(norm_path "$MAIN_ROOT")"

# ── Cross-repo registered-worktree discovery (#809) ─────────────────────────
# Snapshot the registry BEFORE the main loop modifies it via `git worktree
# remove`, so the empty-parent pass can still recognize parents whose leaf
# was registered at the start of the run.
declare -A DISCOVERED_MAIN_ROOTS=()
declare -A REGISTERED_WT_PARENTS=()
discover_registered_wt_parents

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

  # ── Freshness gate (FIRST — before merged-PR check) ──────────────────────
  # Per #1414, is_fresh MUST be checked unconditionally so that newly created
  # worktrees are NEVER deleted regardless of merged-PR state or clean-check
  # relaxation. This gate runs before any other check.
  if is_fresh "$wt_path"; then
    return 0
  fi

  # PR merged check (cache result).
  local merged_pr=0
  if is_pr_merged "$branch"; then
    merged_pr=1
  fi
  if [[ "$merged_pr" == "0" ]]; then
    skipped_unmerged=$((skipped_unmerged + 1)) || true
    return 0
  fi

  # Clean working tree check (tracked files only — untracked ignored).
  if ! is_clean_tracked_only "$wt_path"; then
    skipped_dirty=$((skipped_dirty + 1)) || true
    return 0
  fi

  # All 4 conditions met — candidate.
  candidates=$((candidates + 1)) || true

  if [[ "$APPLY" != "1" ]]; then
    printf 'DRY-RUN: candidate worktree=%s branch=%s\n' "$wt_path" "$branch"
    return 0
  fi

  # Release the CodeGraph index lock (Windows file lock) before removal.
  if command -v node >/dev/null 2>&1; then
    node "$AGENTS_CONFIG_DIR/bin/codegraph-lifecycle.js" stop --path "$wt_path" || true
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
    printf 'WARN: branch -D %s failed; will be reclaimed next cycle\n' \
      "$branch" >&2
  fi
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

# ── Orphan-directory scan pass ──────────────────────────────────────────────
sweep_orphan_dirs

# ── Empty-parent pass (#809) ────────────────────────────────────────────────
sweep_empty_parents

# ─── Stale .worktree-backup cleanup ─────────────────────────────────────────

sweep_stale_backups

# ─── Summary output ─────────────────────────────────────────────────────────

emit_summary

exit 0
