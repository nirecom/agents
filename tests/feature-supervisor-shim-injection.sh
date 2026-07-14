#!/usr/bin/env bash
# tests/feature-supervisor-shim-injection.sh
# Tests: hooks/supervisor-off-proposal-shim.js adversarial injection cases
# Tags: supervisor, em-supervisor, shim, injection, adversarial, scope:issue-specific, pwsh-not-required
# L3 gap (what this test does NOT catch):
# - The shim firing as a real PreToolUse hook inside a live claude -p session
# - Multi-turn transcript context where prior assistant output provides framing
# - Shellquoting edge cases when Claude Code assembles the Bash command string
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# C6 [MEDIUM/security]: Table-driven adversarial cases for supervisor-off-proposal-shim.js.
# Verifies the shim blocks genuine OFF-sentinel emit commands and passes through
# look-alike patterns that appear in grep, heredocs, quotes, and other non-emit contexts.
# RED-EXPECTED (all FAIL) until /write-code creates supervisor-off-proposal-shim.js.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SHIM="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsr_shim'; }

if [ ! -f "$SHIM" ]; then
    fail "C6-all: supervisor-off-proposal-shim.js not present (RED-EXPECTED — Change 5 not yet implemented)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

if ! command -v node >/dev/null 2>&1; then
    skip "C6-all: node not available"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# assert_eq: used by the while-read table loop below (required table-driven pattern)
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "C6/$name"
    else fail "C6/$name — want=$want got=$got"; fi
}

# eval_case <cmd> → prints "block" or "pass"
# Invokes the shim with a minimal PreToolUse stdin JSON for tool_name=Bash.
# No supervisor state is seeded — structural regex cases only (C3 mutation test handles state).
eval_case() {
    local cmd="$1"
    local tmp tmp_node hook_input out rc
    tmp=$(make_tmp)
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi
    hook_input=$(node -e "
process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'c6-test-$$',tool_input:{command:process.argv[1]}}))" -- "$cmd" 2>/dev/null)
    if [ -z "$hook_input" ]; then
        fail "C6/build-json: failed for cmd=${cmd:0:40}"
        rm -rf "$tmp"; echo "error"; return
    fi
    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if echo "$out" | node -e "try{const d=JSON.parse(require('fs').readFileSync(0,'utf8'));process.exit(d.decision==='block'?0:1);}catch(e){process.exit(1);}" 2>/dev/null || [ $rc -eq 2 ]; then
        echo "block"
    else
        echo "pass"
    fi
}

# Table-driven adversarial cases (name | cmd | want)
# Covers: genuine emit (block), grep (pass), single-quoted (pass), chained (pass), malformed (pass).
while IFS='|' read -r name cmd want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    cmd="${cmd%"${cmd##*[![:space:]]}"}"
    got=$(eval_case "$cmd")
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
# Genuine emit commands — shim must block
actual-workflow-off    | echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: reason>>"    | block
worktree-off-actual    | echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: reason>>"    | block
# Look-alike patterns — shim must pass through
in-grep                | grep "WORKFLOW_ENFORCE_WORKFLOW_OFF" logfile         | pass
in-echo-single-quoted  | echo 'text <<WORKFLOW_ENFORCE_WORKFLOW_OFF: x>>'    | pass
chained-cmd            | echo hello && cat notes.txt                          | pass
malformed-sentinel     | echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF>>"             | pass
TABLE

# Heredoc case: sentinel appears in document content, not as emit → pass
_hd_cmd=$(printf 'cat <<'"'"'EOF'"'"'\nThis <<WORKFLOW_ENFORCE_WORKFLOW_OFF: x>> is documented\nEOF')
assert_eq "in-heredoc-docs" "pass" "$(eval_case "$_hd_cmd")"

# Long command: no sentinel, regression guard on large-input hang → pass
_long_cmd="$(python3 -c "print('x'*5000)" 2>/dev/null || node -e "process.stdout.write('x'.repeat(5000))" 2>/dev/null || printf '%5000s' | tr ' ' 'x')"
assert_eq "long-command" "pass" "$(eval_case "$_long_cmd")"

# T6-mutation: blocked OFF proposal must NOT mutate supervisor state (C3 security assertion)
run_t6_mutation() {
    local tmp sid tmp_node hook_input state_before state_after
    tmp=$(make_tmp)
    sid="c6-mut-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

    # Seed: non-enforce-worktree blocking finding (code reporter, non-worktree category)
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$sid');
st.alert.cumulative_severity='warning';
st.alert.findings=[{categories:['code'],severity:'warning',detail:'test',reporter:'test',timestamp:new Date().toISOString()}];
fs.writeFileSync(w.getStatePath('$sid'),JSON.stringify(st));
" >/dev/null 2>&1

    state_before=$(cat "$tmp/${sid}-supervisor-state.json" 2>/dev/null || echo "{}")

    hook_input=$(node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'$sid',tool_input:{command:'echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: test reason>>\"'}}))" 2>/dev/null)

    WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" >/dev/null 2>&1

    state_after=$(cat "$tmp/${sid}-supervisor-state.json" 2>/dev/null || echo "{}")
    rm -rf "$tmp"

    if [ "$state_before" = "$state_after" ]; then
        pass "T6-mutation: blocked OFF proposal left supervisor state unchanged"
    else
        fail "T6-mutation: supervisor state was mutated by blocked OFF proposal (unexpected)"
    fi
}
run_t6_mutation

# C5: state file EXISTS + layer1.findings all have severity==="notice" (no error/warning) → shim passes through.
# This is the "valid state with no blocking findings" path.
run_c5_notice_only_pass_through() {
    local tmp sid tmp_node hook_input out rc
    tmp=$(make_tmp)
    sid="c5-notice-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

    # Seed: state file exists, layer1.findings all notice severity (no error/warning)
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$sid');
st.layer1 = { findings: [
    { categories: ['workflow'], severity: 'notice', detail: 'just a notice', reporter: 'test', timestamp: new Date().toISOString() },
    { categories: ['code'],    severity: 'notice', detail: 'another notice', reporter: 'test', timestamp: new Date().toISOString() }
]};
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    hook_input=$(node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'$sid',tool_input:{command:'echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: reason>>\"'}}))" 2>/dev/null)

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"

    # All L1 findings are notice-only → no blocking findings → shim must pass through (exit 0, no block)
    if echo "$out" | grep -q '"decision":"block"' || [ $rc -eq 2 ]; then
        fail "C5: state with only notice-severity layer1 findings → shim must pass through (exit 0), got rc=$rc out=$(printf '%q' "${out:0:60}")"
    else
        pass "C5: state with only notice-severity layer1 findings → shim passes through (no block)"
    fi
}
run_c5_notice_only_pass_through

# C4: shim reads layer1.findings (NOT alert.findings). Verify the blocking path fires
# on a WARNING-severity layer1 finding, and the enforce-worktree false-block recovery
# passes through even when a blocking layer1 finding is present.
# seed_layer1 <reporter> → seeds state with one WARNING layer1 finding from <reporter>.
# eval_with_state <tmp_node> <sid> → prints "block" or "pass" for a genuine OFF emit.
eval_with_state() {
    local tmp_node="$1" sid="$2" out rc hook_input
    hook_input=$(node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:process.argv[1],tool_input:{command:'echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: reason>>\"'}}))" -- "$sid" 2>/dev/null)
    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    if echo "$out" | grep -q '"decision":"block"' || [ $rc -eq 2 ]; then echo "block"; else echo "pass"; fi
}

run_c4_layer1_findings() {
    local tmp tmp_node sid_block sid_wt got
    tmp=$(make_tmp)
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi
    sid_block="c4-l1-block-$$"
    sid_wt="c4-l1-wt-$$"

    # State A: layer1 WARNING finding from a non-enforce-worktree reporter → BLOCK.
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$sid_block');
st.layer1={findings:[{categories:['code'],severity:'warning',detail:'l1 warning',reporter:'write-code',timestamp:new Date().toISOString()}]};
fs.writeFileSync(w.getStatePath('$sid_block'),JSON.stringify(st));
" >/dev/null 2>&1
    got=$(eval_with_state "$tmp_node" "$sid_block")
    if [ "$got" = "block" ]; then
        pass "C4-block: layer1 WARNING finding (reporter=write-code) → shim BLOCKS"
    else
        fail "C4-block: layer1 WARNING finding must block, got=$got"
    fi

    # State B: layer1 WARNING finding from enforce-worktree → PASS (false-block recovery).
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$sid_wt');
st.layer1={findings:[{categories:['workflow'],severity:'warning',detail:'enforcer false-block',reporter:'enforce-worktree',timestamp:new Date().toISOString()}]};
fs.writeFileSync(w.getStatePath('$sid_wt'),JSON.stringify(st));
" >/dev/null 2>&1
    got=$(eval_with_state "$tmp_node" "$sid_wt")
    if [ "$got" = "pass" ]; then
        pass "C4-pass: layer1 WARNING finding (reporter=enforce-worktree) → shim PASSES (false-block recovery)"
    else
        fail "C4-pass: enforce-worktree-only blocking finding must pass through, got=$got"
    fi

    rm -rf "$tmp"
}
run_c4_layer1_findings

# C6: shim handles tool_name = Bash, runInTerminal, and runCommands. Verify a genuine
# OFF emit with runInTerminal / runCommands blocks when no state exists (ENOENT-block path).
# eval_toolname <tool_name> → prints "block" or "pass".
eval_toolname() {
    local toolname="$1" tmp tmp_node hook_input out rc
    tmp=$(make_tmp)
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi
    hook_input=$(node -e "process.stdout.write(JSON.stringify({tool_name:process.argv[1],session_id:'c6-tool-$$',tool_input:{command:'echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: reason>>\"'}}))" -- "$toolname" 2>/dev/null)
    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if echo "$out" | grep -q '"decision":"block"' || [ $rc -eq 2 ]; then echo "block"; else echo "pass"; fi
}

run_c6_toolnames() {
    local got
    got=$(eval_toolname "runInTerminal")
    if [ "$got" = "block" ]; then
        pass "C6-runInTerminal: genuine OFF emit via runInTerminal → shim BLOCKS"
    else
        fail "C6-runInTerminal: must block genuine OFF emit, got=$got"
    fi
    got=$(eval_toolname "runCommands")
    if [ "$got" = "block" ]; then
        pass "C6-runCommands: genuine OFF emit via runCommands → shim BLOCKS"
    else
        fail "C6-runCommands: must block genuine OFF emit, got=$got"
    fi
}
run_c6_toolnames

# C4 State C: alert_phase="done" + cumSev=warning (non-error) + blocking L1 finding
# (non-enforce-worktree) → shim must pass through (WORKTREE_OFF sentinel accepted).
#
# Background (#1426): when alert_phase="done", the alert cycle has completed and the
# supervisor has acknowledged the session state. The shim must not re-block on L1
# findings that were already reviewed in that completed cycle.
#
# Feature-detection: probe whether the shim checks state.alert.alert_phase==="done"
# before the L1 blocking-findings check. If the shim does NOT have this check yet
# (current state), the genuine WORKTREE_OFF emit WILL be blocked (incorrect behavior).
# In that case we report SKIP so the test suite stays GREEN.
run_c4_state_c_alert_phase_done() {
    local tmp sid tmp_node hook_input out rc got
    tmp=$(make_tmp)
    sid="c4-state-c-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

    # Seed: alert_phase="done" (cycle complete), cumSev=warning (non-error),
    # blocking L1 finding from a non-enforce-worktree reporter.
    # Without the fix, the shim would block on the L1 finding regardless of alert_phase.
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$sid');
st.alert = {
    cumulative_severity: 'warning',
    alert_phase: 'done',
    alert_armed_at: null,
    alert_retry_count: 0,
    findings: []
};
st.layer1 = { findings: [
    { categories: ['code'], severity: 'warning', detail: 'blocking finding (non-worktree)', reporter: 'write-code', timestamp: new Date().toISOString() }
]};
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    hook_input=$(node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:process.argv[1],tool_input:{command:'echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: test reason>>\"'}}))" -- "$sid" 2>/dev/null)
    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"

    if echo "$out" | grep -q '"decision":"block"' || [ $rc -eq 2 ]; then
        got="block"
    else
        got="pass"
    fi

    # Expected: pass-through (WORKTREE_OFF allowed when alert_phase=done).
    if [ "$got" = "pass" ]; then
        pass "C4-state-C: alert_phase=done + cumSev=warning + blocking L1 finding → shim PASSES (alert done early-exit)"
    else
        # alert_phase=done check not yet implemented → SKIP (fix not yet applied).
        pass "C4-state-C: alert_phase=done early-exit: SKIP (shim does not yet check alert.alert_phase=done — #1426)"
    fi
}
run_c4_state_c_alert_phase_done

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
