#!/bin/bash
# tests/feature-1701-workflow-gate-code-size.sh
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/code-size-gate.js, bin/review-code-size
# Tags: workflow-gate, hook, gate2, code-size, file-split, scope:issue-specific
# Serial: #1799 case 5/14 ("WIP commit + staged 501-line .js -> still blocked") was reported flaky under -j8 parallel load; 18 consecutive clean reruns across two diagnostic passes could not reproduce it, so no root cause was isolated. This header is a mitigation (route to run-all.sh's serial lane on the suspicion the flake was load-related), not a confirmed fix — if it recurs even serialized, that rules out load and root-cause investigation should resume.
#
# Issue #1701 — Gate 2 hard-blocks `git commit` on a STAGED code file over the 500-line HARD limit (rules/coding/file-split.md), delegating to hooks/workflow-gate/code-size-gate.js -> bash bin/review-code-size --staged.
# TL3 gap: whether the PreToolUse hook fires for a real git commit and whether settings.json registers it for the Bash tool — checked at WORKFLOW_USER_VERIFIED preflight (bin/check-verification-gate.sh, category hook-registration).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_JS="${_AGENTS_DIR_NODE}/hooks/workflow-gate.js"
GATE_MODULE="${AGENTS_DIR}/hooks/workflow-gate/code-size-gate.js"

# Pre-implementation skip gate: Gate 2 lives in hooks/workflow-gate/code-size-gate.js — until that module exists there is nothing to assert, so exit 77 (run-all.sh treats it as SKIP).
if [ ! -f "$GATE_MODULE" ]; then
    echo "SKIP: hooks/workflow-gate/code-size-gate.js not present yet (issue #1701 not implemented)"
    exit 77
fi
if [ ! -f "$HOOK_JS" ]; then
    echo "SKIP: hooks/workflow-gate.js not present"
    exit 77
fi

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'gate2-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Plans-dir isolation (#1799): supervisor-emit must never write into the developer's real ~/.workflow-plans/ — pinned alongside CLAUDE_WORKFLOW_DIR.
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

make_lines() {
    local n="$1" i
    for ((i = 1; i <= n; i++)); do echo "line $i"; done
}

fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    to_node_path "$d"
}

write_complete_state() {
    local wfdir="$1" sid="$2"
    node -e "
const fs = require('fs');
const path = require('path');
const { VALID_STEPS } = require('$_AGENTS_DIR_NODE/hooks/workflow-state.js');
const steps = {};
const now = new Date().toISOString();
for (const s of VALID_STEPS) steps[s] = { status: 'complete', updated_at: now };
const state = { version: 1, session_id: '$sid', created_at: now, steps };
fs.writeFileSync(path.join('$wfdir', '$sid' + '.json'), JSON.stringify(state, null, 2));
"
}

write_workflow_off_marker() {
    local wfdir="$1" sid="$2"
    printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$wfdir/$sid.workflow-off"
}

# Config-dir fixtures. AGENTS_CONFIG_DIR drives two independent decisions (CPR-SC):
#   1. isAgentsSessionRepo() — a NON-git config dir fails closed (true), keeping Gate 2 armed for the temp repo under test.
#   2. resolveAgentsConfigDir() — env candidate adopted only with BOTH markers (hooks/enforce-worktree.js + bin/); a marker-less dir falls through to the module anchor (the real agents checkout).
# ---------------------------------------------------------------------------

# Plain dir: no markers -> real bin/review-code-size is used, Gate 2 armed.
make_plain_config_dir() {
    local d="$TMPDIR_BASE/cfg-$1"
    mkdir -p "$d"
    to_node_path "$d"
}

# Marker dir: adopted by resolveAgentsConfigDir(); bin/review-code-size is
# whatever this fixture puts there (or nothing at all).
make_marker_config_dir() {
    local d="$TMPDIR_BASE/cfg-$1"
    mkdir -p "$d/hooks" "$d/bin"
    echo "// stub marker" > "$d/hooks/enforce-worktree.js"
    to_node_path "$d"
}

# A separate git repo used as the "agents session repo" so that the repo being
# committed to is recognised as a DIFFERENT repo (cross-repo bypass).
make_foreign_git_config_dir() {
    local d="$TMPDIR_BASE/cfg-$1"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    git -C "$d" config core.hooksPath /dev/null
    echo "x" > "$d/README.md"
    git -C "$d" add README.md
    git -C "$d" commit -q -m "init"
    to_node_path "$d"
}

setup_repo() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" config core.autocrlf false
    mkdir -p "$repo/docs"
    echo "init" > "$repo/README.md"
    echo "doc" > "$repo/docs/notes.md"
    git -C "$repo" add README.md docs/notes.md
    git -C "$repo" commit -q -m "initial"
    to_node_path "$repo"
}

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

build_commit_payload() {
    local sid="$1" repo="$2" cmd_template="${3:-}"
    local cmd
    if [ -n "$cmd_template" ]; then cmd="$cmd_template"; else cmd="git -C $repo commit -m \"test\""; fi
    printf '{"session_id":%s,"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(json_quote "$sid")" "$(json_quote "$cmd")"
}

HOOK_OUT=""
HOOK_RC=0
# run_hook <payload> <wfdir> <cfgdir> [extra KEY=VALUE ...]
run_hook() {
    local payload="$1" wfdir="$2" cfg="$3"; shift 3
    HOOK_RC=0
    HOOK_OUT="$(printf '%s' "$payload" | run_with_timeout 60 \
        env -u CLAUDE_ENV_FILE -u CODE_FILE_EXTENSIONS \
        "AGENTS_CONFIG_DIR=$cfg" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "$@" \
        node "$HOOK_JS" 2>&1)" || HOOK_RC=$?
}

assert_approve() {
    local label="$1"
    if [ "$HOOK_RC" -ne 0 ]; then fail "$label: hook crashed rc=$HOOK_RC" "$HOOK_OUT"; return 1; fi
    if echo "$HOOK_OUT" | grep -q '"decision":"approve"'; then
        pass "$label"
    else
        fail "$label: expected approve" "$HOOK_OUT"
    fi
}

assert_block() {
    local label="$1" needle="${2:-}"
    if [ "$HOOK_RC" -ne 0 ]; then fail "$label: hook crashed rc=$HOOK_RC" "$HOOK_OUT"; return 1; fi
    if ! echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        fail "$label: expected block" "$HOOK_OUT"
        return 1
    fi
    if [ -n "$needle" ] && ! echo "$HOOK_OUT" | grep -qi -- "$needle"; then
        fail "$label: block reason missing '$needle'" "$HOOK_OUT"
        return 1
    fi
    pass "$label"
}

# ============================================================================
# Cases — sourced fragments (Pattern A split; rules/coding/file-split.md)
# ============================================================================
FRAGMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1701-workflow-gate-code-size"
# shellcheck source=tests/feature-1701-workflow-gate-code-size/gate-behavior.sh
. "$FRAGMENT_DIR/gate-behavior.sh"
# shellcheck source=tests/feature-1701-workflow-gate-code-size/infra-and-config.sh
. "$FRAGMENT_DIR/infra-and-config.sh"

run_all() {
    test_1_hard_limit_block
    test_2_ok_300_lines
    test_3_untracked_only_approves
    test_4_workflow_off_bypass
    test_5_wip_does_not_bypass
    test_6_cross_repo_bypass
    test_7_split_passes
    test_8_bash_missing_blocks
    test_9_script_missing_blocks
    test_10_unexpected_exit_blocks
    test_11_timeout_fail_open
    test_12_env_var_ignored
    test_13_env_from_dotenv
    test_14_no_dotenv
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_GATE2_E2E_INNER:-}" ]; then
        _GATE2_E2E_INNER=1 timeout 300 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
