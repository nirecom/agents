#!/usr/bin/env bash
# tests/bin/feat-1607-next-step-pause.sh
# Tests: bin/workflow/next-step, hooks/lib/sentinel-patterns.js, hooks/lib/session-markers.js, hooks/workflow-mark/enforce-override-handlers.js, hooks/stop-premature-stop-guard.js, hooks/supervisor-guard.js, hooks/supervisor-trigger.js, hooks/stop-l2-findings-display.js, CLAUDE.md, settings.json, bin/workflow/lib/next-step/
# Tags: next-step, pause, resume, quiet-layer, supervisor, workflow-off-quiet, scope:issue-specific, pwsh-not-required, TL1, TL2
# TL3 gap (what this test does NOT catch):
# - The Stop/PostToolUse hooks firing in a real claude -p session with a real transcript,
#   and the pause/resume sentinels routed through the live settings.json permission gate.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT
if command -v cygpath >/dev/null 2>&1; then _CHECKOUT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"; else _CHECKOUT_NODE="$SCRIPT_CHECKOUT_ROOT"; fi
NEXT_STEP="$SCRIPT_CHECKOUT_ROOT/bin/workflow/next-step"
PATTERNS_NODE="$_CHECKOUT_NODE/hooks/lib/sentinel-patterns.js"
HANDLER_NODE="$_CHECKOUT_NODE/hooks/workflow-mark/enforce-override-handlers.js"
STATEIO_NODE="$_CHECKOUT_NODE/hooks/workflow-state/state-io.js"
WRITER_NODE="$_CHECKOUT_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_CHECKOUT_NODE/hooks/lib/supervisor-state-schema.js"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'pause1607'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# seed_batch <kind> <tn> <sid> [<kind> <tn> <sid>...] — ONE node seeds every fixture.
# kind: wf (all-pending state → ACTION=invoke), sup_error (cumSev=error, alert
# pending), sup_alertdone (alert done, findings unsurfaced). Each triple gets its
# own dir, dual-pinned env, and a cleared require.cache (no cross-row state).
seed_batch() {
    "$RWT" 20 node -e "
const fs=require('fs'),a=process.argv.slice(1),now=()=>new Date().toISOString();
for(let i=0;i+2<a.length;i+=3){const [k,tn,sid]=a.slice(i,i+3);
 for(const m of Object.keys(require.cache)) delete require.cache[m];
 process.env.WORKFLOW_STATE_DIR=tn; process.env.WORKFLOW_PLANS_DIR=tn;
 try{ if(k==='wf'){require('$STATEIO_NODE').markStep(sid,'workflow_init','pending');continue;}
  const w=require('$WRITER_NODE'),st=require('$SCHEMA_NODE').createEmptyState(sid);
  if(k==='sup_error'){st.alert.cumulative_severity='error';st.alert.alert_phase='pending';st.alert.alert_armed_at=now();
   st.alert.findings=[{categories:['code'],severity:'error',detail:'blocking',reporter:'workflow-gate',status:'confirmed',timestamp:now()}];}
  else{st.alert.alert_phase='done';st.alert.last_run_at=now();st.alert.findings_surfaced_at=null;st.alert.cumulative_severity='warning';
   st.alert.findings=[{categories:['workflow'],severity:'warning',detail:'scope drift observed',reporter:'supervisor',status:'confirmed',timestamp:now()}];}
  fs.writeFileSync(w.getStatePath(sid,{forWrite:true}),JSON.stringify(st));
 }catch(e){process.stderr.write('seed '+k+' '+sid+': '+e.message+'\n');}}" "$@" >/dev/null 2>&1
}
touch_marker() { : > "$1/$2"; }   # <tmp> <filename>

# Pre-create + seed every per-case fixture dir in one node (dirs stay disjoint).
declare -A TMPD TND
for _c in P3 P4 P5 P8 P9 P10 P11; do TMPD[$_c]=$(make_tmp); TND[$_c]=$(node_path "${TMPD[$_c]}"); done
seed_batch wf "${TND[P3]}" n3sid wf "${TND[P4]}" n4sid wf "${TND[P5]}" n5sid wf "${TND[P8]}" n8sid \
    sup_error "${TND[P9]}" n9sid sup_error "${TND[P10]}" n10sid sup_alertdone "${TND[P11]}" n11sid

# ============ P7: sentinel-patterns pause/resume regex + isSentinel ============
# P7 + P6 are pure read-only probes → one node, one "P7=<r>" / "P6=<r>" line each
# (a throw maps to empty = <err>, as the former 2>/dev/null capture did).
probe_P7_P6() {
    "$RWT" 10 node -e "
const t=f=>{try{return f();}catch(e){return '';}};
const p7=t(()=>{const p=require('$PATTERNS_NODE');
const pause='echo \"<<WORKFLOW_NEXT_STEP_PAUSE: taking a detour>>\"';
const resume='echo \"<<WORKFLOW_NEXT_STEP_RESUME: back to work>>\"';
const dq=p.NEXT_STEP_PAUSE_RE_DQ, rdq=p.NEXT_STEP_RESUME_RE_DQ;
if(!dq||!rdq) return 'MISSING';
return (dq.test(pause)&&rdq.test(resume)&&p.isSentinel(pause)&&p.isSentinel(resume))?'OK':'BAD';});
const p6=t(()=>{const s=require('$_CHECKOUT_NODE/settings.json');
const ask=(s.permissions&&s.permissions.ask)||[], allow=(s.permissions&&s.permissions.allow)||[];
const pauseAsk=ask.some(x=>/NEXT_STEP_PAUSE/.test(x));
const resumeAllow=allow.some(x=>/NEXT_STEP_RESUME/.test(x));
const pauseNotAllow=!allow.some(x=>/NEXT_STEP_PAUSE/.test(x));
return (pauseAsk&&resumeAllow&&pauseNotAllow)?'OK':'BAD:pauseAsk='+pauseAsk+',resumeAllow='+resumeAllow;});
process.stdout.write('P7='+p7+'\nP6='+p6+'\n');" 2>/dev/null
}
PROBE_OUT=$(probe_P7_P6)
probe_get() { printf '%s\n' "$PROBE_OUT" | sed -n "s/^$1=//p"; }
# Vacuity guard: the batched probe must emit both lines, else every probe row FAILs loudly.
if ! printf '%s\n' "$PROBE_OUT" | grep -q '^P7=' || ! printf '%s\n' "$PROBE_OUT" | grep -q '^P6='; then
    fail "PROBE-BATCH: batched P7/P6 probe emitted <2 result lines; got ${PROBE_OUT:-<err>}"
fi

case_begin "P7-sentinel-patterns" "hooks/lib/sentinel-patterns.js"
run_P7() {
    local out
    out=$(probe_get P7)
    if [ "$out" = "OK" ]; then pass "P7: sentinel-patterns defines PAUSE/RESUME regex + isSentinel recognizes them"
    else fail "P7: RED-EXPECTED: pause/resume sentinel patterns absent; got ${out:-<err>}"; fi
}
run_P7
case_end

# ============ P1/P2: enforce-override-handlers create/remove pause marker ============
case_begin "P1-P2-override-handler-marker" "hooks/workflow-mark/enforce-override-handlers.js"
run_P1_P2() {
    local tmp tn marker
    tmp=$(make_tmp); tn=$(node_path "$tmp"); marker="$tmp/psid.next-step-paused"
    WORKFLOW_STATE_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 12 node -e "
const h=require('$HANDLER_NODE');
h.handle({cmd:'echo \"<<WORKFLOW_NEXT_STEP_PAUSE: detour>>\"',sessionId:'psid',pushMessage:()=>{},signalFatal:()=>{}});" >/dev/null 2>&1
    if [ -f "$marker" ]; then pass "P1: NEXT_STEP_PAUSE creates <sid>.next-step-paused marker"
    else fail "P1: RED-EXPECTED (handler lacks pause branch): marker not created"; fi
    # resume
    touch_marker "$tmp" "psid.next-step-paused"
    WORKFLOW_STATE_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 12 node -e "
const h=require('$HANDLER_NODE');
h.handle({cmd:'echo \"<<WORKFLOW_NEXT_STEP_RESUME: back>>\"',sessionId:'psid',pushMessage:()=>{},signalFatal:()=>{}});" >/dev/null 2>&1
    if [ ! -f "$marker" ]; then pass "P2: NEXT_STEP_RESUME removes the pause marker (idempotent)"
    else fail "P2: RED-EXPECTED: RESUME did not remove pause marker"; fi
    rm -rf "$tmp" 2>/dev/null || true
}
run_P1_P2
case_end

# ============ P3: next-step ACTION=paused (cause=next-step-paused) ============
case_begin "P3-next-step-paused" "bin/workflow/next-step"
run_P3() {
    local tmp tn out
    tmp=${TMPD[P3]}; tn=${TND[P3]}   # pre-seeded by seed_batch
    touch_marker "$tmp" "n3sid.next-step-paused"
    out=$(WORKFLOW_STATE_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 15 node "$NEXT_STEP" --session n3sid 2>/dev/null)
    if echo "$out" | grep -q "^ACTION=paused$"; then pass "P3a: pause marker → ACTION=paused"
    else fail "P3a: RED-EXPECTED: ACTION not paused under pause marker; out=$(echo "$out" | tr '\n' ' ')"; fi
    if echo "$out" | grep -q "next-step-paused"; then pass "P3b: REASON=next-step-paused surfaced"
    else fail "P3b: RED-EXPECTED: REASON=next-step-paused absent"; fi
    if echo "$out" | grep -q "WORKFLOW_NEXT_STEP_RESUME"; then pass "P3c: NEXT_HINT points at WORKFLOW_NEXT_STEP_RESUME"
    else fail "P3c: RED-EXPECTED: resume hint missing NEXT_STEP_RESUME"; fi
    rm -rf "$tmp" 2>/dev/null || true
}
run_P3
case_end

# ============ P4: next-step workflow-off-quiet cause branch (C4) ============
case_begin "P4-workflow-off-quiet" "bin/workflow/lib/next-step/"
run_P4() {
    local tmp tn out
    tmp=${TMPD[P4]}; tn=${TND[P4]}   # pre-seeded by seed_batch
    touch_marker "$tmp" "n4sid.workflow-off"   # workflow-off, NO pause marker
    out=$(WORKFLOW_STATE_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 15 node "$NEXT_STEP" --session n4sid 2>/dev/null)
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
run_P4
case_end

# ============ P5: no markers → ACTION=invoke (baseline non-regression) ============
case_begin "P5-no-markers-invoke" "hooks/lib/session-markers.js"
run_P5() {
    local tmp tn out
    tmp=${TMPD[P5]}; tn=${TND[P5]}   # pre-seeded by seed_batch
    out=$(WORKFLOW_STATE_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 15 node "$NEXT_STEP" --session n5sid 2>/dev/null)
    if echo "$out" | grep -q "^ACTION=invoke$"; then pass "P5: no markers → ACTION=invoke (normal path unaffected)"
    else fail "P5: baseline broke — expected ACTION=invoke; out=$(echo "$out" | tr '\n' ' ')"; fi
    rm -rf "$tmp" 2>/dev/null || true
}
run_P5
case_end

# ============ P6: settings.json PAUSE=ask / RESUME=allow boundary ============
case_begin "P6-settings-permission-boundary" "settings.json"
run_P6() {
    local out
    out=$(probe_get P6)
    if [ "$out" = "OK" ]; then pass "P6: settings.json PAUSE=ask, RESUME=allow (human-gated pause, auto resume)"
    else fail "P6: RED-EXPECTED: pause/resume permission boundary missing; got ${out:-<err>}"; fi
}
run_P6
case_end

# ============ P8: stop-premature-stop-guard — pause → no decision:block ============
case_begin "P8-premature-stop-guard-quiet" "hooks/stop-premature-stop-guard.js"
run_P8() {
    local tmp tn out
    tmp=${TMPD[P8]}; tn=${TND[P8]}   # pre-seeded by seed_batch
    touch_marker "$tmp" "n8sid.next-step-paused"
    out=$(WORKFLOW_STATE_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" \
        "$RWT" 20 node "$SCRIPT_CHECKOUT_ROOT/hooks/stop-premature-stop-guard.js" <<< '{"session_id":"n8sid","transcript_path":""}' 2>/dev/null)
    if ! echo "$out" | grep -q '"decision":"block"'; then pass "P8: stop-premature-stop-guard does NOT auto-resume during pause"
    else fail "P8: RED-EXPECTED: premature-stop guard still blocks during pause; out=$out"; fi
    rm -rf "$tmp" 2>/dev/null || true
}
run_P8
case_end

# ============ P9: supervisor-guard — pause + cumSev=error → exit 0 (no block) ============
case_begin "P9-supervisor-guard-quiet" "hooks/supervisor-guard.js"
run_P9() {
    local tmp tn rc
    tmp=${TMPD[P9]}; tn=${TND[P9]}   # pre-seeded by seed_batch
    touch_marker "$tmp" "n9sid.next-step-paused"
    WORKFLOW_PLANS_DIR="$tn" WORKFLOW_STATE_DIR="$tn" \
        "$RWT" 20 node "$SCRIPT_CHECKOUT_ROOT/hooks/supervisor-guard.js" <<< '{"session_id":"n9sid","transcript_path":""}' >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "0" ]; then pass "P9: supervisor-guard exits 0 during pause despite cumSev=error"
    else fail "P9: RED-EXPECTED: supervisor-guard still blocks (rc=$rc) during pause"; fi
    rm -rf "$tmp" 2>/dev/null || true
}
run_P9
case_end

# ============ P10: supervisor-trigger — pause + cumSev=error → no advisory ============
case_begin "P10-supervisor-trigger-quiet" "hooks/supervisor-trigger.js"
run_P10() {
    local tmp tn out
    tmp=${TMPD[P10]}; tn=${TND[P10]}   # pre-seeded by seed_batch
    touch_marker "$tmp" "n10sid.next-step-paused"
    out=$(WORKFLOW_PLANS_DIR="$tn" WORKFLOW_STATE_DIR="$tn" \
        "$RWT" 15 node "$SCRIPT_CHECKOUT_ROOT/hooks/supervisor-trigger.js" <<< '{"tool_name":"Bash","session_id":"n10sid","transcript_path":""}' 2>/dev/null)
    if ! echo "$out" | grep -q 'additionalContext'; then pass "P10: supervisor-trigger emits no error advisory during pause (non-consuming)"
    else fail "P10: RED-EXPECTED: supervisor-trigger still surfaces advisory during pause; out=$out"; fi
    rm -rf "$tmp" 2>/dev/null || true
}
run_P10
case_end

# ============ P11: stop-l2-findings-display — pause → no re-surface + surfaced_at not written ============
case_begin "P11-findings-display-quiet" "hooks/stop-l2-findings-display.js"
run_P11() {
    local tmp tn ctrl outp surfaced
    tmp=${TMPD[P11]}; tn=${TND[P11]}   # pre-seeded (sup_alertdone) by seed_batch
    # control: WITHOUT pause marker, confirm the hook actually surfaces (else skip)
    ctrl=$(WORKFLOW_PLANS_DIR="$tn" WORKFLOW_STATE_DIR="$tn" \
        "$RWT" 15 node "$SCRIPT_CHECKOUT_ROOT/hooks/stop-l2-findings-display.js" <<< '{"session_id":"n11sid","transcript_path":""}' 2>/dev/null)
    if ! echo "$ctrl" | grep -q 'additionalContext'; then
        skip "P11: findings did not render in control (renderer gate) — cannot isolate pause suppression"
        rm -rf "$tmp" 2>/dev/null || true
        return
    fi
    # pause case: fresh state (surfaced_at reset) + pause marker → must NOT surface
    seed_batch sup_alertdone "$tn" n11sid
    touch_marker "$tmp" "n11sid.next-step-paused"
    outp=$(WORKFLOW_PLANS_DIR="$tn" WORKFLOW_STATE_DIR="$tn" \
        "$RWT" 15 node "$SCRIPT_CHECKOUT_ROOT/hooks/stop-l2-findings-display.js" <<< '{"session_id":"n11sid","transcript_path":""}' 2>/dev/null)
    if ! echo "$outp" | grep -q 'additionalContext'; then pass "P11a: stop-l2-findings-display does not re-surface findings during pause"
    else fail "P11a: RED-EXPECTED: findings still surfaced during pause; out=$outp"; fi
    surfaced=$(grep -o '"findings_surfaced_at":[^,}]*' "$tmp"/n11sid.control/supervisor-state.json 2>/dev/null | head -1)
    if echo "$surfaced" | grep -q 'null'; then pass "P11b: findings_surfaced_at left null during pause (findings not consumed)"
    else fail "P11b: RED-EXPECTED: findings_surfaced_at written during pause (findings wrongly consumed); got $surfaced"; fi
    rm -rf "$tmp" 2>/dev/null || true
}
run_P11
case_end

# ============ P12: CLAUDE.md action-contract lists `paused` ============
case_begin "P12-claude-md-paused-action" "CLAUDE.md"
run_P12() {
    if grep -qE "\bpaused\b" "$SCRIPT_CHECKOUT_ROOT/CLAUDE.md" 2>/dev/null; then
        pass "P12: CLAUDE.md next-step action-contract documents the paused action"
    else
        fail "P12: RED-EXPECTED: CLAUDE.md action-contract does not mention 'paused'"
    fi
}
run_P12
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
