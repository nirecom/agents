#!/bin/bash
# tests/fix-enforce-worktree-cd-worktree-remove.sh
# Tests for isAllowedCdWorktreeRemove() — #294
# Pattern: cd "<main>" && git [-C "<main>"] worktree remove|prune "<linked>"
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
TMPBASE="$(mktemp -d 2>/dev/null || mktemp -d -t cdwttest)"
trap 'rm -rf "$TMPBASE" 2>/dev/null' EXIT

MAIN="$TMPBASE/main"
OTHER="$TMPBASE/other"
mkdir -p "$MAIN" "$OTHER"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email "test@example.com"
git -C "$MAIN" config user.name "Test"
git -C "$MAIN" config core.hooksPath /dev/null
git -C "$MAIN" commit --allow-empty --no-verify -q -m init
git -C "$OTHER" init -q

# Create a REAL registered linked worktree
WT_LINKED="$TMPBASE/linked-wt"
git -C "$MAIN" worktree add -q -b feature-test "$WT_LINKED" 2>/dev/null

if command -v cygpath >/dev/null 2>&1; then
  MAIN_N="$(cygpath -m "$MAIN")"
  OTHER_N="$(cygpath -m "$OTHER")"
  WT_LINKED_N="$(cygpath -m "$WT_LINKED")"
else
  MAIN_N="$MAIN"; OTHER_N="$OTHER"; WT_LINKED_N="$WT_LINKED"
fi

check_cwr() {
  run_with_timeout node -e "
    const {isAllowedCdWorktreeRemove}=require('$GUARD_JS');
    console.log(isAllowedCdWorktreeRemove(process.argv[1],process.argv[2])?'allow':'reject');
  " -- "$1" "$2" 2>/dev/null
}
assert_allow() { local got; got="$(check_cwr "$1" "$2")"; [ "$got" = "allow"  ] && pass "$3" || fail "$3 (got=$got)"; }
assert_block() { local got; got="$(check_cwr "$1" "$2")"; [ "$got" = "reject" ] && pass "$3" || fail "$3 (got=$got)"; }

# Allow: cd <main> && git worktree remove|prune <linked>
assert_allow "cd \"$MAIN_N\" && git worktree remove \"$WT_LINKED_N\""              "$MAIN_N" "W1: cd main && git worktree remove linked"
assert_allow "cd \"$MAIN_N\" && git -C \"$MAIN_N\" worktree remove \"$WT_LINKED_N\"" "$MAIN_N" "W2: cd main && git -C main worktree remove linked"
assert_allow "cd \"$MAIN_N\" && git worktree prune"                                 "$MAIN_N" "W3: cd main && git worktree prune"

# Block: safety constraints
assert_block "cd \"$OTHER_N\" && git worktree remove \"$WT_LINKED_N\""              "$MAIN_N" "W4: cd other dir → blocked"
assert_block "cd \"$MAIN_N\" && git worktree remove --force \"$WT_LINKED_N\""      "$MAIN_N" "W5: --force → blocked"
assert_block "cd \"$MAIN_N\" && git worktree remove -f \"$WT_LINKED_N\""           "$MAIN_N" "W6: -f → blocked"
assert_block "cd \"$MAIN_N\" && git worktree remove \"$WT_LINKED_N\" && echo done" "$MAIN_N" "W7: trailing && → blocked"
assert_block "cd \"$MAIN_N\" && git worktree remove \"$WT_LINKED_N\" | cat"        "$MAIN_N" "W8: pipe → blocked"
assert_block "cd \"$MAIN_N\" ; git worktree remove \"$WT_LINKED_N\""               "$MAIN_N" "W9: semicolon → blocked"
assert_block "cd \"$MAIN_N\" && rm -rf \"$WT_LINKED_N\""                           "$MAIN_N" "W10: non-git RHS → blocked"
assert_block "cd \"$MAIN_N\" && git worktree add \"$TMPBASE/new\""                 "$MAIN_N" "W11: worktree add → blocked"
assert_block "cd \"$MAIN_N\" && git -C \"$OTHER_N\" worktree remove \"$WT_LINKED_N\"" "$MAIN_N" "W12: -C other repo → blocked"
assert_block "cd \"path&&weird\" && git worktree remove \"$WT_LINKED_N\""          "$MAIN_N" "W13: quoted && in cd path → blocked (path≠main)"

echo ""; echo "Results: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
