#!/bin/bash
# tests/fix-595-bypass-e2e.sh
#
# E2E integration tests for the ENV=1-prefixed bypass predicates in
# hooks/enforce-worktree.js.
#
# Coverage matrix (6 MUST class members):
#   1. isAllowedHistoryWriteViaIssueCloseSkill (IC-WRITE)
#   2. isAllowedHistoryPushViaIssueCloseSkill (IC-PUSH)
#   3. isAllowedHistoryWriteViaComposeDocAppendSkill (CMP-WRITE)
#   4. isAllowedHistoryPushViaComposeDocAppendSkill (CMP-PUSH)
#   5. isAllowedWorktreeCommand (WT-REMOVE)
#   6. isAllowedBranchDeleteWhenNotCheckedOut (BD)
#
# Drive surface:
#   echo '{"tool_name":"Bash","tool_input":{"command":"<cmd>"}}' | \
#     (cd <main-worktree> && node hooks/enforce-worktree.js)
#
#   Hook exit code 0 with no "decision":"block" in output → ALLOW.
#   Hook exit code 0 with "decision":"block" in output    → BLOCK.
#   Any other exit code                                   → CRASH (test failure).
#
# Expected RED tests (TDD):
#   E-IC-WRITE-0, E-CMP-WRITE-0, E-CMP-WRITE-0b — git-add bypass requires
#   bash-write-patterns.js to classify `git add docs/history.md docs/history/`
#   as write (otherwise the hook short-circuits at classify(cmd)!=="write" → allow,
#   which actually produces ALLOW for the wrong reason). These tests are
#   directional and will pass once the source change lands.

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

# Directly query an exported bypass predicate from the hook module.
# Args: <fn-name> <cmd>  →  echoes "allow" | "reject" | "missing"
# Used by the TDD git-add tests to distinguish "passes via classify short-circuit"
# (current state) from "passes via the bypass predicate" (target state after
# bash-write-patterns.js classifies `git add docs/history.md docs/history/` as
# write). Without this white-box check, the E-*-WRITE-0/0b tests would silently
# stay green in both states and provide no TDD signal.
check_predicate() {
    local fn="$1" cmd="$2"
    run_with_timeout 15 node -e "
        const m = require('$GUARD_JS');
        const fn = m[process.argv[1]];
        if (typeof fn !== 'function') { console.log('missing'); process.exit(0); }
        console.log(fn(process.argv[2]) ? 'allow' : 'reject');
    " -- "$fn" "$cmd" 2>/dev/null
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

# Initialize a main worktree with a bare-origin remote and a single commit on the
# default branch.
#
# Args: <name> <subject> <files-csv>
#   - <files-csv>: comma-separated paths (relative to repo) the commit touches.
#                  Each path is created/appended with "x".
# Echoes the absolute main-worktree path.
setup_main_worktree_with_origin() {
    local name="$1" subject="$2" files_csv="$3"
    local repo upstream
    repo="$TMPDIR_BASE/$name"
    upstream="$TMPDIR_BASE/$name.git"
    git init --bare --initial-branch=main "$upstream" >/dev/null
    git init --initial-branch=main "$repo" >/dev/null
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" remote add origin "$upstream"
    git -C "$repo" commit --allow-empty --no-verify -q -m "init"
    git -C "$repo" push -q -u origin main >/dev/null 2>&1
    git -C "$repo" remote set-head origin main >/dev/null 2>&1
    mkdir -p "$repo/docs/history"
    IFS=',' read -ra FILES <<< "$files_csv"
    for f in "${FILES[@]}"; do
        mkdir -p "$repo/$(dirname "$f")"
        echo "x" >> "$repo/$f"
    done
    git -C "$repo" add -A
    git -C "$repo" commit --no-verify -q -m "$subject"
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
# IC-WRITE series — isAllowedHistoryWriteViaIssueCloseSkill
# ============================================================================

test_E_IC_WRITE_0_git_add() {
    local repo; repo="$(setup_main_worktree "ic-write-0")"
    local cmd='ISSUE_CLOSE_SKILL=1 git add docs/history.md docs/history/'
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_allow "E-IC-WRITE-0 (e2e): ISSUE_CLOSE_SKILL=1 git add docs/history.md docs/history/ → ALLOW" "$rc"
    # White-box: the predicate itself must accept this shape — distinguishes
    # "passes via classify() short-circuit" (current state) from "passes via
    # the bypass predicate" (target state once git-add is classified as write).
    local got; got="$(check_predicate isAllowedHistoryWriteViaIssueCloseSkill "$cmd")"
    case "$got" in
        allow)   pass "E-IC-WRITE-0 (predicate): isAllowedHistoryWriteViaIssueCloseSkill accepts git-add shape" ;;
        reject)  fail "E-IC-WRITE-0 (predicate): bypass predicate rejected git-add shape (RED: needs git-add branch in isAllowedHistoryWriteViaIssueCloseSkill)" ;;
        missing) fail "E-IC-WRITE-0 (predicate): isAllowedHistoryWriteViaIssueCloseSkill not exported" ;;
        *)       fail "E-IC-WRITE-0 (predicate): unexpected output '$got'" ;;
    esac
}

test_E_IC_WRITE_1_git_commit() {
    local repo; repo="$(setup_main_worktree "ic-write-1")"
    local cmd="ISSUE_CLOSE_SKILL=1 git commit -m 'docs(history): record issue #595'"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_allow "E-IC-WRITE-1: ISSUE_CLOSE_SKILL=1 git commit -m 'docs(history): …' → ALLOW" "$rc"
}

test_E_IC_WRITE_2_no_prefix_blocked() {
    local repo; repo="$(setup_main_worktree "ic-write-2")"
    local cmd="git commit -m 'docs(history): record issue #595'"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-IC-WRITE-2: git commit -m 'docs(history): …' WITHOUT prefix → BLOCK" "$rc"
}

test_E_IC_WRITE_3_wrong_subject_blocked() {
    local repo; repo="$(setup_main_worktree "ic-write-3")"
    local cmd="ISSUE_CLOSE_SKILL=1 git commit -m 'feat: wrong message'"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-IC-WRITE-3: ISSUE_CLOSE_SKILL=1 git commit with non-docs(history) subject → BLOCK" "$rc"
}

# ============================================================================
# IC-PUSH series — isAllowedHistoryPushViaIssueCloseSkill
# ============================================================================

test_E_IC_PUSH_1_allow() {
    local repo
    repo="$(setup_main_worktree_with_origin "ic-push-1" \
        "docs(history): record issue #595" "docs/history.md")"
    local cmd="ISSUE_CLOSE_SKILL=1 git push origin main"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_allow "E-IC-PUSH-1: ISSUE_CLOSE_SKILL=1 git push origin main (history file + matching subject) → ALLOW" "$rc"
}

test_E_IC_PUSH_2_no_prefix_blocked() {
    local repo
    repo="$(setup_main_worktree_with_origin "ic-push-2" \
        "docs(history): record issue #595" "docs/history.md")"
    local cmd="git push origin main"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-IC-PUSH-2: git push origin main WITHOUT prefix → BLOCK" "$rc"
}

test_E_IC_PUSH_3_wrong_files_blocked() {
    local repo
    repo="$(setup_main_worktree_with_origin "ic-push-3" \
        "docs(history): record issue #595" "src/foo.js")"
    local cmd="ISSUE_CLOSE_SKILL=1 git push origin main"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-IC-PUSH-3: ISSUE_CLOSE_SKILL=1 push with non-history file change → BLOCK" "$rc"
}

# ============================================================================
# CMP-WRITE series — isAllowedHistoryWriteViaComposeDocAppendSkill
# ============================================================================

test_E_CMP_WRITE_0_git_add_history() {
    local repo; repo="$(setup_main_worktree "cmp-write-0")"
    local cmd='COMPOSE_DOC_APPEND_SKILL=1 git add docs/history.md docs/history/'
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_allow "E-CMP-WRITE-0 (e2e): COMPOSE_DOC_APPEND_SKILL=1 git add docs/history.md docs/history/ → ALLOW" "$rc"
    local got; got="$(check_predicate isAllowedHistoryWriteViaComposeDocAppendSkill "$cmd")"
    case "$got" in
        allow)   pass "E-CMP-WRITE-0 (predicate): isAllowedHistoryWriteViaComposeDocAppendSkill accepts git-add history shape" ;;
        reject)  fail "E-CMP-WRITE-0 (predicate): bypass predicate rejected git-add history shape (RED)" ;;
        missing) fail "E-CMP-WRITE-0 (predicate): function not exported" ;;
        *)       fail "E-CMP-WRITE-0 (predicate): unexpected output '$got'" ;;
    esac
}

test_E_CMP_WRITE_0b_git_add_changelog() {
    local repo; repo="$(setup_main_worktree "cmp-write-0b")"
    local cmd='COMPOSE_DOC_APPEND_SKILL=1 git add CHANGELOG.md'
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_allow "E-CMP-WRITE-0b (e2e): COMPOSE_DOC_APPEND_SKILL=1 git add CHANGELOG.md → ALLOW" "$rc"
    local got; got="$(check_predicate isAllowedHistoryWriteViaComposeDocAppendSkill "$cmd")"
    case "$got" in
        allow)   pass "E-CMP-WRITE-0b (predicate): isAllowedHistoryWriteViaComposeDocAppendSkill accepts git-add CHANGELOG shape" ;;
        reject)  fail "E-CMP-WRITE-0b (predicate): bypass predicate rejected git-add CHANGELOG shape (RED)" ;;
        missing) fail "E-CMP-WRITE-0b (predicate): function not exported" ;;
        *)       fail "E-CMP-WRITE-0b (predicate): unexpected output '$got'" ;;
    esac
}

test_E_CMP_WRITE_1_commit_history() {
    local repo; repo="$(setup_main_worktree "cmp-write-1")"
    local cmd="COMPOSE_DOC_APPEND_SKILL=1 git commit -m 'docs(history): record PR #595'"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_allow "E-CMP-WRITE-1: COMPOSE_DOC_APPEND_SKILL=1 git commit -m 'docs(history): record PR #595' → ALLOW" "$rc"
}

test_E_CMP_WRITE_2_commit_changelog() {
    local repo; repo="$(setup_main_worktree "cmp-write-2")"
    local cmd="COMPOSE_DOC_APPEND_SKILL=1 git commit -m 'docs(changelog): record PR #595'"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_allow "E-CMP-WRITE-2: COMPOSE_DOC_APPEND_SKILL=1 git commit -m 'docs(changelog): record PR #595' → ALLOW" "$rc"
}

test_E_CMP_WRITE_3_no_prefix_blocked() {
    local repo; repo="$(setup_main_worktree "cmp-write-3")"
    local cmd="git commit -m 'docs(history): record PR #595'"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-CMP-WRITE-3: git commit -m 'docs(history): record PR #595' WITHOUT prefix → BLOCK" "$rc"
}

# ============================================================================
# CMP-PUSH series — isAllowedHistoryPushViaComposeDocAppendSkill
# ============================================================================

test_E_CMP_PUSH_1_allow() {
    local repo
    repo="$(setup_main_worktree_with_origin "cmp-push-1" \
        "docs(history): record PR #595" "docs/history.md")"
    local cmd="COMPOSE_DOC_APPEND_SKILL=1 git push origin main"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_allow "E-CMP-PUSH-1: COMPOSE_DOC_APPEND_SKILL=1 push (history file + docs(history): record PR #N) → ALLOW" "$rc"
}

test_E_CMP_PUSH_4_wrong_files_blocked() {
    local repo
    repo="$(setup_main_worktree_with_origin "cmp-push-4" \
        "docs(history): record PR #595" "src/foo.js")"
    local cmd="COMPOSE_DOC_APPEND_SKILL=1 git push origin main"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-CMP-PUSH-4: COMPOSE_DOC_APPEND_SKILL=1 push with non-history file change → BLOCK" "$rc"
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
    # IC-WRITE
    test_E_IC_WRITE_0_git_add
    test_E_IC_WRITE_1_git_commit
    test_E_IC_WRITE_2_no_prefix_blocked
    test_E_IC_WRITE_3_wrong_subject_blocked
    # IC-PUSH
    test_E_IC_PUSH_1_allow
    test_E_IC_PUSH_2_no_prefix_blocked
    test_E_IC_PUSH_3_wrong_files_blocked
    # CMP-WRITE
    test_E_CMP_WRITE_0_git_add_history
    test_E_CMP_WRITE_0b_git_add_changelog
    test_E_CMP_WRITE_1_commit_history
    test_E_CMP_WRITE_2_commit_changelog
    test_E_CMP_WRITE_3_no_prefix_blocked
    # CMP-PUSH
    test_E_CMP_PUSH_1_allow
    test_E_CMP_PUSH_4_wrong_files_blocked
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
