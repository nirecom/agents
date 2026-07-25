#!/usr/bin/env bash
# tests/feat-1607-next-step-pause.sh
# Tests: bin/workflow/next-step, hooks/lib/sentinel-patterns.js, hooks/lib/session-markers.js, hooks/workflow-mark/enforce-override-handlers.js, hooks/stop-premature-stop-guard.js, hooks/supervisor-guard.js, hooks/supervisor-trigger.js, hooks/stop-l2-findings-display.js, CLAUDE.md, settings.json
# Tags: next-step, pause, resume, quiet-layer, supervisor, workflow-off-quiet, scope:issue-specific, pwsh-not-required, TL1, TL2
# TL3 gap (what this test does NOT catch):
# - The Stop/PostToolUse hooks firing in a real claude -p session with a real transcript,
#   and the pause/resume sentinels routed through the live settings.json permission gate.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
NEXT_STEP="$AGENTS_DIR/bin/workflow/next-step"
PATTERNS_NODE="$_AGENTS_DIR_NODE/hooks/lib/sentinel-patterns.js"
HANDLER_NODE="$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers.js"
STATEIO_NODE="$_AGENTS_DIR_NODE/hooks/lib/workflow-state/state-io.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'pause1607'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

seed_wf_state() {  # <tn> <sid> — all-pending state → normally ACTION=invoke (workflow_init)
    CLAUDE_WORKFLOW_DIR="$1" "$RWT" 10 node -e "
const wf=require('$STATEIO_NODE'); wf.markStep('$2','workflow_init','pending');" >/dev/null 2>&1
}
seed_sup_error() {  # <tn> <sid> — cumSev=error, alert pending, one finding
    WORKFLOW_PLANS_DIR="$1" "$RWT" 10 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$2');
st.alert.cumulative_severity='error'; st.alert.alert_phase='pending'; st.alert.alert_armed_at=new Date().toISOString();
st.alert.findings=[{categories:['code'],severity:'error',detail:'blocking',reporter:'workflow-gate',status:'confirmed',timestamp:new Date().toISOString()}];
fs.writeFileSync(w.getStatePath('$2'),JSON.stringify(st));" >/dev/null 2>&1
}
seed_sup_alertdone() {  # <tn> <sid> — alert_phase done, findings unsurfaced
    WORKFLOW_PLANS_DIR="$1" "$RWT" 10 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$2');
st.alert.alert_phase='done'; st.alert.last_run_at=new Date().toISOString(); st.alert.findings_surfaced_at=null;
st.alert.cumulative_severity='warning';
st.alert.findings=[{categories:['workflow'],severity:'warning',detail:'scope drift observed',reporter:'supervisor',status:'confirmed',timestamp:new Date().toISOString()}];
fs.writeFileSync(w.getStatePath('$2'),JSON.stringify(st));" >/dev/null 2>&1
}
touch_marker() { : > "$1/$2"; }   # <tmp> <filename>

# ============ P7: sentinel-patterns pause/resume regex + isSentinel ============
run_P7() {
    local out
    out=$("$RWT" 10 node -e "
const p=require('$PATTERNS_NODE');
const pause='echo \"<<WORKFLOW_NEXT_STEP_PAUSE: taking a detour>>\"';
const resume='echo \"<<WORKFLOW_NEXT_STEP_RESUME: back to work>>\"';
const dq=p.NEXT_STEP_PAUSE_RE_DQ, rdq=p.NEXT_STEP_RESUME_RE_DQ;
if(!dq||!rdq){process.stdout.write('MISSING');process.exit(0);}
process.stdout.write((dq.test(pause)&&rdq.test(resume)&&p.isSentinel(pause)&&p.isSentinel(resume))?'OK':'BAD');" 2>/dev/null)
    if [ "$out" = "OK" ]; then pass "P7: sentinel-patterns defines PAUSE/RESUME regex + isSentinel recognizes them"
    else fail "P7: RED-EXPECTED: pause/resume sentinel patterns absent; got ${out:-<err>}"; fi
}

# ============ P1/P2: enforce-override-handlers create/remove pause marker ============
run_P1_P2() {
    local tmp tn marker
    tmp=$(make_tmp); tn=$(node_path "$tmp"); marker="$tmp/psid.next-step-paused"
    CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 12 node -e "
const h=require('$HANDLER_NODE');
h.handle({cmd:'echo \"<<WORKFLOW_NEXT_STEP_PAUSE: detour>>\"',sessionId:'psid',pushMessage:()=>{},signalFatal:()=>{}});" >/dev/null 2>&1
    if [ -f "$marker" ]; then pass "P1: NEXT_STEP_PAUSE creates <sid>.next-step-paused marker"
    else fail "P1: RED-EXPECTED (handler lacks pause branch): marker not created"; fi
    # resume
    touch_marker "$tmp" "psid.next-step-paused"
    CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 12 node -e "
const h=require('$HANDLER_NODE');
h.handle({cmd:'echo \"<<WORKFLOW_NEXT_STEP_RESUME: back>>\"',sessionId:'psid',pushMessage:()=>{},signalFatal:()=>{}});" >/dev/null 2>&1
    if [ ! -f "$marker" ]; then pass "P2: NEXT_STEP_RESUME removes the pause marker (idempotent)"
    else fail "P2: RED-EXPECTED: RESUME did not remove pause marker"; fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ============ P3: next-step ACTION=paused (cause=next-step-paused) ============
run_P3() {
    local tmp tn out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_wf_state "$tn" "n3sid"
    touch_marker "$tmp" "n3sid.next-step-paused"
    out=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 15 node "$NEXT_STEP" --session n3sid 2>/dev/null)
    if echo "$out" | grep -q "^ACTION=paused$"; then pass "P3a: pause marker → ACTION=paused"
    else fail "P3a: RED-EXPECTED: ACTION not paused under pause marker; out=$(echo "$out" | tr '\n' ' ')"; fi
    if echo "$out" | grep -q "next-step-paused"; then pass "P3b: REASON=next-step-paused surfaced"
    else fail "P3b: RED-EXPECTED: REASON=next-step-paused absent"; fi
    if echo "$out" | grep -q "WORKFLOW_NEXT_STEP_RESUME"; then pass "P3c: NEXT_HINT points at WORKFLOW_NEXT_STEP_RESUME"
    else fail "P3c: RED-EXPECTED: resume hint missing NEXT_STEP_RESUME"; fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ============ P4: next-step workflow-off-quiet cause branch (C4) ============
run_P4() {
    local tmp tn out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_wf_state "$tn" "n4sid"
    touch_marker "$tmp" "n4sid.workflow-off"   # workflow-off, NO pause marker
    out=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 15 node "$NEXT_STEP" --session n4sid 2>/dev/null)
    if echo "$out" | grep -q "^ACTION=paused$"; then pass "P4a: workflow-off → ACTION=paused"
    else fail "P4a: RED-EXPECTED: workflow-off does not yield ACTION=paused; out=$(echo "$out" | tr '\n' ' ')"; fi
    if echo "$out" | grep -q "workflow-off-quiet"; then pass "P4b: REASON=workflow-off-quiet surfaced"
    else fail "P4b: RED-EXPECTED: REASON=workflow-off-quiet absent"; fi
    # cause-branched resume: must point at ENFORCE_WORKFLOW_ON, NOT NEXT_STEP_RESUME
    if echo "$out" | grep -q "WORKFLOW_ENFORCE_WORKFLOW_ON" && ! echo "$out" | grep -q "WORKFLOW_NEXT_STEP_RESUME"; then
        pass "P4c: workflow-off resume hint = ENFORCE_WORKFLOW_ON (not NEXT_STEP_RESUME)"
    else
        fail "P4c: RED-EXPECTED: workflow-off resume hint wrong (must be ENFORCE_WORKFLOW_ON only)"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ============ P5: no markers → ACTION=invoke (baseline non-regression) ============
run_P5() {
    local tmp tn out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_wf_state "$tn" "n5sid"
    out=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 15 node "$NEXT_STEP" --session n5sid 2>/dev/null)
    if echo "$out" | grep -q "^ACTION=invoke$"; then pass "P5: no markers → ACTION=invoke (normal path unaffected)"
    else fail "P5: baseline broke — expected ACTION=invoke; out=$(echo "$out" | tr '\n' ' ')"; fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ============ P6: settings.json PAUSE=ask / RESUME=allow boundary ============
run_P6() {
    local out
    out=$("$RWT" 10 node -e "
const s=require('$_AGENTS_DIR_NODE/settings.json');
const ask=(s.permissions&&s.permissions.ask)||[], allow=(s.permissions&&s.permissions.allow)||[];
const pauseAsk=ask.some(x=>/NEXT_STEP_PAUSE/.test(x));
const resumeAllow=allow.some(x=>/NEXT_STEP_RESUME/.test(x));
const pauseNotAllow=!allow.some(x=>/NEXT_STEP_PAUSE/.test(x));
process.stdout.write((pauseAsk&&resumeAllow&&pauseNotAllow)?'OK':'BAD:pauseAsk='+pauseAsk+',resumeAllow='+resumeAllow);" 2>/dev/null)
    if [ "$out" = "OK" ]; then pass "P6: settings.json PAUSE=ask, RESUME=allow (human-gated pause, auto resume)"
    else fail "P6: RED-EXPECTED: pause/resume permission boundary missing; got ${out:-<err>}"; fi
}

# ============ P8: stop-premature-stop-guard — pause → no decision:block ============
run_P8() {
    local tmp tn out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_wf_state "$tn" "n8sid"
    touch_marker "$tmp" "n8sid.next-step-paused"
    out=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 20 node "$AGENTS_DIR/hooks/stop-premature-stop-guard.js" <<< '{"session_id":"n8sid","transcript_path":""}' 2>/dev/null)
    if ! echo "$out" | grep -q '"decision":"block"'; then pass "P8: stop-premature-stop-guard does NOT auto-resume during pause"
    else fail "P8: RED-EXPECTED: premature-stop guard still blocks during pause; out=$out"; fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ============ P9: supervisor-guard — pause + cumSev=error → exit 0 (no block) ============
run_P9() {
    local tmp tn rc
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_sup_error "$tn" "n9sid"
    touch_marker "$tmp" "n9sid.next-step-paused"
    WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 20 node "$AGENTS_DIR/hooks/supervisor-guard.js" <<< '{"session_id":"n9sid","transcript_path":""}' >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "0" ]; then pass "P9: supervisor-guard exits 0 during pause despite cumSev=error"
    else fail "P9: RED-EXPECTED: supervisor-guard still blocks (rc=$rc) during pause"; fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ============ P10: supervisor-trigger — pause + cumSev=error → no advisory ============
run_P10() {
    local tmp tn out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_sup_error "$tn" "n10sid"
    touch_marker "$tmp" "n10sid.next-step-paused"
    out=$(WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" \
        "$RWT" 15 node "$AGENTS_DIR/hooks/supervisor-trigger.js" <<< '{"tool_name":"Bash","session_id":"n10sid","transcript_path":""}' 2>/dev/null)
    if ! echo "$out" | grep -q 'additionalContext'; then pass "P10: supervisor-trigger emits no error advisory during pause (non-consuming)"
    else fail "P10: RED-EXPECTED: supervisor-trigger still surfaces advisory during pause; out=$out"; fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ============ P11: stop-l2-findings-display — pause → no re-surface + surfaced_at not written ============
run_P11() {
    local tmp tn ctrl outp surfaced
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    # control: WITHOUT pause marker, confirm the hook actually surfaces (else skip)
    seed_sup_alertdone "$tn" "n11sid"
    ctrl=$(WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 15 node "$AGENTS_DIR/hooks/stop-l2-findings-display.js" <<< '{"session_id":"n11sid","transcript_path":""}' 2>/dev/null)
    if ! echo "$ctrl" | grep -q 'additionalContext'; then
        skip "P11: findings did not render in control (renderer gate) — cannot isolate pause suppression"
        rm -rf "$tmp" 2>/dev/null || true
        return
    fi
    # pause case: fresh state (surfaced_at reset) + pause marker → must NOT surface
    seed_sup_alertdone "$tn" "n11sid"
    touch_marker "$tmp" "n11sid.next-step-paused"
    outp=$(WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 15 node "$AGENTS_DIR/hooks/stop-l2-findings-display.js" <<< '{"session_id":"n11sid","transcript_path":""}' 2>/dev/null)
    if ! echo "$outp" | grep -q 'additionalContext'; then pass "P11a: stop-l2-findings-display does not re-surface findings during pause"
    else fail "P11a: RED-EXPECTED: findings still surfaced during pause; out=$outp"; fi
    surfaced=$(grep -o '"findings_surfaced_at":[^,}]*' "$tmp"/n11sid-supervisor-state.json 2>/dev/null | head -1)
    if echo "$surfaced" | grep -q 'null'; then pass "P11b: findings_surfaced_at left null during pause (findings not consumed)"
    else fail "P11b: RED-EXPECTED: findings_surfaced_at written during pause (findings wrongly consumed); got $surfaced"; fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ============ P12: CLAUDE.md action-contract lists `paused` ============
run_P12() {
    if grep -qE "\bpaused\b" "$AGENTS_DIR/CLAUDE.md" 2>/dev/null; then
        pass "P12: CLAUDE.md next-step action-contract documents the paused action"
    else
        fail "P12: RED-EXPECTED: CLAUDE.md action-contract does not mention 'paused'"
    fi
}

run_P7
run_P1_P2
run_P3
run_P4
run_P5
run_P6
run_P8
run_P9
run_P10
run_P11
run_P12

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
