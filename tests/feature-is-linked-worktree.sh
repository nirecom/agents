#!/bin/bash
# Tests: bin/is-linked-worktree.sh, bin/is-linked-worktree.sh.
# Tags: is-linked-worktree
# Tests for issue #602 PR1 — bin/is-linked-worktree.sh.
#
# Parses `git worktree list --porcelain` and prints one of:
#   main | linked | unknown
# Always exits 0.
#
#   TC1: main worktree → "main"
#   TC2: linked worktree → "linked"
#   TC3: non-git directory → "unknown"
#
# Precondition gate: skips cleanly when bin/is-linked-worktree.sh is absent.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_DIR/bin/is-linked-worktree.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        perl -e 'alarm 30; exec @ARGV' -- "$@"
    fi
}

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL: precondition missing — bin/is-linked-worktree.sh"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

EMPTY_HOOKS_DIR="$TMPDIR_BASE/no-hooks"
mkdir -p "$EMPTY_HOOKS_DIR"

make_repo() {
    local repo
    repo=$(mktemp -d)
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath "$EMPTY_HOOKS_DIR"
    git -C "$repo" config core.autocrlf false
    git -C "$repo" checkout -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "${repo//\\//}"
}

# ---------------------------------------------------------------------------
# TC1: main worktree
# ---------------------------------------------------------------------------
REPO1=$(make_repo)
EXIT=0
OUT=$(cd "$REPO1" && run_with_timeout bash "$SCRIPT" 2>&1) || EXIT=$?

if [ "$EXIT" -eq 0 ] && echo "$OUT" | grep -qw "main"; then
    pass "TC1: main worktree → 'main' (exit 0)"
else
    fail "TC1: exit=$EXIT output=$OUT"
fi

# ---------------------------------------------------------------------------
# TC2: linked worktree
# ---------------------------------------------------------------------------
REPO2=$(make_repo)
LINKED_DIR="$TMPDIR_BASE/linked-wt"
git -C "$REPO2" worktree add -q -b feature-linked "$LINKED_DIR" 2>/dev/null

EXIT=0
OUT=$(cd "$LINKED_DIR" && run_with_timeout bash "$SCRIPT" 2>&1) || EXIT=$?

if [ "$EXIT" -eq 0 ] && echo "$OUT" | grep -qw "linked"; then
    pass "TC2: linked worktree → 'linked' (exit 0)"
else
    fail "TC2: exit=$EXIT output=$OUT"
fi

# ---------------------------------------------------------------------------
# TC3: non-git directory
# ---------------------------------------------------------------------------
NONGIT="$TMPDIR_BASE/non-git"
mkdir -p "$NONGIT"

EXIT=0
OUT=$(cd "$NONGIT" && run_with_timeout bash "$SCRIPT" 2>&1) || EXIT=$?

if [ "$EXIT" -eq 0 ] && echo "$OUT" | grep -qw "unknown"; then
    pass "TC3: non-git directory → 'unknown' (exit 0)"
else
    fail "TC3: exit=$EXIT output=$OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
