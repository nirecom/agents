#!/bin/bash
# tests/fix-enforce-worktree-main-cleanup.sh
# Tests: hooks/enforce-worktree.js
# Tags: enforce-worktree-main-cleanup
# Tests for isAllowedMainWorktreeCleanup() — #297
set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _A="$(cygpath -m "$AGENTS_DIR")"; else _A="$AGENTS_DIR"; fi
GUARD_JS="${_A}/hooks/enforce-worktree.js"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}
TMPBASE="$(mktemp -d 2>/dev/null || mktemp -d -t mctest)"
trap 'rm -rf "$TMPBASE" 2>/dev/null' EXIT

# Main repo with NO linked worktrees
MAIN_CLEAN="$TMPBASE/main-clean"
mkdir -p "$MAIN_CLEAN"
git -C "$MAIN_CLEAN" init -q -b main
git -C "$MAIN_CLEAN" config user.email "test@example.com"
git -C "$MAIN_CLEAN" config user.name "Test"
git -C "$MAIN_CLEAN" config core.hooksPath /dev/null
git -C "$MAIN_CLEAN" commit --allow-empty --no-verify -q -m init
if command -v cygpath >/dev/null 2>&1; then MAIN_CLEAN_N="$(cygpath -m "$MAIN_CLEAN")"; else MAIN_CLEAN_N="$MAIN_CLEAN"; fi

# Main repo WITH one linked worktree
MAIN_DIRTY="$TMPBASE/main-dirty"
mkdir -p "$MAIN_DIRTY"
git -C "$MAIN_DIRTY" init -q -b main
git -C "$MAIN_DIRTY" config user.email "test@example.com"
git -C "$MAIN_DIRTY" config user.name "Test"
git -C "$MAIN_DIRTY" config core.hooksPath /dev/null
git -C "$MAIN_DIRTY" commit --allow-empty --no-verify -q -m init
git -C "$MAIN_DIRTY" worktree add -q -b feature-x "$TMPBASE/dirty-wt" 2>/dev/null
if command -v cygpath >/dev/null 2>&1; then MAIN_DIRTY_N="$(cygpath -m "$MAIN_DIRTY")"; else MAIN_DIRTY_N="$MAIN_DIRTY"; fi

# Separate unrelated repo for -C /other tests
OTHER_REPO="$TMPBASE/other"
mkdir -p "$OTHER_REPO"
git -C "$OTHER_REPO" init -q
git -C "$OTHER_REPO" config user.email "test@example.com"
git -C "$OTHER_REPO" config user.name "Test"
git -C "$OTHER_REPO" commit --allow-empty --no-verify -q -m init
if command -v cygpath >/dev/null 2>&1; then OTHER_N="$(cygpath -m "$OTHER_REPO")"; else OTHER_N="$OTHER_REPO"; fi

check_mc() {
  run_with_timeout node -e "
    const {isAllowedMainWorktreeCleanup}=require('$GUARD_JS');
    console.log(isAllowedMainWorktreeCleanup(process.argv[1],process.argv[2])?'allow':'reject');
  " -- "$1" "$2" 2>/dev/null
}
assert_allow() { local got; got="$(check_mc "$1" "$2")"; [ "$got" = "allow"  ] && pass "$3" || fail "$3 (got=$got)"; }
assert_block() { local got; got="$(check_mc "$1" "$2")"; [ "$got" = "reject" ] && pass "$3" || fail "$3 (got=$got)"; }

# Allow: no linked worktrees
assert_allow "git stash push -m wip"           "$MAIN_CLEAN_N" "S1: stash push (no linked WT)"
assert_allow "git stash pop"                    "$MAIN_CLEAN_N" "S2: stash pop"
assert_allow "git stash apply stash@{0}"        "$MAIN_CLEAN_N" "S3: stash apply"
assert_allow "git stash drop stash@{0}"         "$MAIN_CLEAN_N" "S4: stash drop"
assert_allow "git stash clear"                  "$MAIN_CLEAN_N" "S5: stash clear"
assert_allow "git stash -u"                     "$MAIN_CLEAN_N" "S6: stash -u (push variant)"
assert_allow "git checkout -- README.md"        "$MAIN_CLEAN_N" "S7: checkout -- file"
assert_allow "git checkout HEAD -- README.md"   "$MAIN_CLEAN_N" "S8: checkout HEAD -- file"
assert_allow "git restore README.md"            "$MAIN_CLEAN_N" "S9: restore file"
assert_allow "git restore --staged README.md"   "$MAIN_CLEAN_N" "S10: restore --staged"
assert_allow "git -C \"$MAIN_CLEAN_N\" stash pop" "$MAIN_CLEAN_N" "S10b: -C repoRoot stash"

# Block: linked worktree exists — cleanup NOT complete
assert_block "git stash push"                   "$MAIN_DIRTY_N" "S11: stash blocked (linked WT exists)"
assert_block "git stash pop"                    "$MAIN_DIRTY_N" "S12: stash pop blocked (linked WT)"
assert_block "git restore README.md"            "$MAIN_DIRTY_N" "S13: restore blocked (linked WT)"

# Block: out-of-scope stash subcommands
assert_block "git stash branch newbranch"       "$MAIN_CLEAN_N" "S14: stash branch blocked"
assert_block "git stash show"                   "$MAIN_CLEAN_N" "S15: stash show blocked"
assert_block "git stash store sha"              "$MAIN_CLEAN_N" "S16: stash store blocked"
assert_block "git stash create"                 "$MAIN_CLEAN_N" "S17: stash create blocked"
assert_block "git stash list"                   "$MAIN_CLEAN_N" "S18: stash list blocked"

# Block: restore --source (rewrite from arbitrary tree)
assert_block "git restore --source=HEAD~1 f"   "$MAIN_CLEAN_N" "S19: restore --source= blocked"
assert_block "git restore --source HEAD~1 f"   "$MAIN_CLEAN_N" "S20: restore --source <tree> blocked"

# Block: checkout without -- separator (branch switch)
assert_block "git checkout main"               "$MAIN_CLEAN_N" "S21: checkout branch blocked"
assert_block "git checkout -b feature/x"       "$MAIN_CLEAN_N" "S22: checkout -b blocked"
assert_block "git checkout -B feature/x"       "$MAIN_CLEAN_N" "S23: checkout -B blocked"
assert_block "git checkout -f main"            "$MAIN_CLEAN_N" "S24: checkout -f blocked"

# Block: shell chaining
assert_block "git stash pop && echo done"      "$MAIN_CLEAN_N" "S25: chaining blocked"

# Block: -C pointing at unrelated repo
assert_block "git -C \"$OTHER_N\" stash pop"  "$MAIN_CLEAN_N" "S26: -C /other blocked"

echo ""; echo "Results: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
