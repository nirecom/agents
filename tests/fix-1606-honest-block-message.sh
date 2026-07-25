#!/usr/bin/env bash
# tests/fix-1606-honest-block-message.sh
# Tests: hooks/supervisor-off-proposal-shim.js
# Tags: supervisor, off-proposal, shim, honest-message, buildReason, scope:issue-specific, pwsh-not-required, TL1
#
# #1606: on a fresh session with NO supervisor state file (ENOENT), the OFF block
# message must NOT claim "Active supervisor findings exist" — there are none. It must
# honestly say the OFF requires a clearance token via bin/request-off-clearance (the
# reason is "examination not yet completed", not "findings present"). When a state
# file DOES exist, findings are still not the block reason under the token-first gate.
# The isWtEnd (worktree-end cleanup) branch message is preserved (non-regression).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
SHIM="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'honest'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

OFF='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: [workflow-bug] cannot proceed>>"'

run_shim() {  # <tmp_node> <sid> → prints "rc|<stdout>"
    local tn="$1" sid="$2" hook_input out rc
    hook_input=$("$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'$sid',tool_input:{command:process.argv[1]}}))" "$OFF")
    out=$(WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$tn" "$RWT" 12 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

mentions_findings() { echo "$1" | grep -qi 'Active supervisor findings exist'; }
mentions_clearance() { echo "$1" | grep -qiE 'request-off-clearance|clearance token|examination'; }

# ===== C1: ENOENT (no state) + genuine emit + no token → honest message =====
run_C1() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")   # no state file, no token
    r=$(run_shim "$tn" "c1sid"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" != "2" ]; then
        fail "C1: precondition — genuine OFF without token must block (rc=$rc)"
        return
    fi
    if ! mentions_findings "$out"; then
        pass "C1a: ENOENT block message does NOT falsely claim 'Active supervisor findings exist'"
    else
        fail "C1a: RED-EXPECTED (misleading message live): ENOENT block still claims findings exist; out=$out"
    fi
    if mentions_clearance "$out"; then
        pass "C1b: ENOENT block message points at bin/request-off-clearance / examination"
    else
        fail "C1b: RED-EXPECTED: ENOENT block message missing clearance guidance; out=$out"
    fi
}

# ===== C2: state file present WITH findings + no token → findings not the block reason =====
run_C2() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    WORKFLOW_PLANS_DIR="$tn" "$RWT" 10 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('c2sid');
st.layer1.findings=[{categories:['code'],severity:'error',detail:'x',reporter:'workflow-gate',timestamp:new Date().toISOString()}];
fs.writeFileSync(w.getStatePath('c2sid'),JSON.stringify(st));" >/dev/null 2>&1
    r=$(run_shim "$tn" "c2sid"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" != "2" ]; then
        fail "C2: precondition — no token must block (rc=$rc)"
        return
    fi
    if ! mentions_findings "$out" && mentions_clearance "$out"; then
        pass "C2: state-present block cites clearance token, not findings, as the reason"
    else
        fail "C2: RED-EXPECTED: state-present block still cites findings / lacks clearance guidance; out=$out"
    fi
}

# ===== C3: isWtEnd branch message preserved (non-regression) =====
run_C3() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    : > "$tmp/c3sid-wt-cleanup-active"   # trigger isWtEnd
    r=$(run_shim "$tn" "c3sid"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if echo "$out" | grep -qiE 'sweep-worktrees|WE-16|worktree-end'; then
        pass "C3: worktree-end cleanup (isWtEnd) block message preserved"
    else
        fail "C3: isWtEnd branch message regressed; rc=$rc out=$out"
    fi
}

run_C1
run_C2
run_C3

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
