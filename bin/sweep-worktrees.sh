#!/usr/bin/env bash
#
# bin/sweep-worktrees.sh
#
# Reclaims zombie linked worktrees and their branches. Also scans
# WORKTREE_BASE_DIR for orphan directories not tracked by git's worktree
# registry. Default is dry-run; pass --apply to delete.
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
DRY_RUN=1 # mirror of !APPLY for orphan-dir scan readability

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
    --apply) APPLY=1; DRY_RUN=0 ;;
    --dry-run) APPLY=0; DRY_RUN=1 ;;
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
orphan_dirs_removed=0
orphan_dirs_skipped_has_git=0
orphan_dirs_skipped_young=0
orphan_dirs_skipped_registered=0
orphan_dirs_skipped_failed=0
orphan_dirs_skipped_has_files=0
orphan_dirs_skipped_repo_mismatch=0
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
  if ! out="$(gh pr list -H "$branch" --state merged \
      --json number --jq 'length > 0' 2>/dev/null)"; then
    printf 'WARN: gh pr list failed for branch %s; skipping\n' "$branch" >&2
    return 1
  fi
  [[ "$out" == "true" ]]
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

# ── Orphan-directory scan pre-pass guard ─────────────────────────────────────
registered_norm_file=$(mktemp)
trap "rm -f \"$registered_norm_file\" \"${registered_norm_file}.raw\"" EXIT
SKIP_ORPHAN_DIR_SCAN=0
if ! git -C "$MAIN_ROOT" worktree list --porcelain > "${registered_norm_file}.raw" 2>/dev/null; then
  printf 'WARNING: git worktree list --porcelain failed; skipping orphan-dir scan pass\n' >&2
  SKIP_ORPHAN_DIR_SCAN=1
else
  awk '/^worktree /{print substr($0,10)}' "${registered_norm_file}.raw" \
    | while IFS= read -r r; do norm_path "$r"; printf '\n'; done > "$registered_norm_file"
fi

# ── Orphan-directory scan pass ────────────────────────────────────────────────
# Reclaim directories under WORKTREE_BASE_DIR that are not in the git registry.
# Reuses hooks/cleanup-orphan-dir.js for the actual removal (4-AND safety gate).
if [[ "$SKIP_ORPHAN_DIR_SCAN" != "1" && -d "$WORKTREE_BASE_DIR" ]]; then
  current_repo_name="$(basename "$MAIN_ROOT")"
  wt_base_norm="$(norm_path "$WORKTREE_BASE_DIR")"

  while IFS= read -r -d '' cand_dir; do
    cand_name="$(basename "$cand_dir")"
    # Cross-repo guard: only sweep dirs whose final segment matches this repo.
    [[ "$cand_name" == "$current_repo_name" ]] || continue
    cand_norm="$(norm_path "$cand_dir")"

    # Gate (4): skip if registered (already handled by main loop).
    if grep -Fxq -- "$cand_norm" "$registered_norm_file"; then
      orphan_dirs_skipped_registered=$((orphan_dirs_skipped_registered + 1))
      continue
    fi
    # Gate (1): containment under WORKTREE_BASE_DIR.
    case "$cand_norm" in
      "$wt_base_norm"/*) ;;
      *) continue ;;
    esac
    # Gate (2): no .git present (file, dir, or dangling symlink).
    if [[ -e "$cand_dir/.git" || -L "$cand_dir/.git" ]]; then
      orphan_dirs_skipped_has_git=$((orphan_dirs_skipped_has_git + 1))
      continue
    fi
    # Gate (3): mtime check (older than --min-age-hours).
    if is_fresh "$cand_dir"; then
      orphan_dirs_skipped_young=$((orphan_dirs_skipped_young + 1))
      continue
    fi
    # Gate (5): cross-repo ownership proof. Requires WORKTREE_NOTES.md with a
    # `Main repo:` line matching the current MAIN_ROOT (forward-slash form).
    # Basename match alone is not unique ownership (two unrelated repos can
    # share `agents`/`dotfiles` basenames under different parent paths), so
    # legacy notes lacking the field and missing notes files are SKIPPED —
    # never fall through to basename match.
    #
    # Gate (4) "empty-or-notes-only" was intentionally removed: a partial
    # `git worktree remove` (removes .git + registry entry but fails on the
    # filesystem due to e.g. MAX_PATH) leaves a full checkout with no .git.
    # That directory has proven ownership via Gate (5) and is safe to delete
    # via cleanup-orphan-dir.js --force-if-not-registered. Directories without
    # a valid WORKTREE_NOTES.md are rejected by Gate (5) regardless of content.
    notes_file="$cand_dir/WORKTREE_NOTES.md"
    if [[ ! -f "$notes_file" ]]; then
      orphan_dirs_skipped_repo_mismatch=$((orphan_dirs_skipped_repo_mismatch + 1))
      continue
    fi
    recorded="$( { grep -m1 -E '^Main repo:[[:space:]]*' "$notes_file" 2>/dev/null || true; } | sed -E 's/^Main repo:[[:space:]]*//' | tr -d '\r')"
    if [[ -z "$recorded" ]]; then
      orphan_dirs_skipped_repo_mismatch=$((orphan_dirs_skipped_repo_mismatch + 1))
      continue
    fi
    main_norm_fs="$(norm_path "$MAIN_ROOT")"
    rec_norm_fs="$(norm_path "$recorded")"
    if [[ "$rec_norm_fs" != "$main_norm_fs" ]]; then
      orphan_dirs_skipped_repo_mismatch=$((orphan_dirs_skipped_repo_mismatch + 1))
      continue
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      printf 'would remove orphan dir: %s\n' "$cand_dir" >&2
    else
      node_out="$(WORKTREE_BASE_DIR="$WORKTREE_BASE_DIR" \
        node "$AGENTS_CONFIG_DIR/hooks/cleanup-orphan-dir.js" \
        --force-if-not-registered "$cand_dir" 2>&1)"
      node_rc=$?
      if [[ "$node_rc" -eq 0 ]]; then
        orphan_dirs_removed=$((orphan_dirs_removed + 1))
      else
        orphan_dirs_skipped_failed=$((orphan_dirs_skipped_failed + 1))
        printf 'WARNING: cleanup-orphan-dir failed for %s: %s\n' "$cand_dir" "$node_out" >&2
      fi
    fi
  done < <(find "$WORKTREE_BASE_DIR" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)
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
  printf '{"scanned":%d,"candidates":%d,"worktree_removed":%d,"branch_deleted":%d,"skipped_eperm":%d,"skipped_unmerged":%d,"orphan_dirs_removed":%d,"orphan_dirs_skipped_has_git":%d,"orphan_dirs_skipped_young":%d,"orphan_dirs_skipped_registered":%d,"orphan_dirs_skipped_failed":%d,"orphan_dirs_skipped_has_files":%d,"orphan_dirs_skipped_repo_mismatch":%d,"errors":%s}\n' \
    "$scanned" "$candidates" "$worktree_removed" "$branch_deleted" \
    "$skipped_eperm" "$skipped_unmerged" "$orphan_dirs_removed" \
    "$orphan_dirs_skipped_has_git" "$orphan_dirs_skipped_young" \
    "$orphan_dirs_skipped_registered" "$orphan_dirs_skipped_failed" \
    "$orphan_dirs_skipped_has_files" "$orphan_dirs_skipped_repo_mismatch" \
    "$errs_json"
else
  printf 'sweep-worktrees summary:\n'
  printf '  scanned: %d\n' "$scanned"
  printf '  candidates: %d\n' "$candidates"
  printf '  worktree_removed: %d\n' "$worktree_removed"
  printf '  branch_deleted: %d\n' "$branch_deleted"
  printf '  skipped_eperm: %d\n' "$skipped_eperm"
  printf '  skipped_unmerged: %d\n' "$skipped_unmerged"
  if [[ "$orphan_dirs_removed" -gt 0 ]]; then
    printf '  orphan_dirs_removed: %d\n' "$orphan_dirs_removed"
  fi
  skip_summary=""
  [[ "$orphan_dirs_skipped_has_git" -gt 0 ]] && skip_summary+=" has_git=$orphan_dirs_skipped_has_git"
  [[ "$orphan_dirs_skipped_young" -gt 0 ]] && skip_summary+=" young=$orphan_dirs_skipped_young"
  [[ "$orphan_dirs_skipped_registered" -gt 0 ]] && skip_summary+=" registered=$orphan_dirs_skipped_registered"
  [[ "$orphan_dirs_skipped_failed" -gt 0 ]] && skip_summary+=" failed=$orphan_dirs_skipped_failed"
  [[ "$orphan_dirs_skipped_has_files" -gt 0 ]] && skip_summary+=" has_files=$orphan_dirs_skipped_has_files"
  [[ "$orphan_dirs_skipped_repo_mismatch" -gt 0 ]] && skip_summary+=" repo_mismatch=$orphan_dirs_skipped_repo_mismatch"
  if [[ -n "$skip_summary" ]]; then
    printf '  orphan_dirs_skipped:%s\n' "$skip_summary"
  fi
  if [[ "$APPLY" != "1" ]]; then
    printf '  (dry-run; pass --apply to actually delete)\n'
  fi
fi

exit 0
