#!/bin/bash
# tests/fix-1484-pre-flight-eval-allow.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js
# Tags: worktree, enforce, hook, security, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
#   - Real sessions where AGENTS_CONFIG_DIR is an actual live config dir with
#     a real pre-flight.sh that produces output consumed by eval
#   - Cross-platform shell expansion of $AGENTS_CONFIG_DIR in sub-shells
#   - Hook invocation ordering when multiple allow predicates contest the command
# Closest-to-action mitigation: gap is covered at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
#
# Issue #1484: eval-wrapped pre-flight.sh form is false-blocked because
# isAllowedWorkerScriptInvocation() primary regex `^\s*bash\s+"([^"]+)"(\s[\s\S]*)?$`
# does not match `eval "$(bash "$acd/skills/issue-close-finalize/scripts/pre-flight.sh")"`.
# The fix adds: (1) pre-flight.sh to SANCTIONED, (2) eval-unwrap secondary regex,
# (3) resolution of literal $AGENTS_CONFIG_DIR prefix before SANCTIONED comparison.
#
# Drive surface (full hook):
#   echo '{"tool_name":"Bash","tool_input":{"command":"<cmd>"}}' | \
#     (cd <main-worktree> && AGENTS_CONFIG_DIR=<fake-acd> node hooks/enforce-worktree.js)

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
    # Remaining args are extra env vars (KEY=VAL form), e.g. AGENTS_CONFIG_DIR=...
    GUARD_RC=0
    GUARD_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
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
            env -u CLAUDE_ENV_FILE \
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

# Create a fake AGENTS_CONFIG_DIR with all sanctioned worker scripts as empty
# files, including the pre-flight.sh targeted by #1484. Echoes the
# cygpath-normalized path.
setup_fake_acd() {
    local name="$1"
    local d="$TMPDIR_BASE/fake-acd-$name"
    mkdir -p "$d/bin/github-issues"
    touch "$d/bin/check-unstaged-tracked.sh"
    touch "$d/bin/probe-remote-bootstrap.sh"
    touch "$d/bin/issue-close-gate.sh"
    touch "$d/bin/github-issues/issue-close-stage-triage.sh"
    touch "$d/bin/github-issues/parent-body-update.sh"
    # #1484: pre-flight.sh must exist in the fake ACD so SANCTIONED path resolves
    mkdir -p "$d/skills/issue-close-finalize/scripts"
    touch "$d/skills/issue-close-finalize/scripts/pre-flight.sh"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

# ============================================================================
# F1484 series — eval-unwrap branch for isAllowedWorkerScriptInvocation
#
# The hook receives commands from the main worktree CWD. Because pre-flight.sh
# is invoked via eval "$(bash "...")" rather than bare bash "...", the primary
# regex in worker-script.js does not match, causing a false-block. These tests
# drive the fix by confirming:
#   RED (BLOCK now, ALLOW after fix): F1484-1, F1484-2, F1484-7
#   GREEN (BLOCK always):             F1484-3, F1484-4, F1484-6
#   GREEN (ALLOW always, regression): F1484-5
# ============================================================================

# F1484-1: eval-wrapped pre-flight.sh (no `|| exit 0`) → ALLOW
# RED before fix: primary regex doesn't match eval-wrapped form.
test_F1484_1_allow_eval_preflight_no_tail() {
    local repo; repo="$(setup_main_worktree "f1484-1")"
    local fake_acd; fake_acd="$(setup_fake_acd "1")"
    local cmd; cmd="eval \"\$(bash \"$fake_acd/skills/issue-close-finalize/scripts/pre-flight.sh\")\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" || rc=$?
    assert_allow "F1484-1: eval-wrapped pre-flight.sh (no tail) → ALLOW (RED before fix)" "$rc"
}

# F1484-2: eval-wrapped pre-flight.sh + `|| exit 0` tail → ALLOW
# RED before fix: primary regex doesn't match eval-wrapped form.
test_F1484_2_allow_eval_preflight_exit0_tail() {
    local repo; repo="$(setup_main_worktree "f1484-2")"
    local fake_acd; fake_acd="$(setup_fake_acd "2")"
    local cmd; cmd="eval \"\$(bash \"$fake_acd/skills/issue-close-finalize/scripts/pre-flight.sh\")\" || exit 0"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" || rc=$?
    assert_allow "F1484-2: eval-wrapped pre-flight.sh + || exit 0 → ALLOW (RED before fix)" "$rc"
}

# F1484-3: eval-wrapped NON-SANCTIONED script → BLOCK
# GREEN always: bin/some-other.sh is not in SANCTIONED list, identity gate rejects.
test_F1484_3_block_eval_non_sanctioned() {
    local repo; repo="$(setup_main_worktree "f1484-3")"
    local fake_acd; fake_acd="$(setup_fake_acd "3")"
    mkdir -p "$fake_acd/bin"
    touch "$fake_acd/bin/some-other.sh"
    local cmd; cmd="eval \"\$(bash \"$fake_acd/bin/some-other.sh\")\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" || rc=$?
    assert_block "F1484-3: eval-wrapped non-sanctioned script → BLOCK (identity gate, GREEN always)" "$rc"
}

# F1484-4: eval-wrapped + args (migrate-repo style, out of scope) → BLOCK
# GREEN always: the eval-unwrap branch accepts NO args to the inner bash call.
# A trailing argument makes this out-of-scope and must be rejected.
test_F1484_4_block_eval_with_args() {
    local repo; repo="$(setup_main_worktree "f1484-4")"
    local fake_acd; fake_acd="$(setup_fake_acd "4")"
    local cmd; cmd="eval \"\$(bash \"$fake_acd/skills/issue-close-finalize/scripts/pre-flight.sh\" \"$repo\")\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" || rc=$?
    assert_block "F1484-4: eval-wrapped + inner args → BLOCK (no-arg restriction, GREEN always)" "$rc"
}

# F1484-5: bare bash + existing SANCTIONED script (regression check) → ALLOW
# GREEN always: primary regex path must not regress after the eval-unwrap branch is added.
test_F1484_5_allow_bare_bash_sanctioned_regression() {
    local repo; repo="$(setup_main_worktree "f1484-5")"
    local fake_acd; fake_acd="$(setup_fake_acd "5")"
    local cmd; cmd="bash \"$fake_acd/bin/check-unstaged-tracked.sh\" \"$repo\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" || rc=$?
    assert_allow "F1484-5: bare bash + sanctioned script → ALLOW (primary-regex regression, GREEN always)" "$rc"
}

# F1484-6: eval-wrapped + `|| rm -rf /` chaining (security pin) → BLOCK
# GREEN always: non-exit command in tail; structural argTail scan must catch it.
test_F1484_6_block_eval_dangerous_tail() {
    local repo; repo="$(setup_main_worktree "f1484-6")"
    local fake_acd; fake_acd="$(setup_fake_acd "6")"
    local cmd; cmd="eval \"\$(bash \"$fake_acd/skills/issue-close-finalize/scripts/pre-flight.sh\")\" || rm -rf /"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" || rc=$?
    assert_block "F1484-6: eval-wrapped + || rm -rf / chaining → BLOCK (argTail security pin, GREEN always)" "$rc"
}

# F1484-7: literal $AGENTS_CONFIG_DIR prefix (env-var unexpanded) → ALLOW
# RED before fix: the hook receives the raw command string before shell expansion,
# so the path contains the literal text `$AGENTS_CONFIG_DIR`. The fix must resolve
# this literal prefix to the actual acd value before SANCTIONED comparison.
test_F1484_7_allow_literal_env_var_prefix() {
    local repo; repo="$(setup_main_worktree "f1484-7")"
    local fake_acd; fake_acd="$(setup_fake_acd "7")"
    # Pass the LITERAL string $AGENTS_CONFIG_DIR — NOT the expanded path.
    # json_quote will properly escape the $ signs so the JSON payload contains them verbatim.
    local literal_cmd='eval "$(bash "$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/pre-flight.sh")" || exit 0'
    local payload; payload="$(build_bash_payload "$literal_cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" || rc=$?
    assert_allow "F1484-7: literal \$AGENTS_CONFIG_DIR prefix → ALLOW (env-var resolution, RED before fix)" "$rc"
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
    test_F1484_7_allow_literal_env_var_prefix
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
