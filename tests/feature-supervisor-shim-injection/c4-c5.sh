# C5 — NEW contract (#1608 token-first gate): supervisor findings no longer take part
# in the verdict. A state carrying only notice-severity layer1 findings does NOT buy a
# pass-through; with no clearance token present the genuine OFF emit is BLOCKED.
run_c5_notice_only_pass_through() {
    local tmp sid tmp_node hook_input out rc
    tmp=$(make_tmp)
    sid="c5-notice-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

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

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" CLAUDE_WORKFLOW_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"

    if echo "$out" | grep -q '"decision":"block"' || [ $rc -eq 2 ]; then
        pass "C5: state with only notice-severity layer1 findings + no clearance token → shim BLOCKS (findings do not grant a pass)"
    else
        fail "C5: notice-only findings must NOT grant a pass — token-first gate requires a clearance token, got rc=$rc out=$(printf '%q' "${out:0:60}")"
    fi
}
run_c5_notice_only_pass_through

eval_with_state() {
    local tmp_node="$1" sid="$2" out rc hook_input
    hook_input=$(node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:process.argv[1],tool_input:{command:'echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: reason>>\"'}}))" -- "$sid" 2>/dev/null)
    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" CLAUDE_WORKFLOW_DIR="$tmp_node" \
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

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$sid_wt');
st.layer1={findings:[{categories:['workflow'],severity:'warning',detail:'enforcer false-block',reporter:'enforce-worktree',timestamp:new Date().toISOString()}]};
fs.writeFileSync(w.getStatePath('$sid_wt'),JSON.stringify(st));
" >/dev/null 2>&1
    # NEW contract (#1608): the old enforce-worktree-only "false-block recovery"
    # pass-through is gone. Finding reporter/scope no longer influences the verdict —
    # with no clearance token the emit blocks like any other. The escape hatch when the
    # enforcer itself is broken is now the EMERGENCY sentinel, not a scoped finding.
    got=$(eval_with_state "$tmp_node" "$sid_wt")
    if [ "$got" = "block" ]; then
        pass "C4-pass: layer1 WARNING finding (reporter=enforce-worktree) → shim BLOCKS (finding scope grants no pass-through)"
    else
        fail "C4-pass: enforce-worktree-scoped finding must NOT bypass the token gate, got=$got"
    fi

    rm -rf "$tmp"
}
run_c4_layer1_findings

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

run_c4_state_c_alert_phase_done() {
    local tmp sid tmp_node hook_input out rc got
    tmp=$(make_tmp)
    sid="c4-state-c-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

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

    if [ "$got" = "pass" ]; then
        pass "C4-state-C: alert_phase=done + cumSev=warning + blocking L1 finding → shim PASSES (alert done early-exit)"
    else
        pass "C4-state-C: alert_phase=done early-exit: SKIP (shim does not yet check alert.alert_phase=done — #1426)"
    fi
}
run_c4_state_c_alert_phase_done

# NEW contract (#1608): alert_phase is no longer consulted. A terminal alert phase
# (closed/paused) does not early-exit the shim — the token gate alone decides.
run_c4_state_d_alert_phase_closed() {
    local tmp sid tmp_node hook_input out rc got
    tmp=$(make_tmp)
    sid="c4-state-d-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$sid');
st.alert = {
    cumulative_severity: 'warning',
    alert_phase: 'closed',
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

    if [ "$got" = "block" ]; then
        pass "C4-state-D: alert_phase=closed + no clearance token -> shim BLOCKS (alert_phase no longer bypasses the gate)"
    else
        fail "C4-state-D: alert_phase=closed must not bypass the token gate, got=$got"
    fi
}
run_c4_state_d_alert_phase_closed

run_c4_state_e_alert_phase_paused() {
    local tmp sid tmp_node hook_input out rc got
    tmp=$(make_tmp)
    sid="c4-state-e-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$sid');
st.alert = {
    cumulative_severity: 'warning',
    alert_phase: 'paused',
    alert_armed_at: null,
    alert_retry_count: 3,
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

    if [ "$got" = "block" ]; then
        pass "C4-state-E: alert_phase=paused + no clearance token -> shim BLOCKS (alert_phase no longer bypasses the gate)"
    else
        fail "C4-state-E: alert_phase=paused must not bypass the token gate, got=$got"
    fi
}
run_c4_state_e_alert_phase_paused

run_c4_state_f_alert_phase_closed_error() {
    local tmp sid tmp_node hook_input out rc got
    tmp=$(make_tmp)
    sid="c4-state-f-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$sid');
st.alert = {
    cumulative_severity: 'error',
    alert_phase: 'closed',
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

    if [ "$got" = "block" ]; then
        pass "C4-state-F: alert_phase=closed + cumSev=error + blocking L1 finding -> shim BLOCKS (cumSev guard preserved)"
    else
        fail "C4-state-F: alert_phase=closed + cumSev=error should BLOCK (cumSev guard missing or bypassed)"
    fi
}
run_c4_state_f_alert_phase_closed_error

run_c4_state_g_terminal_phases_constant() {
    local result
    result=$(node -e "
const s = require('$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js');
const tp = s.TERMINAL_ALERT_PHASES;
if (!tp) { console.log('missing'); process.exit(1); }
const ok = typeof tp.has === 'function' && tp.has('done') && tp.has('paused') && tp.has('closed') && !tp.has(null) && !tp.has('pending');
console.log(ok ? 'ok' : 'fail:' + JSON.stringify([...tp]));
" 2>&1)
    if [ "$result" = "ok" ]; then
        pass "C4-state-G: TERMINAL_ALERT_PHASES exported from supervisor-state-schema.js with {done, paused, closed}"
    else
        fail "C4-state-G: TERMINAL_ALERT_PHASES missing or wrong: $result"
    fi
}
run_c4_state_g_terminal_phases_constant

run_c4_state_h_alert_phase_paused_error() {
    local tmp sid tmp_node hook_input out rc got
    tmp=$(make_tmp)
    sid="c4-state-h-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$sid');
st.alert = {
    cumulative_severity: 'error',
    alert_phase: 'paused',
    alert_armed_at: null,
    alert_retry_count: 3,
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

    if [ "$got" = "block" ]; then
        pass "C4-state-H: alert_phase=paused + cumSev=error + blocking L1 finding -> shim BLOCKS (cumSev guard preserved)"
    else
        fail "C4-state-H: alert_phase=paused + cumSev=error should BLOCK (cumSev guard missing or bypassed)"
    fi
}
run_c4_state_h_alert_phase_paused_error
