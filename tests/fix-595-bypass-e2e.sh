#!/bin/bash
# tests/fix-595-bypass-e2e.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows.js.
# Tags: worktree, enforce, hook, history, docs, security, interpreter-wrapper, fix-802
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

test_E_WT_REMOVE_4_bash_dash_c_blocked() {
    # #802 security regression: `bash -c '...'` wraps the worktree command in a
    # nested shell. stripQuotedArgs collapses the SQ body so hasShellChaining()
    # returns false, but the raw cmd still matches /\bgit\b/ and
    # /\bworktree\s+remove\b/, causing isAllowedWorktreeCommand to allow the
    # wrapper. The nested shell expands $linked and runs `&& echo done`
    # unconstrained — exactly the chaining the guard is supposed to block.
    local repo; repo="$(setup_main_worktree "wt-remove-4")"
    local linked; linked="$(add_linked_worktree "$repo" "lw4" "feature/lw4")"
    local cmd="bash -c 'git worktree remove $linked && echo done'"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-WT-REMOVE-4: bash -c 'git worktree remove … && echo done' → BLOCK (#802 interpreter wrapper)" "$rc"
}

test_E_WT_REMOVE_5_sh_dash_c_blocked() {
    # Sibling of WT-REMOVE-4 covering the POSIX `sh -c` form. The same
    # quote-stripping path applies regardless of which interpreter wraps the
    # command, so the guard must reject both bash and sh wrappers symmetrically.
    local repo; repo="$(setup_main_worktree "wt-remove-5")"
    local linked; linked="$(add_linked_worktree "$repo" "lw5" "feature/lw5")"
    local cmd="sh -c 'git worktree remove $linked'"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-WT-REMOVE-5: sh -c 'git worktree remove …' → BLOCK (#802 interpreter wrapper)" "$rc"
}

test_E_WT_REMOVE_6_quoted_path_allowed() {
    # Regression pin: the legitimate quoted-path form must continue to ALLOW.
    # Fixing #802 by rejecting all quoted bodies would over-block this common
    # case where the linked-worktree path contains spaces or is variable-derived
    # and the user simply wraps the path in DQ.
    local repo; repo="$(setup_main_worktree "wt-remove-6")"
    local linked; linked="$(add_linked_worktree "$repo" "lw6" "feature/lw6")"
    local cmd="git worktree remove \"$linked\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_allow "E-WT-REMOVE-6: git worktree remove \"<linked>\" → ALLOW (regression pin)" "$rc"
}

test_E_WT_REMOVE_7_env_prefix_bash_c_blocked() {
    # Combines the WORKTREE_END_SKILL=1 prefix (which is the sanctioned form for
    # /worktree-end) with a `bash -c '...'` wrapper. The prefix must NOT launder
    # the nested-shell wrapper — the same security property as WT-REMOVE-4 must
    # hold even when the caller adds the sanctioned env prefix in front.
    local repo; repo="$(setup_main_worktree "wt-remove-7")"
    local linked; linked="$(add_linked_worktree "$repo" "lw7" "feature/lw7")"
    local cmd="WORKTREE_END_SKILL=1 bash -c 'git worktree remove $linked'"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-WT-REMOVE-7: WORKTREE_END_SKILL=1 bash -c '...' → BLOCK (#802 env-prefix + wrapper)" "$rc"
}

# ----------------------------------------------------------------------------
# Fix #820 — Interpreter-wrapper + RCE-flag hardening (E-WT-REMOVE-8..12)
#
# Each case drives the hook end-to-end with a Bash PreToolUse payload. After
# source implementation lands, these are blocked by rejectInterpreterAndChaining
# / rejectRceGitFlags wired into the relevant predicates (merge / cleanup /
# push). Before implementation, several may pass-by-accident if the existing
# hasShellChaining/sub-match guards already trip on the pattern — that is fine,
# the test asserts the expected outcome, not the rejection path.
# ----------------------------------------------------------------------------

test_E_WT_REMOVE_8_bash_c_pull_ff_blocked() {
    # #820: `bash -c 'git pull --ff-only'` against the merge predicate.
    # The wrapper hides `git pull --ff-only` behind a quoted body — without the
    # new rejectInterpreterAndChaining helper called by isAllowedFastForwardMerge,
    # nothing in the predicate inspects the outer interpreter token.
    local repo; repo="$(setup_main_worktree "wt-remove-8")"
    local cmd="bash -c 'git pull --ff-only'"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-WT-REMOVE-8: bash -c 'git pull --ff-only' → BLOCK (#820 merge predicate interpreter wrapper)" "$rc"
}

test_E_WT_REMOVE_9_rce_c_sshcommand_pull_blocked() {
    # #820: `git -c core.sshCommand=… pull --ff-only`. -c sets an arbitrary
    # config key for the duration of the command; the value of
    # core.sshCommand is executed by the transport, enabling RCE.
    # rejectRceGitFlags must catch this in isAllowedFastForwardMerge.
    local repo; repo="$(setup_main_worktree "wt-remove-9")"
    local cmd="git -c core.sshCommand=curl pull --ff-only"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-WT-REMOVE-9: git -c core.sshCommand=… pull --ff-only → BLOCK (#820 RCE flag)" "$rc"
}

test_E_WT_REMOVE_10_bash_c_stash_blocked() {
    # #820: `bash -c 'git stash'` against the cleanup predicate
    # (isAllowedMainWorktreeCleanup). With no linked worktree the cleanup
    # predicate is the natural ALLOW path, but the wrapper must not slip past.
    local repo; repo="$(setup_main_worktree "wt-remove-10")"
    local cmd="bash -c 'git stash'"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-WT-REMOVE-10: bash -c 'git stash' → BLOCK (#820 cleanup predicate interpreter wrapper)" "$rc"
}

test_E_WT_REMOVE_11_bash_c_push_blocked() {
    # #820: `bash -c 'git push'` against the push predicate
    # (isAllowedPushAllExcluded). Without the new helper, the wrapper bypasses
    # hasShellChaining and the predicate may consider the inner command.
    local repo; repo="$(setup_main_worktree "wt-remove-11")"
    local cmd="bash -c 'git push'"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-WT-REMOVE-11: bash -c 'git push' → BLOCK (#820 push predicate interpreter wrapper)" "$rc"
}

test_E_WT_REMOVE_12_rce_c_sshcommand_push_blocked() {
    # #820: `git -c core.sshCommand=… push`. The same RCE-class flag against
    # the push predicate — rejectRceGitFlags must catch it in
    # isAllowedPushAllExcluded.
    local repo; repo="$(setup_main_worktree "wt-remove-12")"
    local cmd="git -c core.sshCommand=curl push"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0; run_guard "$payload" "$repo" || rc=$?
    assert_block "E-WT-REMOVE-12: git -c core.sshCommand=… push → BLOCK (#820 push predicate RCE flag)" "$rc"
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
    test_E_WT_REMOVE_4_bash_dash_c_blocked
    test_E_WT_REMOVE_5_sh_dash_c_blocked
    test_E_WT_REMOVE_6_quoted_path_allowed
    test_E_WT_REMOVE_7_env_prefix_bash_c_blocked
    # Fix #820 — interpreter-wrapper + RCE-flag hardening
    test_E_WT_REMOVE_8_bash_c_pull_ff_blocked
    test_E_WT_REMOVE_9_rce_c_sshcommand_pull_blocked
    test_E_WT_REMOVE_10_bash_c_stash_blocked
    test_E_WT_REMOVE_11_bash_c_push_blocked
    test_E_WT_REMOVE_12_rce_c_sshcommand_push_blocked
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
