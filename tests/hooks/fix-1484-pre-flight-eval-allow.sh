#!/bin/bash
# tests/hooks/fix-1484-pre-flight-eval-allow.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js
# Tags: worktree, enforce, hook, security, scope:issue-specific
# L3 gap (what this test does NOT catch): a live pre-flight.sh whose output eval consumes,
#   sub-shell expansion of $AGENTS_MAIN_ROOT, ordering between contesting allow predicates.
#   Mitigation: WORKFLOW_USER_VERIFIED preflight (bin/check-verification-gate.sh, hook-registration).
# Issue #1484: `eval "$(bash "<root>/skills/issue-close-finalize/scripts/pre-flight.sh")"` was
#   false-blocked; the fix sanctioned pre-flight.sh and added an eval-unwrap regex. A path still
#   carrying an unexpanded $AGENTS_MAIN_ROOT is blocked with a hint since #2561.
# Drive: payload JSON on stdin of `node hooks/enforce-worktree.js`, cwd = a fixture main worktree.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
    _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
fi
GUARD_JS="${_SCRIPT_CHECKOUT_ROOT_NODE}/hooks/enforce-worktree.js"

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

# Tempdir base, cleaned up at exit. Node gives a POSIX-style path on Windows.
TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'fix1484-'+process.pid).replace(/\\\\/g,'/');
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

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

build_bash_payload() {
    local cmd="$1"
    local q; q="$(json_quote "$cmd")"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$q"
}

# Run the guard with cwd set to <main-worktree>.
# Returns: 0 = ALLOW, 1 = BLOCK, 2 = CRASH.
GUARD_OUT=""
GUARD_RC=0
run_guard() {
    local payload="$1"; shift
    local main_wt="$1"; shift
    # Remaining args are extra env vars (KEY=VAL form), e.g. AGENTS_MAIN_ROOT=...
    GUARD_RC=0
    GUARD_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env \
        -C "$main_wt" \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$main_wt" \
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
if ! env -C "$TMPDIR_BASE" true 2>/dev/null; then
    run_guard() {
        local payload="$1"; shift
        local main_wt="$1"; shift
        GUARD_RC=0
        GUARD_OUT="$(cd "$main_wt" && printf '%s' "$payload" | run_with_timeout 30 \
            env \
            "ENFORCE_WORKTREE=on" \
            "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$main_wt" \
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

# Initialize a minimal main worktree. Echoes cygpath-normalized path.
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

# Add a linked worktree under <main-worktree>/.wt/<name>. Echoes its path.
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

# The root the sanctioned worker scripts are named under. The guard accepts a worker
# script only under the checkout the guard itself runs from (#2561: no environment
# variable is consulted), and it compares paths without touching the files — so the
# commands below name scripts under this checkout and never execute or create them.
guard_checkout_root() { printf '%s\n' "$_SCRIPT_CHECKOUT_ROOT_NODE"; }   # the case-number argument is a label only

# ============================================================================
# F1484 series — eval-unwrap branch for isAllowedWorkerScriptInvocation.
# pre-flight.sh is invoked via eval "$(bash "...")", which the primary bare-bash
# regex in worker-script.js does not match.
#   ALLOW: F1484-1, F1484-2, F1484-5   BLOCK: F1484-3, F1484-4, F1484-6, F1484-7
# ============================================================================

# F1484-1: eval-wrapped pre-flight.sh (no `|| exit 0`) → ALLOW
# RED before fix: primary regex doesn't match eval-wrapped form.
test_F1484_1_allow_eval_preflight_no_tail() {
    local repo; repo="$(setup_main_worktree "f1484-1")"
    local guard_root; guard_root="$(guard_checkout_root "1")"
    local cmd; cmd="eval \"\$(bash \"$guard_root/skills/issue-close-finalize/scripts/pre-flight.sh\")\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" || rc=$?
    assert_allow "F1484-1: eval-wrapped pre-flight.sh (no tail) → ALLOW (RED before fix)" "$rc"
}

# F1484-2: eval-wrapped pre-flight.sh + `|| exit 0` tail → ALLOW
# RED before fix: primary regex doesn't match eval-wrapped form.
test_F1484_2_allow_eval_preflight_exit0_tail() {
    local repo; repo="$(setup_main_worktree "f1484-2")"
    local guard_root; guard_root="$(guard_checkout_root "2")"
    local cmd; cmd="eval \"\$(bash \"$guard_root/skills/issue-close-finalize/scripts/pre-flight.sh\")\" || exit 0"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" || rc=$?
    assert_allow "F1484-2: eval-wrapped pre-flight.sh + || exit 0 → ALLOW (RED before fix)" "$rc"
}

# F1484-3: eval-wrapped NON-SANCTIONED script → BLOCK
# GREEN always: bin/some-other.sh is not in SANCTIONED list, identity gate rejects.
test_F1484_3_block_eval_non_sanctioned() {
    local repo; repo="$(setup_main_worktree "f1484-3")"
    local guard_root; guard_root="$(guard_checkout_root "3")"
    local cmd; cmd="eval \"\$(bash \"$guard_root/bin/some-other.sh\")\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" || rc=$?
    assert_block "F1484-3: eval-wrapped non-sanctioned script → BLOCK (identity gate, GREEN always)" "$rc"
}

# F1484-4: eval-wrapped + args (migrate-repo style, out of scope) → BLOCK
# GREEN always: the eval-unwrap branch accepts NO args to the inner bash call.
# A trailing argument makes this out-of-scope and must be rejected.
test_F1484_4_block_eval_with_args() {
    local repo; repo="$(setup_main_worktree "f1484-4")"
    local guard_root; guard_root="$(guard_checkout_root "4")"
    local cmd; cmd="eval \"\$(bash \"$guard_root/skills/issue-close-finalize/scripts/pre-flight.sh\" \"$repo\")\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" || rc=$?
    assert_block "F1484-4: eval-wrapped + inner args → BLOCK (no-arg restriction, GREEN always)" "$rc"
}

# F1484-5: bare bash + existing SANCTIONED script (regression check) → ALLOW
# GREEN always: primary regex path must not regress after the eval-unwrap branch is added.
test_F1484_5_allow_bare_bash_sanctioned_regression() {
    local repo; repo="$(setup_main_worktree "f1484-5")"
    local guard_root; guard_root="$(guard_checkout_root "5")"
    local cmd; cmd="bash \"$guard_root/bin/check-unstaged-tracked.sh\" \"$repo\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" || rc=$?
    assert_allow "F1484-5: bare bash + sanctioned script → ALLOW (primary-regex regression, GREEN always)" "$rc"
}

# F1484-6: eval-wrapped + `|| rm -rf /` chaining (security pin) → BLOCK
# GREEN always: non-exit command in tail; structural argTail scan must catch it.
test_F1484_6_block_eval_dangerous_tail() {
    local repo; repo="$(setup_main_worktree "f1484-6")"
    local guard_root; guard_root="$(guard_checkout_root "6")"
    local cmd; cmd="eval \"\$(bash \"$guard_root/skills/issue-close-finalize/scripts/pre-flight.sh\")\" || rm -rf /"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" || rc=$?
    assert_block "F1484-6: eval-wrapped + || rm -rf / chaining → BLOCK (argTail security pin, GREEN always)" "$rc"
}

# F1484-7: literal $AGENTS_MAIN_ROOT prefix (env-var unexpanded) → BLOCK with a hint (#2561).
# The hook reads the raw command before the shell expands it, so it cannot confirm which
# file will run: the prefix is no longer rewritten, and the block reason names the literal form.
test_F1484_7_block_literal_env_var_prefix() {
    local repo; repo="$(setup_main_worktree "f1484-7")"
    local guard_root; guard_root="$(guard_checkout_root "7")"
    # Pass the LITERAL string $AGENTS_MAIN_ROOT — NOT the expanded path.
    # json_quote will properly escape the $ signs so the JSON payload contains them verbatim.
    local literal_cmd='eval "$(bash "$AGENTS_MAIN_ROOT/skills/issue-close-finalize/scripts/pre-flight.sh")" || exit 0'
    local payload; payload="$(build_bash_payload "$literal_cmd")"
    local rc=0
    run_guard "$payload" "$repo" || rc=$?
    assert_block "F1484-7: literal \$AGENTS_MAIN_ROOT prefix → BLOCK (unexpanded variable, #2561)" "$rc"
    local hint='Hint: skills/issue-close-finalize/scripts/pre-flight.sh is allowed from the main worktree, but this command names it through $AGENTS_MAIN_ROOT'
    if printf '%s' "$GUARD_OUT" | grep -qF "$hint"; then
        pass "F1484-7 hint: the block reason names the script and the variable it was reached through"
    else
        fail "F1484-7 hint: block reason lacks the variable-path hint (out: $GUARD_OUT)"
    fi
}

# ============================================================================
# Run all
# ============================================================================

run_all() {
    test_F1484_1_allow_eval_preflight_no_tail
    test_F1484_2_allow_eval_preflight_exit0_tail
    test_F1484_3_block_eval_non_sanctioned
    test_F1484_4_block_eval_with_args
    test_F1484_5_allow_bare_bash_sanctioned_regression
    test_F1484_6_block_eval_dangerous_tail
    test_F1484_7_block_literal_env_var_prefix
}

# 180s outer timeout so a stuck git op cannot wedge the suite.
if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_FIX1484_TEST_INNER:-}" ]; then
        _FIX1484_TEST_INNER=1 timeout 180 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
