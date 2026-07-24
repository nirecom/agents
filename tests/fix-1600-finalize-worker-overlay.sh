#!/bin/bash
# tests/fix-1600-finalize-worker-overlay.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js
# Tags: worktree, enforce, hook, security, scope:issue-specific
#
# Issue #1600: the finalize-worker command shapes moved to single-line,
# fully-resolved-literal-path `eval` (env-prefix + node/bash interpreter + args).
# The legacy SANCTIONED array + eval-unwrap regex in worker-script.js only match
# a bare `eval "$(bash "<path>")"` (no env prefix, no args), so the three live
# finalize shapes are false-blocked (#1590 regression). The fix adds a structured
# overlay (finalize-worker-overlay.js: FINALIZE_OVERLAY_REGISTRY, G5_DECISION_VALUES,
# matchFinalizeWorkerOverlay) wired into isAllowedWorkerScriptInvocation BEFORE the
# legacy SANCTIONED check. This test drives that overlay:
#   RED (BLOCK now, ALLOW after fix): every ALLOW case below
#   GREEN (BLOCK always):             every identity/arg/structural attack below
#
# TL3 gap (what this TL2 test does NOT catch):
#   - A real /session-close → /issue-close-finalize chain issuing the eval from a
#     genuine main worktree with a live AGENTS_CONFIG_DIR and real finalize scripts.
#   - Cross-platform shell expansion of the resolved literals inside the sub-shell.
# Closest-to-action mitigation: hook-registration category at WORKFLOW_USER_VERIFIED
# preflight (bin/check-verification-gate.sh).
#
# Drive surface (full hook):
#   echo '{"tool_name":"Bash","tool_input":{"command":"<cmd>"}}' | \
#     (cd <main-worktree> && AGENTS_CONFIG_DIR=<fake-acd> \
#      WORKFLOW_PLANS_DIR=<plans> node hooks/enforce-worktree.js)

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

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'fix1600-'+process.pid).replace(/\\\\/g,'/');
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
    # Remaining args are extra env vars (KEY=VAL form).
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

# Fake AGENTS_CONFIG_DIR with the finalize scripts touched (#1600 overlay targets)
# plus the legacy sanctioned scripts. Echoes the cygpath-normalized path.
setup_fake_acd() {
    local name="$1"
    local d="$TMPDIR_BASE/fake-acd-$name"
    mkdir -p "$d/bin/github-issues"
    touch "$d/bin/check-unstaged-tracked.sh"
    touch "$d/bin/probe-remote-bootstrap.sh"
    touch "$d/bin/issue-close-gate.sh"
    touch "$d/bin/github-issues/issue-close-stage-triage.sh"
    touch "$d/bin/github-issues/parent-body-update.sh"
    # #1600: the 4 finalize scripts the overlay registry targets.
    mkdir -p "$d/skills/issue-close-finalize/scripts"
    touch "$d/skills/issue-close-finalize/scripts/pre-flight.sh"
    touch "$d/skills/issue-close-finalize/scripts/run-initial.sh"
    touch "$d/skills/issue-close-finalize/scripts/run-loop-step.js"
    touch "$d/skills/issue-close-finalize/scripts/run-finalize-terminal.sh"
    touch "$d/skills/issue-close-finalize/scripts/step-g5-loop.sh"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

# Create a WORKFLOW_PLANS_DIR under TMPDIR_BASE; echo cygpath-normalized path.
setup_plans_dir() {
    local name="$1"
    local d="$TMPDIR_BASE/plans-$name"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

# ----------------------------------------------------------------------------
# Live command-shape builders (single-line, fully-resolved literal paths).
# printf format strings are single-quoted so embedded " and $( are verbatim.
# ----------------------------------------------------------------------------

# initial: env prefix (ACD/FSD/MWT) + bash run-initial.sh + 3 args.
build_initial() {
    local acd_val="$1" fsd_val="$2" mwt_val="$3" scripts="$4"
    printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234" "")"' \
        "$acd_val" "$fsd_val" "$mwt_val" "$scripts"
}

# loop_step: env prefix (ACD/FSD) + node run-loop-step.js + state + decision.
build_loop_step() {
    local acd_val="$1" fsd_val="$2" scripts="$3" statefile="$4" decision="$5"
    printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" node "%s/run-loop-step.js" "%s" "%s")"' \
        "$acd_val" "$fsd_val" "$scripts" "$statefile" "$decision"
}

# finalize_terminal: env prefix (ACD) + bash run-finalize-terminal.sh + 3 args.
build_finalize_terminal() {
    local acd_val="$1" scripts="$2" statefile="$3" sid="$4" outcome="$5"
    printf 'eval "$(AGENTS_CONFIG_DIR="%s" bash "%s/run-finalize-terminal.sh" "%s" "%s" "%s")"' \
        "$acd_val" "$scripts" "$statefile" "$sid" "$outcome"
}

# ----------------------------------------------------------------------------
# Test groups (sourced — share the harness/fixtures/builders defined above).
# ----------------------------------------------------------------------------

SCRIPT_DIR_1600="$(dirname "${BASH_SOURCE[0]}")/fix-1600-finalize-worker-overlay"

# shellcheck source=./fix-1600-finalize-worker-overlay/allow-cases.sh
. "$SCRIPT_DIR_1600/allow-cases.sh"
# shellcheck source=./fix-1600-finalize-worker-overlay/block-identity-args.sh
. "$SCRIPT_DIR_1600/block-identity-args.sh"
# shellcheck source=./fix-1600-finalize-worker-overlay/block-structural.sh
. "$SCRIPT_DIR_1600/block-structural.sh"

# ============================================================================
# Run all
# ============================================================================

run_all() {
    # ALLOW
    test_allow_initial
    test_allow_loop_step_enum "accept"
    test_allow_loop_step_enum "decline"
    test_allow_loop_step_enum "llm_declined"
    test_allow_loop_step_enum "recurse_done"
    test_allow_finalize_terminal
    test_allow_initial_env_order_swapped
    # BLOCK — identity/env (C1)
    test_block_acd_env_mismatch
    test_block_variable_script_path
    test_block_fsd_env_mismatch
    test_block_mwt_env_mismatch
    test_block_extra_env_key
    test_block_missing_fsd_env
    # BLOCK — args (C3)
    test_block_loop_extra_arg
    test_block_loop_missing_decision
    test_block_loop_state_outside_plans
    test_block_terminal_outcome_outside_plans
    test_block_loop_state_sibling_prefix_bypass
    test_block_loop_state_path_traversal
    test_block_terminal_outcome_sibling_prefix_bypass
    test_block_terminal_outcome_path_traversal
    test_block_loop_bad_decision "approve" "approve"
    test_block_loop_bad_decision "accepted" "accepted"
    test_block_loop_bad_decision "Accept" "Accept"
    test_block_loop_bad_decision "" "empty"
    test_block_initial_extra_arg
    test_block_initial_missing_arg
    test_block_finalize_terminal_extra_arg
    test_block_finalize_terminal_missing_arg
    test_block_g5_loop_live_shape
    # BLOCK — structural
    test_block_dangerous_tail
    test_block_cmd_subst_arg
    test_block_interp_mismatch_node_on_bash
    test_block_interp_mismatch_bash_on_node
    test_block_multiline
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_FIX1600_TEST_INNER:-}" ]; then
        _FIX1600_TEST_INNER=1 timeout 180 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
