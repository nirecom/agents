# tests/feature-719-supervisor-guard-hook/cases-g20-g28.sh
# G20-G28: #912 + #914 + #903 — L2 retry threshold, AskUserQuestion gate,
# WORKTREE_OFF proposal trigger (C3 branch). Verbatim from original entrypoint.

# Probes whether the writer module exposes incrementL2RetryCount (i.e. l2_retry_count
# infrastructure has been implemented). Used to skip cleanly until source lands.
require_increment_l2_retry() {
    local label="$1"
    local probe
    probe=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
process.stdout.write(typeof w.incrementL2RetryCount === 'function' ? 'yes' : 'no');
" 2>/dev/null)
    if [ "$probe" != "yes" ]; then
        skip "$label (incrementL2RetryCount not implemented yet)"; return 1
    fi
    return 0
}

# Probes whether the formatter accepts the (findings, sid, wsid, supervisorPath, stateFilePath)
# arity AND produces the new fallback-recipe block. Used to skip cleanly until source lands.
require_recipe_block_format() {
    local label="$1"
    local probe
    probe=$(run_with_timeout 5 node -e "
const f = require('$_AGENTS_DIR_NODE/hooks/lib/supervisor-report-format');
const out = f.formatCumSevErrorReason([], 'probe-sid', 'probe-wsid', 'agents/supervisor.md', '/tmp/probe-state.json');
process.stdout.write(out.indexOf('supervisor-write-layer2') >= 0 ? 'yes' : 'no');
" 2>/dev/null)
    if [ "$probe" != "yes" ]; then
        skip "$label (recipe-block formatter arity not implemented yet)"; return 1
    fi
    return 0
}

seed_state_with_retry() {
    local tmp="$1" sid="$2" layer2_json="$3" retry_count="$4"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.layer2 = Object.assign({}, $layer2_json, { l2_retry_count: $retry_count });
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

# G20 — branch(2) cumSev=error AND l2_retry_count already at threshold (2)
#       -> auto-freeze, no block emitted, exit 0
run_g20() {
    require_source "$HOOK" "G20: branch(2) cumSev=error + retry at threshold -> no block, exit 0" || return
    require_increment_l2_retry "G20: branch(2) cumSev=error + retry at threshold -> no block, exit 0" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state_with_retry "$tmp" "g20-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [] }" 2
    out=$(echo '{"stop_hook_active":false,"session_id":"g20-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -qi "\"decision\":\"block\"" ); then
        pass "G20: branch(2) cumSev=error + retry at threshold -> no block, exit 0"
    else
        fail "G20: branch(2) cumSev=error + retry at threshold -> no block, exit 0 (rc=$rc, out=$out)"
    fi
}

# G21 — branch(3) l2_armed_at + retry at threshold -> no block, exit 0
run_g21() {
    require_source "$HOOK" "G21: branch(3) l2_armed_at + retry at threshold -> no block, exit 0" || return
    require_increment_l2_retry "G21: branch(3) l2_armed_at + retry at threshold -> no block, exit 0" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state_with_retry "$tmp" "g21-sid" "{ l2_armed_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }" 2
    out=$(echo '{"stop_hook_active":false,"session_id":"g21-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -qi "\"decision\":\"block\"" ); then
        pass "G21: branch(3) l2_armed_at + retry at threshold -> no block, exit 0"
    else
        fail "G21: branch(3) l2_armed_at + retry at threshold -> no block, exit 0 (rc=$rc, out=$out)"
    fi
}

# G22 — branch(3) fires; first invocation emits block; second invocation crosses threshold
run_g22() {
    require_source "$HOOK" "G22: branch(3) first->block, second->cross threshold no block" || return
    require_increment_l2_retry "G22: branch(3) first->block, second->cross threshold no block" || return
    local tmp out1 rc1 out2 rc2
    tmp="$(mktemp -d)"
    seed_state_with_retry "$tmp" "g22-sid" "{ l2_armed_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }" 0
    out1=$(echo '{"stop_hook_active":false,"session_id":"g22-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc1=$?
    # Second invocation: state still has l2_armed_at, retry_count should have been incremented to 1
    out2=$(echo '{"stop_hook_active":false,"session_id":"g22-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc2=$?
    rm -rf "$tmp"
    if [ $rc1 -eq 2 ] && ( echo "$out1" | grep -qi "block" ) && [ $rc2 -eq 0 ]; then
        pass "G22: branch(3) first->block, second->cross threshold no block (rc1=$rc1, rc2=$rc2)"
    else
        fail "G22: branch(3) first->block, second->cross threshold no block (rc1=$rc1, out1=$out1, rc2=$rc2, out2=$out2)"
    fi
}

# G23 — transcript with AskUserQuestion tool_use as last assistant tool -> no block from (2) or (3)
run_g23() {
    require_source "$HOOK" "G23: AskUserQuestion last tool_use -> no block, exit 0" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"q"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"AskUserQuestion","input":{"question":"?"}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state "$tmp" "g23-sid" "{ l2_armed_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: 'error', findings: [] }"
    out=$(printf '{"stop_hook_active":false,"session_id":"g23-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -qi "\"decision\":\"block\"" ); then
        pass "G23: AskUserQuestion last tool_use -> no block, exit 0"
    else
        fail "G23: AskUserQuestion last tool_use -> no block, exit 0 (rc=$rc, out=$out)"
    fi
}

# G24 — same transcript but no AskUserQuestion -> block emitted (regression guard)
run_g24() {
    require_source "$HOOK" "G24: no AskUserQuestion in transcript -> block emitted" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"q"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state "$tmp" "g24-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [] }"
    out=$(printf '{"stop_hook_active":false,"session_id":"g24-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && ( echo "$out" | grep -qi "block" ); then
        pass "G24: no AskUserQuestion in transcript -> block emitted"
    else
        fail "G24: no AskUserQuestion in transcript -> block emitted (rc=$rc, out=$out)"
    fi
}

# G25 — transcript with Bash tool_use containing WORKFLOW_ENFORCE_WORKTREE_OFF proposal
#       -> C3 branch fires, decision:block, exit 2
run_g25() {
    require_source "$HOOK" "G25: C3 worktree-off proposal -> decision:block, exit 2" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"q"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: temporary>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state "$tmp" "g25-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(printf '{"stop_hook_active":false,"session_id":"g25-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && ( echo "$out" | grep -qi "block" ); then
        pass "G25: C3 worktree-off proposal -> decision:block, exit 2"
    else
        fail "G25: C3 worktree-off proposal -> decision:block, exit 2 (rc=$rc, out=$out)"
    fi
}

# G26 — same as G25 but retry count at threshold -> auto-freeze, no block, exit 0
run_g26() {
    require_source "$HOOK" "G26: C3 + retry at threshold -> auto-freeze, no block" || return
    require_increment_l2_retry "G26: C3 + retry at threshold -> auto-freeze, no block" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"q"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: t>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state_with_retry "$tmp" "g26-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [] }" 2
    out=$(printf '{"stop_hook_active":false,"session_id":"g26-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -qi "\"decision\":\"block\"" ); then
        pass "G26: C3 + retry at threshold -> auto-freeze, no block"
    else
        fail "G26: C3 + retry at threshold -> auto-freeze, no block (rc=$rc, out=$out)"
    fi
}

# G27 — AskUserQuestion-turn AND C3 trigger both present -> AskUserQuestion gate wins, no block
run_g27() {
    require_source "$HOOK" "G27: AskUserQuestion + C3 trigger -> gate wins, no block" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"q"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: t>>\""}},{"type":"tool_use","id":"tu2","name":"AskUserQuestion","input":{"question":"?"}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state "$tmp" "g27-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(printf '{"stop_hook_active":false,"session_id":"g27-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -qi "\"decision\":\"block\"" ); then
        pass "G27: AskUserQuestion + C3 trigger -> gate wins, no block"
    else
        fail "G27: AskUserQuestion + C3 trigger -> gate wins, no block (rc=$rc, out=$out)"
    fi
}

# G28 — branch(2) block reason contains resolved stateFilePath (guard passes new arg to formatter)
run_g28() {
    require_source "$HOOK" "G28: branch(2) block reason includes stateFilePath" || return
    require_recipe_block_format "G28: branch(2) block reason includes stateFilePath" || return
    local tmp out rc state_path
    tmp="$(mktemp -d)"
    seed_state "$tmp" "g28-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [{\"categories\":[\"workflow\"],\"severity\":\"error\",\"detail\":\"d\",\"timestamp\":\"2026-06-06T12:00:00.000Z\"}] }"
    # Resolve what stateFilePath value the guard should be using
    state_path=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
process.stdout.write(w.getStatePath('g28-sid'));
" 2>/dev/null)
    out=$(echo '{"stop_hook_active":false,"session_id":"g28-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    # Check for presence of g28-sid-supervisor-state.json fragment in output
    if [ $rc -eq 2 ] && ( echo "$out" | grep -q "g28-sid-supervisor-state.json" ); then
        pass "G28: branch(2) block reason includes stateFilePath"
    else
        fail "G28: branch(2) block reason includes stateFilePath (rc=$rc, expected_path=$state_path, out=$out)"
    fi
}

# G29 — no WORKTREE_OFF sentinel in transcript -> C3 not armed, exit 0
run_g29() {
    require_source "$HOOK" "G29: no OFF sentinel -> C3 not fired, exit 0" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    # Plain transcript: only Bash with a regular command, no WORKTREE_OFF
    tp="$(node_path "$tmp/t.jsonl")"
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo hello"}}]}}' > "$tmp/t.jsonl"
    seed_state "$tmp" "g29-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null, l2_retry_count: 0 }"
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"g29-sid\",\"transcript_path\":\"$tp\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -qi "\"decision\":\"block\"" ); then
        pass "G29: no OFF sentinel -> C3 not fired, exit 0"
    else
        fail "G29: no OFF sentinel -> C3 not fired, exit 0 (rc=$rc, out=$out)"
    fi
}

# G30 — WORKTREE_OFF sentinel in a user turn (not assistant) -> C3 not triggered
run_g30() {
    require_source "$HOOK" "G30: OFF in user-turn -> C3 not triggered, exit 0" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    # OFF sentinel in a user message — detectWorktreeOffProposal filters to assistant-only
    tp="$(node_path "$tmp/t.jsonl")"
    printf '%s\n' \
        '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"<<WORKFLOW_ENFORCE_WORKTREE_OFF: test>>"}]}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo hello"}}]}}' \
        > "$tmp/t.jsonl"
    seed_state "$tmp" "g30-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null, l2_retry_count: 0 }"
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"g30-sid\",\"transcript_path\":\"$tp\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -qi "\"decision\":\"block\"" ); then
        pass "G30: OFF in user-turn -> C3 not triggered, exit 0"
    else
        fail "G30: OFF in user-turn -> C3 not triggered, exit 0 (rc=$rc, out=$out)"
    fi
}
