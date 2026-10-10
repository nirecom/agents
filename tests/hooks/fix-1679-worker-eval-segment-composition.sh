#!/bin/bash
# tests/hooks/fix-1679-worker-eval-segment-composition.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree.js, skills/issue-close-finalize/SKILL.md
# Tags: enforce-worktree, allowlist, security, TL1, TL2, pwsh-not-required, scope:issue-specific
#
# Issue #1679 (S-8): a sanctioned pre-flight.sh eval must stay allowed next to benign
# companion segments (leading cd, trailing echo, 2>&1), and no companion may write or
# mutate the environment. IN = logged forms, AD = adversarial (BLOCK), E2E = real hook,
# MU = isAllowedWorkerScriptInvocation() called directly.
# TL3 gap: a real /issue-close-finalize chain and the PreToolUse registration itself.

set -u

# Self-re-exec under a hard timeout BEFORE any fixture is built, so the outer
# process never pays for the git init / worktree add it is about to discard.
if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_FIX1679_SEG_INNER:-}" ]; then
        _FIX1679_SEG_INNER=1 timeout 180 bash "$0" "$@"
        exit $?
    fi
fi

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

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'fix1679-seg-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

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
# Fixtures — one shared main worktree + linked worktree + plans dir.
# No case mutates fixture state, so a single build keeps the 25+ guard spawns
# inside the 120s budget. Pattern lifted from tests/hooks/fix-1600-finalize-worker-overlay.sh.
# ----------------------------------------------------------------------------

setup_main_worktree() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q --no-verify -m "initial"
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$repo"; else echo "$repo"; fi
}

add_linked_worktree() {
    local main_wt="$1" name="$2" branch="$3"
    local wt_path="$main_wt/.wt/$name"
    git -C "$main_wt" worktree add -q -b "$branch" "$wt_path" >/dev/null
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$wt_path"; else echo "$wt_path"; fi
}

setup_plans_dir() {
    local d="$TMPDIR_BASE/plans-$1"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$d"; else echo "$d"; fi
}

REPO="$(setup_main_worktree "repo")"
LINKED="$(add_linked_worktree "$REPO" "wt1" "feat/x")"
PLANS="$(setup_plans_dir "main")"
# The guard accepts a sanctioned script only under the checkout it was loaded from
# (#2561), so the rows name this checkout. The comparison is on the path alone:
# bin/evil.sh (AD1679-7) is never created, and nothing is written into this checkout.
GUARD_CHECKOUT="$_SCRIPT_CHECKOUT_ROOT_NODE"
SCRIPTS="$GUARD_CHECKOUT/skills/issue-close-finalize/scripts"

# PF_RESOLVED is the literal absolute path the guard can verify. PF_VARIABLE is the
# unexpanded form: PreToolUse fires BEFORE the shell expands it, so the guard cannot
# tell which file would run and blocks it with a hint (#2561).
PF_RESOLVED="$SCRIPTS/pre-flight.sh"
PF_VARIABLE='$AGENTS_MAIN_ROOT/skills/issue-close-finalize/scripts/pre-flight.sh'

# eval-wrapped sanctioned segment. $1 = script path literal.
pf_eval() { printf 'eval "$(bash "%s")"' "$1"; }

# Convenience: run one command through the guard against the shared fixture.
guard() {
    local cmd="$1"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$REPO" \
        "WORKFLOW_PLANS_DIR=$PLANS" || rc=$?
    return $rc
}

# ----------------------------------------------------------------------------
# Test groups (sourced — share the harness/fixtures/builders defined above).
# ----------------------------------------------------------------------------

SCRIPT_DIR_1679="$(dirname "${BASH_SOURCE[0]}")/fix-1679-worker-eval-segment-composition"

# shellcheck source=./fix-1679-worker-eval-segment-composition/in-ad-cases.sh
. "$SCRIPT_DIR_1679/in-ad-cases.sh"
# shellcheck source=./fix-1679-worker-eval-segment-composition/e2e-tl1-cases.sh
. "$SCRIPT_DIR_1679/e2e-tl1-cases.sh"

# ============================================================================
# Run all
# ============================================================================

test_in_cases
test_ad_cases
test_e2e_cases
test_tl1_cases

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
