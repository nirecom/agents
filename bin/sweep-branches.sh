#!/usr/bin/env bash
#
# bin/sweep-branches.sh
#
# Reclaims merged-but-undeleted local and remote branches. Local branches are
# age-gated (--min-age-hours); remote branches are only PR-merged checked.
# Deletes by default; pass --dry-run to preview.
#
# Usage:
#   sweep-branches.sh [--dry-run] [--min-age-hours N] [--ci-mode]
#                     [--apply] [--skip-gh-check]
#
# Entrypoint only: flag parsing, environment checks, candidate collection, and
# pass sequencing. The logic lives in the sibling bin/sweep-branches/ modules
# (rules/coding/file-split.md Pattern A):
#   pr-state.sh      — gh-backed PR state classification
#   gates.sh         — pure protection / age / reachability gates
#   delete-passes.sh — the three deletion passes
#   summary.sh       — CI-mode JSON and plain-text summary
#
# Exit code: 0 on normal completion (per-branch failures are non-fatal).
#            1 only on fatal setup error (missing AGENTS_CONFIG_DIR, git, etc.).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sweep-write-mode.sh
source "$SCRIPT_DIR/lib/sweep-write-mode.sh"
# shellcheck source=./sweep-branches/pr-state.sh
source "$SCRIPT_DIR/sweep-branches/pr-state.sh"
# shellcheck source=./sweep-branches/gates.sh
source "$SCRIPT_DIR/sweep-branches/gates.sh"
# shellcheck source=./sweep-branches/delete-passes.sh
source "$SCRIPT_DIR/sweep-branches/delete-passes.sh"
# shellcheck source=./sweep-branches/summary.sh
source "$SCRIPT_DIR/sweep-branches/summary.sh"

# ─── Defaults & flag parsing ────────────────────────────────────────────────

sweep_write_mode_init
MIN_AGE_HOURS=24
CI_MODE=0
SKIP_GH=0
DELETE_NO_PR=0
TIMEOUT_SECONDS=120
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
EOF
  sweep_write_mode_usage_lines
  cat <<'EOF'
  --min-age-hours N     Skip local branches whose last commit is more recent
                        than N hours (default 24). Remote branches are not
                        age-gated — only the PR-merged check applies.
  --delete-no-pr        Also delete local branches that have no PR at all
                        (age-gated by --sweep-age-days). --delete-no-pr alone
                        deletes; add --dry-run to preview.
  --sweep-age-days N    Age threshold in days for no-PR detection
                        (default 30; env SWEEP_AGE_DAYS).
  --ci-mode             Emit JSON summary on stdout (instead of plain text).
  --skip-gh-check       Skip the gh PR merged-state check (testing only).
  --timeout-seconds N   Timeout in seconds for git branch -D (default 120).
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
    --timeout-seconds)
      shift
      TIMEOUT_SECONDS="${1:?--timeout-seconds requires a value}"
      if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SECONDS" -lt 1 ]]; then
        printf 'ERROR: --timeout-seconds must be a positive integer, got: %s\n' "$TIMEOUT_SECONDS" >&2
        exit 1
      fi
      ;;
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
skipped_worktree_locked=0
pr_state_unknown=0
unmerged_pr_skipped=0
no_pr_branches=()
errors=()

# Lazily resolved from gh repo view.
REPO_OWNER=""
REPO_NAME=""

# Cached default-branch ref (e.g. "origin/main"); resolved on first use.
DEFAULT_REMOTE_REF=""

# ─── Candidate collection ───────────────────────────────────────────────────

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

# ─── Deletion passes ────────────────────────────────────────────────────────

run_local_delete_pass
run_no_pr_delete_pass
run_remote_delete_pass

# ─── Summary output ─────────────────────────────────────────────────────────

emit_summary

exit 0
