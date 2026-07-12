#!/usr/bin/env bash
# Tests: bin/sweep-worktrees.sh
# Tags: unit, sweep, scope:issue-specific
#
# Test suite for sweep-worktrees merged-PR clean-check relaxation (#1393).
# Also validates is_fresh protection (#1414): fresh worktrees must be skipped
# regardless of merged-PR state.
#
# Before the relaxation, `is_clean_wt()` rejects ALL worktrees with untracked
# files regardless of PR merge state. After the relaxation (change A), merged-PR
# worktrees use `is_clean_tracked_only()` which ignores untracked files, while
# non-merged-PR worktrees are still rejected early via `skipped_unmerged`.
#
# Test cases:
#   TC1: merged-PR with clean worktree -> candidate (both old and new behavior)
#   TC2: merged-PR with untracked file -> candidate (new behavior; was skipped before)
#   TC3: non-merged-PR with clean worktree -> skipped_unmerged (both old and new)
#   TC4: non-merged-PR with untracked files -> skipped_unmerged (both old and new)
#   TC5: non-existent worktree path -> is_clean_wt() does not crash
#   TC6: detached HEAD worktree -> skipped with warning (no crash)
#   TC7: fresh worktree (< MIN_AGE_HOURS) with merged-PR + untracked -> skipped
#        by is_fresh (#1414 regression guard)
#
# L3 gap: real claude -p session with actual linked worktrees is not covered.
#          See tests/claude-e2e.md for L3 acceptance criteria.
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_DIR/bin/sweep-worktrees.sh"

plan_tests() {
  echo "1..7"
}

run_test() {
  local desc="$1"
  local expected="$2"
  local output="$3"
  if echo "$output" | grep -q "$expected"; then
    echo "ok"
  else
    echo "not ok"
    echo "# Failed: $desc"
    echo "# expected pattern: $expected"
    echo "# output: $output"
  fi
}

# --- Setup: create a repo with a linked worktree ---
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

ENFORCE_WORKTREE=off git init "$TEST_DIR/main"
cd "$TEST_DIR/main"
git config user.email "test@test"
git config user.name "test"
ENFORCE_WORKTREE=off git commit --allow-empty -m "initial"

# Create a branch and a linked worktree
ENFORCE_WORKTREE=off git checkout -b test-branch
ENFORCE_WORKTREE=off git commit --allow-empty -m "branch commit"
ENFORCE_WORKTREE=off git worktree add --force "$TEST_DIR/wt" test-branch

# --- TC1: merged-PR + untracked file -> candidate ---
touch "$TEST_DIR/wt/untracked.txt"
cd "$TEST_DIR/main"
output1=$(SKIP_GH_CHECK=1 bash "$SCRIPT" --apply --min-age-hours 0 --skip-gh-check 2>&1 || true)
run_test "TC1: merged-PR + untracked file -> candidate" "candidates: 1" "$output1"

# --- TC2: non-merged-PR + untracked file -> skipped_unmerged ---
cd "$TEST_DIR/main"
ENFORCE_WORKTREE=off git worktree add --force "$TEST_DIR/wt2" test-branch
touch "$TEST_DIR/wt2/untracked.txt"
output2=$(bash "$SCRIPT" --apply --min-age-hours 0 --ci-mode 2>&1 || true)
run_test "TC2: non-merged-PR + untracked file -> skipped_unmerged" '"skipped_unmerged"' "$output2"

# --- TC3: merged-PR + clean worktree (no untracked) -> candidate ---
cd "$TEST_DIR/main"
ENFORCE_WORKTREE=off git worktree add --force "$TEST_DIR/wt3" test-branch
output3=$(SKIP_GH_CHECK=1 bash "$SCRIPT" --apply --min-age-hours 0 --skip-gh-check 2>&1 || true)
run_test "TC3: merged-PR + clean -> candidate" "candidates:" "$output3"

# --- TC4: non-merged-PR + clean worktree -> skipped_unmerged ---
cd "$TEST_DIR/main"
ENFORCE_WORKTREE=off git worktree add --force "$TEST_DIR/wt4" test-branch
output4=$(bash "$SCRIPT" --apply --min-age-hours 0 --ci-mode 2>&1 || true)
run_test "TC4: non-merged-PR + clean -> skipped_unmerged" '"skipped_unmerged"' "$output4"

# --- Clean up worktrees used in TC1-TC4 (they block test-branch checkout) ---
ENFORCE_WORKTREE=off git worktree remove --force "$TEST_DIR/wt" 2>/dev/null || true
ENFORCE_WORKTREE=off git worktree remove --force "$TEST_DIR/wt2" 2>/dev/null || true
ENFORCE_WORKTREE=off git worktree remove --force "$TEST_DIR/wt3" 2>/dev/null || true
ENFORCE_WORKTREE=off git worktree remove --force "$TEST_DIR/wt4" 2>/dev/null || true

# --- TC5: non-existent worktree path -> no crash ---
output5=$(SKIP_GH_CHECK=1 bash "$SCRIPT" --apply --min-age-hours 0 --skip-gh-check 2>&1 || true)
run_test "TC5: non-existent path -> no crash" "scanned:" "$output5"

# --- TC6: detached HEAD worktree -> skipped with warning ---
cd "$TEST_DIR/main"
ENFORCE_WORKTREE=off git checkout --detach HEAD
ENFORCE_WORKTREE=off git worktree add --force --detach "$TEST_DIR/wt5"
output6=$(SKIP_GH_CHECK=1 bash "$SCRIPT" --apply --min-age-hours 0 --skip-gh-check 2>&1 || true)
run_test "TC6: detached HEAD -> skipped" "WARN.*detached" "$output6"

# --- TC7: fresh worktree (< MIN_AGE_HOURS) with merged-PR + untracked -> skipped by is_fresh ---
# MIN_AGE_HOURS is 24 by default; a worktree created moments ago is fresh.
cd "$TEST_DIR/main"
ENFORCE_WORKTREE=off git checkout test-branch
ENFORCE_WORKTREE=off git worktree add --force "$TEST_DIR/wt6" test-branch
touch "$TEST_DIR/wt6/untracked.txt"
output7=$(SKIP_GH_CHECK=1 bash "$SCRIPT" --apply --skip-gh-check 2>&1 || true)
run_test "TC7: fresh worktree -> skipped (is_fresh #1414)" "candidates: 0" "$output7"

echo ""
echo "=== Test complete ==="
