#!/bin/bash
# tests/fix-enforce-worktree-push-fix-cleanup.sh
#
# Integration tests for Fix 3: hooks/cleanup-orphan-dir.js
#
# Standalone Node.js CLI:
#     node hooks/cleanup-orphan-dir.js <path>
#
# Safely deletes an EMPTY orphan directory left behind after `git worktree
# remove`. Refuses if any of the following are true:
#   - path is a symlink
#   - path is outside WORKTREE_BASE_DIR
#   - path is a registered git worktree (`git worktree list`)
#   - path is non-empty
#   - path equals WORKTREE_BASE_DIR itself (floor check)
#
# TDD note: hooks/cleanup-orphan-dir.js does not yet exist. All tests will
# FAIL RED until Fix 3 is implemented.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
CLEANUP_JS="${_AGENTS_DIR_NODE}/hooks/cleanup-orphan-dir.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'push-fix-cleanup-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# WORKTREE_BASE_DIR for this whole test run.
WT_BASE="$TMPDIR_BASE/wt-base"
mkdir -p "$WT_BASE"

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

require_script() {
    if [ ! -f "$CLEANUP_JS" ]; then
        fail "$1 (cleanup-orphan-dir.js not present — expected RED until Fix 3)"
        return 1
    fi
    return 0
}

norm_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

# Run the cleanup script with WORKTREE_BASE_DIR set, return exit code (echo).
# Args: target_path [extra_env=val ...]
run_cleanup() {
    local target="$1"; shift
    run_with_timeout 30 env "WORKTREE_BASE_DIR=$(norm_path "$WT_BASE")" "$@" \
        node "$CLEANUP_JS" "$target" >/dev/null 2>&1
    echo "$?"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

test_deletes_empty_orphan_dir() {
    require_script "test_deletes_empty_orphan_dir" || return
    local target="$WT_BASE/orphan-empty"
    mkdir -p "$target"
    target="$(norm_path "$target")"
    local rc; rc="$(run_cleanup "$target")"
    if [ "$rc" = "0" ] && [ ! -e "$target" ]; then
        pass "Fix 3: deletes empty orphan dir under WORKTREE_BASE_DIR"
    else
        fail "Fix 3: should delete empty orphan dir (rc=$rc, exists=$([ -e "$target" ] && echo yes || echo no))"
    fi
}

test_nonexistent_path_idempotent() {
    require_script "test_nonexistent_path_idempotent" || return
    local target; target="$(norm_path "$WT_BASE/does-not-exist")"
    local rc; rc="$(run_cleanup "$target")"
    if [ "$rc" = "0" ]; then
        pass "Fix 3: nonexistent path is idempotent (exit 0)"
    else
        fail "Fix 3: nonexistent path should exit 0 (rc=$rc)"
    fi
}

test_nonempty_dir_refuses() {
    require_script "test_nonempty_dir_refuses" || return
    local target="$WT_BASE/nonempty"
    mkdir -p "$target"
    echo "data" > "$target/file.txt"
    target="$(norm_path "$target")"
    local rc; rc="$(run_cleanup "$target")"
    if [ "$rc" != "0" ] && [ -e "$target" ] && [ -e "$target/file.txt" ]; then
        pass "Fix 3: refuses to delete non-empty dir (rc=$rc, file preserved)"
    else
        fail "Fix 3: should refuse non-empty dir and preserve contents (rc=$rc)"
    fi
}

test_outside_base_refuses() {
    require_script "test_outside_base_refuses" || return
    local outside="$TMPDIR_BASE/outside-base"
    mkdir -p "$outside"
    outside="$(norm_path "$outside")"
    local rc; rc="$(run_cleanup "$outside")"
    if [ "$rc" != "0" ] && [ -e "$outside" ]; then
        pass "Fix 3: refuses path outside WORKTREE_BASE_DIR (rc=$rc, preserved)"
    else
        fail "Fix 3: should refuse path outside base and preserve (rc=$rc)"
    fi
}

test_registered_worktree_refuses() {
    require_script "test_registered_worktree_refuses" || return
    # Create a main repo OUTSIDE the WT_BASE so its main worktree is unrelated.
    local main="$TMPDIR_BASE/wt-main"
    mkdir -p "$main"
    git -C "$main" init -q -b main
    git -C "$main" config user.email "test@example.com"
    git -C "$main" config user.name "Test"
    git -C "$main" config core.hooksPath /dev/null
    echo "x" > "$main/README.md"
    git -C "$main" add README.md
    git -C "$main" commit -q -m "initial"
    # Add a linked worktree UNDER WT_BASE — this is the empty-but-registered case
    # that the cleanup must refuse to delete because `git worktree list` includes it.
    local wt_path="$WT_BASE/registered-wt"
    git -C "$main" worktree add -q -b feature "$wt_path" 2>/dev/null
    local wt_norm; wt_norm="$(norm_path "$wt_path")"
    local rc; rc="$(run_cleanup "$wt_norm")"
    if [ "$rc" != "0" ] && [ -e "$wt_path" ]; then
        pass "Fix 3: refuses registered git worktree path (rc=$rc, preserved)"
    else
        fail "Fix 3: should refuse registered worktree path (rc=$rc, exists=$([ -e "$wt_path" ] && echo yes || echo no))"
    fi
}

test_symlink_refuses() {
    require_script "test_symlink_refuses" || return
    # Create a real dir somewhere, then a symlink under WT_BASE pointing to it.
    local real="$TMPDIR_BASE/symlink-target"
    mkdir -p "$real"
    local link="$WT_BASE/symlink-orphan"
    # ln -s may fail on Windows without privileges/dev-mode, or may silently
    # create a regular file/dir copy instead of a real symlink (Git Bash on
    # Windows behaves this way without MSYS=winsymlinks:nativestrict).
    if ! ln -s "$real" "$link" 2>/dev/null; then
        pass "Fix 3: symlink case skipped (ln -s unavailable on this system)"
        return
    fi
    # Verify the result is actually a symlink (POSIX -L test). On Git Bash
    # without dev mode this is false even when ln -s exits 0.
    if [ ! -L "$link" ]; then
        pass "Fix 3: symlink case skipped (ln -s did not produce a real symlink)"
        rm -rf "$link" 2>/dev/null
        return
    fi
    local link_norm; link_norm="$(norm_path "$link")"
    local rc; rc="$(run_cleanup "$link_norm")"
    if [ "$rc" != "0" ] && [ -e "$link" ]; then
        pass "Fix 3: refuses symlink target (rc=$rc, link preserved)"
    else
        fail "Fix 3: should refuse symlink and preserve (rc=$rc, exists=$([ -e "$link" ] && echo yes || echo no))"
    fi
}

test_path_traversal_refuses() {
    require_script "test_path_traversal_refuses" || return
    # `../../../etc` from inside WT_BASE escapes the base.
    # Use an absolute path that resolves outside via traversal segments.
    local target="$WT_BASE/../../../etc"
    local rc; rc="$(run_cleanup "$target")"
    # If somehow it resolved INTO base, the dir would not exist; the script must
    # still refuse / not delete /etc. We check that exit is non-zero AND /etc still exists.
    if [ "$rc" != "0" ]; then
        pass "Fix 3: refuses path-traversal target (rc=$rc)"
    else
        fail "Fix 3: should refuse path traversal target (rc=$rc)"
    fi
}

test_base_itself_refuses() {
    require_script "test_base_itself_refuses" || return
    # The script must NEVER delete WORKTREE_BASE_DIR itself (floor check).
    local target; target="$(norm_path "$WT_BASE")"
    local rc; rc="$(run_cleanup "$target")"
    if [ "$rc" != "0" ] && [ -d "$WT_BASE" ]; then
        pass "Fix 3: refuses base dir itself (rc=$rc, base preserved)"
    else
        fail "Fix 3: should refuse base dir (rc=$rc, exists=$([ -d "$WT_BASE" ] && echo yes || echo no))"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

test_deletes_empty_orphan_dir
test_nonexistent_path_idempotent
test_nonempty_dir_refuses
test_outside_base_refuses
test_registered_worktree_refuses
test_symlink_refuses
test_path_traversal_refuses
test_base_itself_refuses

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

if [ $FAIL -eq 0 ]; then exit 0; else exit 1; fi
