#!/bin/bash
# tests/fix-296-hook-cwd-drift-cleanup.sh
# Tests: hooks/cleanup-orphan-dir.js
# Tags: worktree, hook, bin, git, tests
#
# Tests for hooks/cleanup-orphan-dir.js with the new `--force-if-not-registered`
# flag (issue #296). The flag widens the cleanup behaviour for orphan-dir
# scenarios where the directory is non-empty but does NOT contain any .git
# entry anywhere in its subtree, is not a registered worktree, and lies under
# WORKTREE_BASE_DIR.
#
# Pre-implementation, the hook rejects any flag (`flags not accepted: --...`),
# so F1/F2 (which require the flag to succeed) fail. F3/F4/F5/F5b/F5c/F6/F7/F8/F9
# all assert refusal patterns and may pass or fail depending on which message
# the current implementation emits.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
CLEANUP="${_AGENTS_DIR_NODE}/hooks/cleanup-orphan-dir.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$AGENTS_DIR/hooks/cleanup-orphan-dir.js" ]; then
    echo "FAIL: hooks/cleanup-orphan-dir.js not found"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# Detect platform
is_windows() {
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) [ "${OS:-}" = "Windows_NT" ] && return 0 || return 1 ;;
    esac
}

# Create a BASE directory at <tmp>/a/b — segments >= 3 from root, so the
# script's floor check passes.
setup_base() {
    TMPDIR_C="$(mktemp -d 2>/dev/null || mktemp -d -t cleanup_test)"
    BASE="$TMPDIR_C/a/b"
    mkdir -p "$BASE"
    if command -v cygpath >/dev/null 2>&1; then
        BASE_W="$(cygpath -w "$BASE")"
    else
        BASE_W="$BASE"
    fi
}

cleanup_base() {
    # Best-effort cleanup. Remove any temp worktree registered under our base.
    if [ -n "${TEMP_WT_PATH:-}" ] && [ -d "$TEMP_WT_PATH" ]; then
        git -C "$AGENTS_DIR" worktree remove -f "$TEMP_WT_PATH" >/dev/null 2>&1 || true
        # If the branch was created, prune it.
        if [ -n "${TEMP_WT_BRANCH:-}" ]; then
            git -C "$AGENTS_DIR" branch -D "$TEMP_WT_BRANCH" >/dev/null 2>&1 || true
        fi
        git -C "$AGENTS_DIR" worktree prune >/dev/null 2>&1 || true
    fi
    [ -n "${TMPDIR_C:-}" ] && [ -d "$TMPDIR_C" ] && rm -rf "$TMPDIR_C" 2>/dev/null || true
}

setup_base
trap cleanup_base EXIT INT TERM HUP

# Run the hook. <flag-or-empty> is "" for no flag, or "--force-if-not-registered" etc.
# <target> is the path argument (empty string omits it).
# Captures stdout+stderr + exit code into globals OUT / RC.
run_cleanup() {
    local flag="$1"
    local target="$2"
    if [ -n "$flag" ] && [ -n "$target" ]; then
        OUT=$(WORKTREE_BASE_DIR="$BASE_W" run_with_timeout 30 node "$CLEANUP" "$flag" "$target" 2>&1)
    elif [ -n "$flag" ] && [ -z "$target" ]; then
        OUT=$(WORKTREE_BASE_DIR="$BASE_W" run_with_timeout 30 node "$CLEANUP" "$flag" 2>&1)
    elif [ -z "$flag" ] && [ -n "$target" ]; then
        OUT=$(WORKTREE_BASE_DIR="$BASE_W" run_with_timeout 30 node "$CLEANUP" "$target" 2>&1)
    else
        OUT=$(WORKTREE_BASE_DIR="$BASE_W" run_with_timeout 30 node "$CLEANUP" 2>&1)
    fi
    RC=$?
}

# ─────────────────────────────────────────────────────────────────────────────
# F1: --force-if-not-registered + EMPTY unregistered path → delete, exit 0
# ─────────────────────────────────────────────────────────────────────────────
test_F1() {
    local target="$BASE/f1-empty"
    mkdir -p "$target"
    run_cleanup "--force-if-not-registered" "$target"
    if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '"deleted":true'; then
        pass "F1: empty unregistered dir → deleted (exit 0)"
    else
        fail "F1: rc=$RC out=$OUT"
    fi
    rm -rf "$target" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# F2: --force-if-not-registered + NONEMPTY unregistered path → recursive delete
# ─────────────────────────────────────────────────────────────────────────────
test_F2() {
    local target="$BASE/f2-nonempty"
    mkdir -p "$target/bar"
    echo content > "$target/foo.txt"
    echo content > "$target/bar/baz.txt"
    run_cleanup "--force-if-not-registered" "$target"
    if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '"recursive":true'; then
        pass "F2: nonempty unregistered → recursive delete (exit 0, recursive:true)"
    else
        fail "F2: rc=$RC out=$OUT"
    fi
    rm -rf "$target" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# F3: --force-if-not-registered + REGISTERED worktree path → refuse
# Setup: add a temporary linked worktree of the agents repo under BASE.
# ─────────────────────────────────────────────────────────────────────────────
test_F3() {
    local target="$BASE/f3-registered"
    TEMP_WT_PATH="$target"
    TEMP_WT_BRANCH="test/296-cleanup-f3-$$"
    # Use the agents repo (parent of the cleanup script) to register the wt.
    if ! git -C "$AGENTS_DIR" worktree add -q "$target" -b "$TEMP_WT_BRANCH" >/dev/null 2>&1; then
        # Branch may already exist from a prior failed run; retry without -b.
        git -C "$AGENTS_DIR" branch -D "$TEMP_WT_BRANCH" >/dev/null 2>&1 || true
        if ! git -C "$AGENTS_DIR" worktree add -q "$target" -b "$TEMP_WT_BRANCH" >/dev/null 2>&1; then
            fail "F3: could not create test worktree at $target"
            return
        fi
    fi
    run_cleanup "--force-if-not-registered" "$target"
    if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "registered.*worktree"; then
        pass "F3: registered worktree → refused"
    else
        fail "F3: rc=$RC out=$OUT"
    fi
    # Clean up the temp worktree.
    git -C "$AGENTS_DIR" worktree remove -f "$target" >/dev/null 2>&1 || true
    git -C "$AGENTS_DIR" branch -D "$TEMP_WT_BRANCH" >/dev/null 2>&1 || true
    git -C "$AGENTS_DIR" worktree prune >/dev/null 2>&1 || true
    TEMP_WT_PATH=""
    TEMP_WT_BRANCH=""
}

# ─────────────────────────────────────────────────────────────────────────────
# F4: --force-if-not-registered + path OUTSIDE BASE → refuse
# ─────────────────────────────────────────────────────────────────────────────
test_F4() {
    local outside="$TMPDIR_C/outside-of-base"
    mkdir -p "$outside"
    run_cleanup "--force-if-not-registered" "$outside"
    if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "outside.*WORKTREE_BASE_DIR"; then
        pass "F4: outside BASE → refused"
    else
        fail "F4: rc=$RC out=$OUT"
    fi
    rm -rf "$outside" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# F5: --force-if-not-registered + immediate .git child → refuse
# ─────────────────────────────────────────────────────────────────────────────
test_F5() {
    local target="$BASE/f5-dotgit-immediate"
    mkdir -p "$target/.git"
    run_cleanup "--force-if-not-registered" "$target"
    if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "\.git"; then
        pass "F5: immediate .git child → refused"
    else
        fail "F5: rc=$RC out=$OUT"
    fi
    rm -rf "$target" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# F5b: --force-if-not-registered + nested <target>/sub/.git → refuse (recursive)
# ─────────────────────────────────────────────────────────────────────────────
test_F5b() {
    local target="$BASE/f5b-dotgit-nested"
    mkdir -p "$target/subdir/.git"
    run_cleanup "--force-if-not-registered" "$target"
    if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "\.git"; then
        pass "F5b: nested .git in subdir → refused"
    else
        fail "F5b: rc=$RC out=$OUT"
    fi
    rm -rf "$target" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# F5c: --force-if-not-registered + .git as a regular FILE (gitlink) → refuse
# ─────────────────────────────────────────────────────────────────────────────
test_F5c() {
    local target="$BASE/f5c-dotgit-file"
    mkdir -p "$target"
    echo "gitdir: /tmp/whatever" > "$target/.git"
    run_cleanup "--force-if-not-registered" "$target"
    if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "\.git"; then
        pass "F5c: .git as gitlink file → refused"
    else
        fail "F5c: rc=$RC out=$OUT"
    fi
    rm -rf "$target" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# F6: --force-if-not-registered + SYMLINK → refuse (POSIX-only; SKIP on Windows)
# ─────────────────────────────────────────────────────────────────────────────
test_F6() {
    if is_windows; then
        echo "SKIP: F6 — POSIX-only (symlink semantics differ on Windows)"
        PASS=$((PASS + 1))
        return
    fi
    local real="$BASE/f6-real-target"
    local link="$BASE/f6-symlink"
    mkdir -p "$real"
    ln -s "$real" "$link"
    run_cleanup "--force-if-not-registered" "$link"
    if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "symlink"; then
        pass "F6: symlink → refused"
    else
        fail "F6: rc=$RC out=$OUT"
    fi
    rm -f "$link" 2>/dev/null || true
    rm -rf "$real" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# F7: NO flag + nonempty path → refuse with "not empty" (existing behaviour)
# ─────────────────────────────────────────────────────────────────────────────
test_F7() {
    local target="$BASE/f7-noflag-nonempty"
    mkdir -p "$target"
    echo x > "$target/file.txt"
    run_cleanup "" "$target"
    if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "not empty"; then
        pass "F7: no flag + nonempty → refused with 'not empty'"
    else
        fail "F7: rc=$RC out=$OUT"
    fi
    rm -rf "$target" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# F8: --unknown-flag <path> → refuse ("flags not accepted")
# ─────────────────────────────────────────────────────────────────────────────
test_F8() {
    local target="$BASE/f8-target"
    mkdir -p "$target"
    run_cleanup "--unknown-flag" "$target"
    if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "flags not accepted"; then
        pass "F8: unknown flag → refused with 'flags not accepted'"
    else
        fail "F8: rc=$RC out=$OUT"
    fi
    rm -rf "$target" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# F9: --force-if-not-registered with NO positional path → refuse
# ─────────────────────────────────────────────────────────────────────────────
test_F9() {
    run_cleanup "--force-if-not-registered" ""
    if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "expected 1 positional path arg"; then
        pass "F9: missing path → refused with arg-count message"
    else
        fail "F9: rc=$RC out=$OUT"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────
test_F1
test_F2
test_F3
test_F4
test_F5
test_F5b
test_F5c
test_F6
test_F7
test_F8
test_F9

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
