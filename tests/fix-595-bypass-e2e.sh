#!/bin/bash
# tests/fix-595-bypass-e2e.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree.js.
# Tags: worktree, enforce, hook, history, docs
#
# E2E integration tests for bypass predicates still active in
# hooks/enforce-worktree.js after the #687 positive-allow redesign.
#
# IC-WRITE/IC-PUSH/CMP-WRITE/CMP-PUSH series were removed: the four bypass
# predicates they tested (isAllowedHistoryWrite/PushVia{IssueClose,ComposeDocAppend}Skill)
# were intentionally deleted in #687. Those tests are archived in
# tests/_archive/feature-325-history-write-bypass.sh.
#
# Coverage matrix (2 active MUST class members):
#   1. isAllowedWorktreeCommand (WT-REMOVE)
#   2. isAllowedBranchDeleteWhenNotCheckedOut (BD)
#
# Drive surface:
#   echo '{"tool_name":"Bash","tool_input":{"command":"<cmd>"}}' | \
#     (cd <main-worktree> && node hooks/enforce-worktree.js)
#
#   Hook exit code 0 with no "decision":"block" in output → ALLOW.
#   Hook exit code 0 with "decision":"block" in output    → BLOCK.
#   Any other exit code                                   → CRASH (test failure).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

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

# Tempdir base, cleaned up at exit. Use node so we get a POSIX-style path on Windows.
TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'fix595-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Existence gate.
if [ ! -f "$GUARD_JS" ]; then
    echo "FAIL: precondition missing — hooks/enforce-worktree.js"
    echo ""
    echo "Total: PASS=0 FAIL=1"
    exit 1
fi

# JSON-quote a string via node.
json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

# Build a PreToolUse Bash payload.
build_bash_payload() {
    local cmd="$1"
    local q; q="$(json_quote "$cmd")"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$q"
}

# Run the guard with cwd set to <main-worktree>.
# Sets GUARD_OUT (stdout+stderr) and GUARD_RC (exit code).
# Returns:
#   0 = ALLOW   (rc=0, no block decision in stdout)
#   1 = BLOCK   (rc=0, "decision":"block" in stdout)
#   2 = CRASH   (rc != 0)
GUARD_OUT=""
GUARD_RC=0
run_guard() {
    local payload="$1"; shift
    local main_wt="$1"; shift
    # Remaining args are extra env vars passed to the hook process (KEY=VAL form).
    GUARD_RC=0
    GUARD_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        -C "$main_wt" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_EXTRA_REPOS=$main_wt" \
        "$@" \
        node "$GUARD_JS" 2>&1)" || GUARD_RC=$?
    if [ "$GUARD_RC" -ne 0 ]; then
        return 2
    fi
    if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 0
}

# `env -C` is a GNU coreutils extension (>=8.28). Fallback: subshell `cd` + env.
# Detect once and override run_guard if needed.
if ! env -C "$TMPDIR_BASE" true 2>/dev/null; then
    run_guard() {
        local payload="$1"; shift
        local main_wt="$1"; shift
        GUARD_RC=0
        GUARD_OUT="$(cd "$main_wt" && printf '%s' "$payload" | run_with_timeout 30 \
            env -u CLAUDE_ENV_FILE \
            "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
            "ENFORCE_WORKTREE=on" \
            "ENFORCE_WORKTREE_EXTRA_REPOS=$main_wt" \
            "$@" \
            node "$GUARD_JS" 2>&1)" || GUARD_RC=$?
        if [ "$GUARD_RC" -ne 0 ]; then
            return 2
        fi
        if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
            return 1
        fi
        return 0
    }
fi

assert_allow() {
    local label="$1" rc="$2"
    case "$rc" in
        0) pass "$label" ;;
        1) fail "$label (BLOCK — expected ALLOW; out: $GUARD_OUT)" ;;
        2) fail "$label (CRASH rc=$GUARD_RC; out: $GUARD_OUT)" ;;
        *) fail "$label (unexpected rc=$rc; out: $GUARD_OUT)" ;;
    esac
}

assert_block() {
    local label="$1" rc="$2"
    case "$rc" in
        0) fail "$label (ALLOW — expected BLOCK; out: $GUARD_OUT)" ;;
        1) pass "$label" ;;
        2) fail "$label (CRASH rc=$GUARD_RC; out: $GUARD_OUT)" ;;
        *) fail "$label (unexpected rc=$rc; out: $GUARD_OUT)" ;;
    esac
}

# ----------------------------------------------------------------------------
# Fixture builders
# ----------------------------------------------------------------------------

# Initialize a minimal main worktree (no linked worktree, no origin).
# Args: <name>
# Echoes the absolute (cygpath-normalized) path of the main worktree.
setup_main_worktree() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    mkdir -p "$repo/docs/history"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q --no-verify -m "initial"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

# Add a linked worktree under <main-worktree>/.wt/<name> on a new branch.
# Echoes the absolute path of the linked worktree.
add_linked_worktree() {
    local main_wt="$1" name="$2" branch="$3"
    local wt_path="$main_wt/.wt/$name"
    git -C "$main_wt" worktree add -q -b "$branch" "$wt_path" >/dev/null
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$wt_path"
    else
        echo "$wt_path"
    fi
}

# ============================================================================
# WT-REMOVE series — isAllowedWorktreeCommand (worktree remove)
# ============================================================================

test_E_WT_REMOVE_1_with_prefix() {
    local repo; repo="$(setup_main_worktree "wt-remove-1")"
    local linked; linked="$(add_linked_worktree "$repo" "lw1" "feature/lw1")"
    local cmd="WORKTREE_END_SKILL=1 git worktree remove $linked"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_allow "E-WT-REMOVE-1: WORKTREE_END_SKILL=1 git worktree remove <linked> → ALLOW (prefixed form)" "$rc"
}

test_E_WT_REMOVE_2_unconditional() {
    local repo; repo="$(setup_main_worktree "wt-remove-2")"
    local linked; linked="$(add_linked_worktree "$repo" "lw2" "feature/lw2")"
    local cmd="git worktree remove $linked"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_allow "E-WT-REMOVE-2: git worktree remove <linked> → ALLOW (unconditional)" "$rc"
}

test_E_WT_REMOVE_3_shell_chaining_blocked() {
    local repo; repo="$(setup_main_worktree "wt-remove-3")"
    local linked; linked="$(add_linked_worktree "$repo" "lw3" "feature/lw3")"
    local cmd="WORKTREE_END_SKILL=1 git worktree remove $linked && echo done"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-WT-REMOVE-3: git worktree remove … && echo done → BLOCK (shell chaining)" "$rc"
}

# ============================================================================
# BRANCH-DELETE series — isAllowedBranchDeleteWhenNotCheckedOut
# ============================================================================

# Setup helper: build a main worktree with an unused branch (created and switched
# back to main so the branch is not checked out anywhere).
setup_main_with_unused_branch() {
    local name="$1" branch="$2"
    local repo; repo="$(setup_main_worktree "$name")"
    # Create the branch via `branch` (not `switch -c`) so HEAD stays on main.
    # Resolve back to filesystem path for `git -C` use:
    local raw="$TMPDIR_BASE/$name"
    git -C "$raw" branch "$branch" >/dev/null
    echo "$repo"
}

test_E_BD_1_with_prefix_allow() {
    local repo; repo="$(setup_main_with_unused_branch "bd-1" "fix/unused")"
    # `git -C <repo>` with the prefixed form. Even from cwd=repo, the explicit -C
    # exercises the dispatch path. Quoted path so spaces in TMPDIR_BASE work.
    local cmd="WORKTREE_END_SKILL=1 git -C \"$repo\" branch -D fix/unused"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_allow "E-BD-1: WORKTREE_END_SKILL=1 git -C <repo> branch -D fix/unused → ALLOW" "$rc"
}

test_E_BD_2_no_prefix_blocked() {
    local repo; repo="$(setup_main_with_unused_branch "bd-2" "fix/unused")"
    # Without the prefix, force-delete (-D) lacks authorization → BLOCK.
    local cmd="git -C \"$repo\" branch -D fix/unused"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-BD-2: git -C <repo> branch -D fix/unused WITHOUT prefix → BLOCK (force-delete needs WORKTREE_END_SKILL=1)" "$rc"
}

test_E_BD_3_checked_out_branch_blocked() {
    local repo; repo="$(setup_main_worktree "bd-3")"
    # Attempt to delete `main`, which IS checked out (in the main worktree itself).
    local cmd="WORKTREE_END_SKILL=1 git -C \"$repo\" branch -D main"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-BD-3: branch -D main (checked-out) even with prefix → BLOCK" "$rc"
}

# ============================================================================
# Run all
# ============================================================================

run_all() {
    # WT-REMOVE
    test_E_WT_REMOVE_1_with_prefix
    test_E_WT_REMOVE_2_unconditional
    test_E_WT_REMOVE_3_shell_chaining_blocked
    # BRANCH-DELETE
    test_E_BD_1_with_prefix_allow
    test_E_BD_2_no_prefix_blocked
    test_E_BD_3_checked_out_branch_blocked
}

# 180s outer timeout so a stuck `git push` cannot wedge the suite.
if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_FIX595_TEST_INNER:-}" ]; then
        _FIX595_TEST_INNER=1 timeout 180 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
