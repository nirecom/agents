#!/bin/bash
# tests/feature-workflow-gate-unstaged-tracked.sh
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/staged-evidence.js
# Tags: workflow-gate, hook, gate1, unstaged-tracked, git, bin
#
# E2E tests for Gate 1 — workflow-gate.js must block git commit when the
# working tree has unstaged tracked-file modifications.
# Expected red until #269 lands.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_JS="${_AGENTS_DIR_NODE}/hooks/workflow-gate.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'gate1-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_hook() {
    if [ ! -f "$HOOK_JS" ]; then
        fail "$1 (hooks/workflow-gate.js not present)"
        return 1
    fi
    return 0
}

fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

# Write a workflow state file with every VALID_STEPS entry marked complete.
write_complete_state() {
    local wfdir="$1" sid="$2"
    node -e "
const fs = require('fs');
const path = require('path');
const { VALID_STEPS } = require('$_AGENTS_DIR_NODE/hooks/lib/workflow-state.js');
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

write_worktree_off_marker() {
    local wfdir="$1" sid="$2"
    printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$wfdir/$sid.worktree-off"
}

# Build repo with one already-tracked code file `app.js` (committed).
setup_repo() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    echo "src" > "$repo/app.js"
    git -C "$repo" add README.md app.js
    git -C "$repo" commit -q -m "initial"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

build_commit_payload() {
    local sid="$1" repo="$2" cmd_template="${3:-}"
    local q_sid q_cmd cmd
    if [ -n "$cmd_template" ]; then
        cmd="$cmd_template"
    else
        cmd="git -C $repo commit -m \"test\""
    fi
    q_sid="$(json_quote "$sid")"
    q_cmd="$(json_quote "$cmd")"
    printf '{"session_id":%s,"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$q_sid" "$q_cmd"
}

HOOK_OUT=""
HOOK_RC=0
run_hook() {
    local payload="$1" wfdir="$2"
    HOOK_RC=0
    HOOK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$HOOK_JS" 2>&1)" || HOOK_RC=$?
}

# ============================================================================
# Tests
# ============================================================================

# A. baseline clean: workflow state complete + staged code only, no unstaged
test_A_baseline_clean_approves() {
    require_hook "A" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate1AAA"
    local repo; repo="$(setup_repo "a-repo")"
    write_complete_state "$wfdir" "$sid"
    # Edit + stage app.js; nothing left unstaged.
    echo "edit" >> "$repo/app.js"
    git -C "$repo" add app.js
    local payload; payload="$(build_commit_payload "$sid" "$repo")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "A: hook crashed rc=$HOOK_RC" "$HOOK_OUT"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"approve"'; then
        pass "A: baseline clean → approve"
    else
        fail "A: expected approve, got" "$HOOK_OUT"
    fi
}

# B. unstaged tracked code file present + workflow state complete → block
test_B_unstaged_tracked_blocks() {
    require_hook "B" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate1BBB"
    local repo; repo="$(setup_repo "b-repo")"
    write_complete_state "$wfdir" "$sid"
    # Stage README.md change, leave app.js unstaged.
    echo "doc-edit" >> "$repo/README.md"
    git -C "$repo" add README.md
    echo "unstaged-edit" >> "$repo/app.js"
    local payload; payload="$(build_commit_payload "$sid" "$repo")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "B: hook crashed rc=$HOOK_RC" "$HOOK_OUT"
        return
    fi
    if ! echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        fail "B: expected block (gate1 fires)" "$HOOK_OUT"
        return
    fi
    if ! echo "$HOOK_OUT" | grep -q 'tracked-file modifications were not staged'; then
        fail "B: expected reason to mention tracked-file modifications were not staged" "$HOOK_OUT"
        return
    fi
    pass "B: unstaged tracked code → block with gate1 reason"
}

# C. WIP commit form skips Gate 1
test_C_wip_skips_gate1() {
    require_hook "C" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate1CCC"
    local repo; repo="$(setup_repo "c-repo")"
    write_complete_state "$wfdir" "$sid"
    echo "doc-edit" >> "$repo/README.md"
    git -C "$repo" add README.md
    echo "unstaged-edit" >> "$repo/app.js"
    # NOTE: -c MUST come before the `commit` subcommand verb.
    local payload; payload="$(build_commit_payload "$sid" "$repo" \
        "git -C $repo -c workflow.wip=1 commit -m \"wip\"")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "C: hook crashed rc=$HOOK_RC" "$HOOK_OUT"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"approve"'; then
        pass "C: WIP commit skips gate1 → approve"
    else
        fail "C: expected approve under WIP (gate1 must skip when isWip)" "$HOOK_OUT"
    fi
}

# D. docs-only staged (README.md) + unstaged tracked code → still blocked
#    (Gate 1 must fire regardless of docs-only short-circuit.)
test_D_docs_only_does_not_skip_gate1() {
    require_hook "D" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate1DDD"
    local repo; repo="$(setup_repo "d-repo")"
    write_complete_state "$wfdir" "$sid"
    # Only README.md is staged (docs-only). app.js is unstaged tracked.
    echo "doc-edit" >> "$repo/README.md"
    git -C "$repo" add README.md
    echo "unstaged-edit" >> "$repo/app.js"
    local payload; payload="$(build_commit_payload "$sid" "$repo")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "D: hook crashed rc=$HOOK_RC" "$HOOK_OUT"
        return
    fi
    if ! echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        fail "D: expected block — gate1 must NOT be skipped by docs-only" "$HOOK_OUT"
        return
    fi
    if ! echo "$HOOK_OUT" | grep -q 'tracked-file modifications were not staged'; then
        fail "D: expected gate1 reason" "$HOOK_OUT"
        return
    fi
    pass "D: docs-only staged + unstaged tracked → still blocked by gate1"
}

# E. WORKFLOW_OFF marker present → approve (early-return; no state needed)
test_E_workflow_off_approves() {
    require_hook "E" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate1EEE"
    local repo; repo="$(setup_repo "e-repo")"
    write_workflow_off_marker "$wfdir" "$sid"
    # Leave app.js modified (unstaged) so that without bypass, gate1 would fire.
    echo "edit" >> "$repo/app.js"
    local payload; payload="$(build_commit_payload "$sid" "$repo")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "E: hook crashed rc=$HOOK_RC" "$HOOK_OUT"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"approve"'; then
        pass "E: WORKFLOW_OFF marker → approve (early-return)"
    else
        fail "E: expected approve via workflow-off early-return" "$HOOK_OUT"
    fi
}

# F. WORKTREE_OFF marker + unstaged file → Gate 1 bypassed, approve
#    (WORKTREE_OFF is NOT a global early-return; it only skips Gate 1.
#     Other gates are still active — workflow state must be complete.)
test_F_worktree_off_bypasses_gate1() {
    require_hook "F" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate1FFF"
    local repo; repo="$(setup_repo "f-repo")"
    write_complete_state "$wfdir" "$sid"
    write_worktree_off_marker "$wfdir" "$sid"
    # Leave app.js unstaged — Gate 1 would block without WORKTREE_OFF.
    echo "edit" >> "$repo/app.js"
    local payload; payload="$(build_commit_payload "$sid" "$repo")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "F: hook crashed rc=$HOOK_RC" "$HOOK_OUT"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"approve"'; then
        pass "F: WORKTREE_OFF + unstaged file → approve (Gate 1 bypassed, state complete)"
    else
        fail "F: expected approve via worktree-off Gate 1 bypass" "$HOOK_OUT"
    fi
}

run_all() {
    test_A_baseline_clean_approves
    test_B_unstaged_tracked_blocks
    test_C_wip_skips_gate1
    test_D_docs_only_does_not_skip_gate1
    test_E_workflow_off_approves
    test_F_worktree_off_bypasses_gate1
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_GATE1_E2E_INNER:-}" ]; then
        _GATE1_E2E_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
