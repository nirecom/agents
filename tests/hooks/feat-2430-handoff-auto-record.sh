#!/usr/bin/env bash
# tests/hooks/feat-2430-handoff-auto-record.sh
# Tests: hooks/post-compact.js, hooks/workflow-mark/reset-handler.js, bin/supervisor-write-audit-verdict, bin/supervisor-write-audit
# Tags: handoff, auto-record, post-compact, reset-from, supervisor-verdict, active-period, workflow-off, fail-open, regression-2430, regression-2652, state-handoff-record, scope:issue-specific, pwsh-not-required, TL2

# Issue #2430 — events a resuming session cannot reconstruct from the compacted transcript (a compaction, a WARN/BLOCK audit verdict) are recorded mechanically at the code that performs them, as origin auto-record, through the one helper that owns that origin (CPR-SSOT). #2652 moves those records into the state file as state_handoff_record events, and drops the RESET_FROM breadcrumb: the `reset` event the handler already appends is the one record of a rollback, so a second record would copy it. A lost record never changes the primary job's output or exit code.
# Header note: the helper-owns-the-origin case targets hooks/lib/auto-record.js, which is not a header token — the #2502 language gate refuses a new js token in a bash header; the deleted hooks/lib/handoff-auto-record.js token was dropped.

# TL3 gap: the real dispatch (Claude Code firing PostCompact, the workflow-mark PostToolUse hook routing a real RESET_FROM echo, the supervisor-audit agent calling the verdict CLI) is not driven; each producer is fed the envelope or argv it receives in production. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.

# TDD (write_code has not run): the "records" rows are expected to FAIL until hooks/lib/auto-record.js and hooks/lib/state-handoff-record.js exist and the producers write state_handoff_record events; the "records nothing", "one reset event" and "output unchanged" rows already hold today and pin the contract against regression.

set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP="$(make_tmp)"
readonly TMP
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$TMP/wf" "$TMP/home" "$TMP/transcripts"
export WORKFLOW_STATE_DIR="$(np "$TMP/wf")"
export WORKFLOW_PLANS_DIR="$WORKFLOW_STATE_DIR"
export HOME="$(np "$TMP/home")" USERPROFILE="$(np "$TMP/home")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMP/transcripts")"
export AGENTS="$(np "$SCRIPT_CHECKOUT_ROOT")"
unset CLAUDE_CODE_SESSION_ID
cd "$TMP" || exit 1

# ---- helpers (JS lives in generated files that read process.env only)
cat > "$TMP/seed.js" <<'JS'
// node seed.js <sid> <active|final|init-only>
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const [sid, mode] = process.argv.slice(2);
S.writeState(sid, S.createInitialState(sid, { cwd: '/x', git_branch: 'feature/x' }));
if (mode !== 'init-only') S.markStep(sid, 'workflow_init', 'complete');
if (mode === 'final') S.markStep(sid, 'final_report', 'complete');
JS
cat > "$TMP/entry.js" <<'JS'
// node entry.js <sid> <key> [cls step summaryPrefix pointerSuffix] — OK / BAD:... / COUNT:<n>
// over the state file's state_handoff_record events with that record_key.
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const [sid, key, cls, step, prefix, pointer] = process.argv.slice(2);
let events = [];
try { events = ((S.readRawState(sid) || {}).events || []); } catch (e) { events = []; }
const all = events.filter((e) => e && e.kind === 'state_handoff_record' && e.record_key === key);
if (!cls) { process.stdout.write('COUNT:' + all.length); process.exit(0); }
const bad = [];
if (all.length !== 1) bad.push('records:' + all.length);
else {
  const e = all[0];
  if (e.cls !== cls) bad.push('cls:' + e.cls);
  if (e.at_step !== step) bad.push('at_step:' + e.at_step);
  if (e.origin !== 'auto-record') bad.push('origin:' + e.origin);
  if (String(e.summary).indexOf(prefix) !== 0) bad.push('summary:' + e.summary);
  if (pointer !== '-' && !String(e.pointer).replace(/\\/g, '/').endsWith(pointer)) bad.push('pointer:' + e.pointer);
  if (pointer === '-' && e.pointer !== '-' && e.pointer !== '') bad.push('pointer:' + e.pointer);
}
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS
cat > "$TMP/resets.js" <<'JS'
// node resets.js <sid> — "<reset events>:<from_step of the last>:<state_handoff_record reset-from records>"
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
let events = [];
try { events = ((S.readRawState(process.argv[2]) || {}).events || []); } catch (e) { events = []; }
const resets = events.filter((e) => e && e.kind === 'reset');
const recs = events.filter((e) => e && e.kind === 'state_handoff_record' && e.record_key === 'reset-from');
process.stdout.write(resets.length + ':' + (resets.length ? resets[resets.length - 1].from_step : '-') + ':' + recs.length);
JS
cat > "$TMP/reset.js" <<'JS'
// node reset.js <sid|-> <sentinel-command>
const { handle } = require(process.env.AGENTS + '/hooks/workflow-mark/reset-handler');
const sid = process.argv[2] === '-' ? null : process.argv[2];
const msgs = [];
handle({ cmd: process.argv[3], sessionId: sid, pushMessage: (m) => msgs.push(m), signalFatal: (m) => msgs.push('FATAL:' + m), repoCwd: process.cwd() });
process.stdout.write(msgs.join('\n'));
JS
cat > "$TMP/arm.js" <<'JS'
// node arm.js <sid> — empty supervisor state, then arm one audit run; prints its id.
const fs = require('fs');
const w = require(process.env.AGENTS + '/hooks/lib/supervisor-state-writer');
const s = require(process.env.AGENTS + '/hooks/lib/supervisor-state-schema');
const { armAuditRun } = require(process.env.AGENTS + '/hooks/lib/supervisor-state-writer/audit-run');
const sid = process.argv[2];
const st = s.createEmptyState(sid);
st.audit = Object.assign(st.audit || {}, { audit_phase: null });
const p = w.getStatePath(sid);
fs.mkdirSync(require('path').dirname(p), { recursive: true });
fs.writeFileSync(p, JSON.stringify(st));
const r = armAuditRun(sid, { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#1'] });
process.stdout.write(String((r && (r.audit_run_id || r.run_id)) || 'ARMFAIL'));
JS
cat > "$TMP/status.js" <<'JS'
// node status.js <sid> <step> — the step's current status, or NOSTATE.
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const st = S.readState(process.argv[2]);
process.stdout.write(st && st.steps && st.steps[process.argv[3]] ? String(st.steps[process.argv[3]].status) : 'NOSTATE');
JS

nj() { run_with_timeout 60 node "$(np "$TMP/$1")" "${@:2}" 2>&1; }
seed() { nj seed.js "$1" "$2" >/dev/null; }
# approve_gates <sid> — real confirm-sentinel approvals for every gated step: since #2709 a
# RESET_FROM past a gated step is refused unless that step already holds a verified approval.
approve_gates() {
    run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/tests/lib/plan-approval-fixture.js" approve "$1" clarify_intent outline detail >/dev/null
}
entry() { nj entry.js "$@"; }
resets() { nj resets.js "$1"; }
status() { nj status.js "$1" "$2"; }
verdict_cli() { run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-write-audit-verdict" "$@" 2>/dev/null; }
audit_cli() { run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-write-audit" "$@" 2>/dev/null; }
compact() { printf '{"session_id":"%s"}' "$1" | run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/hooks/post-compact.js" 2>/dev/null; }
verdict_ptr() { printf '%s' "$1.control/supervisor-state.json"; }

expect() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$3 got=${2:0:300}"; fi
}

# injected <output> — the re-injection envelope PostCompact exists to emit.
injected() {
    case "$1" in *'"additionalContext"'*'Workflow progress:'*) printf 'yes' ;; *) printf 'no:%s' "${1:0:120}" ;; esac
}

# rejected <reset.js output> — the handler said it did not apply the reset.
rejected() {
    case "$1" in *malformed*|*rejected*|*unknown*|*"NOT applied"*) printf 'yes' ;; *) printf 'no:%s' "${1:0:120}" ;; esac
}

# ---- post-compact

case_begin "post-compact-active-records" "hooks/post-compact.js"
seed pc-active active
OUT="$(compact pc-active)"
expect "A1: an active-period compaction still re-injects its context" "$(injected "$OUT")" "yes"
expect "A1: it records a class B compaction state_handoff_record, origin auto-record" \
    "$(entry pc-active compaction B - 'context compaction occurred at ' -)" "OK"
case_end

case_begin "post-compact-inactive-records-nothing" "hooks/post-compact.js"
seed pc-final final
OUT="$(compact pc-final)"
expect "A2: after final_report the compaction still re-injects" "$(injected "$OUT")" "yes"
expect "A2: after final_report nothing is recorded" "$(entry pc-final compaction)" "COUNT:0"
OUT="$(compact pc-nostate)"
expect "A2: with no state the compaction still re-injects" "$(injected "$OUT")" "yes"
expect "A2: with no state nothing is recorded" "$(entry pc-nostate compaction)" "COUNT:0"
expect "A2: with no state no state file is created" "$([ -e "$TMP/wf/pc-nostate.json" ] && echo created || echo none)" "none"
case_end

# ---- RESET_FROM: the reset event is the one record (#2652); no reset-from state_handoff_record.

case_begin "reset-from-success-leaves-one-reset-event" "hooks/workflow-mark/reset-handler.js"
seed rs-ok active
CMD='echo "<<WORKFLOW_RESET_FROM_clarify_intent: redo the intent check>>"'
OUT="$(nj reset.js rs-ok "$CMD")"
expect "R1: the reset itself is applied (no rejection message)" "$OUT" ""
expect "R1: one reset event from clarify_intent, and no reset-from state_handoff_record" "$(resets rs-ok)" "1:clarify_intent:0"
case_end

case_begin "reset-from-rejected-records-nothing" "hooks/workflow-mark/reset-handler.js"
seed rs-empty active
CMD='echo "<<WORKFLOW_RESET_FROM_clarify_intent: >>"'
OUT="$(nj reset.js rs-empty "$CMD")"
expect "R2: an empty-reason RESET_FROM is rejected" "$(rejected "$OUT")" "yes"
expect "R2: an empty-reason RESET_FROM leaves no reset event and no record" "$(resets rs-empty)" "0:-:0"
seed rs-unknown active
CMD='echo "<<WORKFLOW_RESET_FROM_no_such_step: a valid reason>>"'
OUT="$(nj reset.js rs-unknown "$CMD")"
expect "R2: an unknown-step RESET_FROM is rejected" "$(rejected "$OUT")" "yes"
expect "R2: an unknown-step RESET_FROM leaves no reset event and no record" "$(resets rs-unknown)" "0:-:0"
CMD='echo "<<WORKFLOW_RESET_FROM_clarify_intent: a valid reason>>"'
OUT="$(nj reset.js rs-nostate "$CMD")"
expect "R2: a RESET_FROM with no state is rejected" "$(rejected "$OUT")" "yes"
expect "R2: a RESET_FROM with no state creates no state file" "$([ -e "$TMP/wf/rs-nostate.json" ] && echo created || echo none)" "none"
case_end

case_begin "reset-from-workflow-init-leaves-one-reset-event" "hooks/workflow-mark/reset-handler.js"
seed rs-init active
CMD='echo "<<WORKFLOW_RESET_FROM_workflow_init: restart the whole session>>"'
OUT="$(nj reset.js rs-init "$CMD")"
expect "R3: RESET_FROM_workflow_init is applied (no rejection message)" "$OUT" ""
expect "R3: the reset rolled workflow_init back to pending" "$(status rs-init workflow_init)" "pending"
expect "R3: one reset event from workflow_init, and no reset-from state_handoff_record" "$(resets rs-init)" "1:workflow_init:0"
case_end

case_begin "reset-from-mid-step-leaves-one-reset-event" "hooks/workflow-mark/reset-handler.js"
seed rs-mid active
approve_gates rs-mid
CMD='echo "<<WORKFLOW_RESET_FROM_run_tests: rerun the suite>>"'
OUT="$(nj reset.js rs-mid "$CMD")"
expect "R4: RESET_FROM_run_tests is applied" "$OUT" ""
expect "R4: one reset event from run_tests, and no reset-from state_handoff_record" "$(resets rs-mid)" "1:run_tests:0"
case_end

case_begin "reset-from-never-active-records-nothing" "hooks/workflow-mark/reset-handler.js"
seed rs-never init-only
CMD='echo "<<WORKFLOW_RESET_FROM_workflow_init: restart the whole session>>"'
OUT="$(nj reset.js rs-never "$CMD")"
expect "R5: a reset on a never-initialised session is still applied" "$OUT" ""
expect "R5: workflow_init stays pending" "$(status rs-never workflow_init)" "pending"
expect "R5: one reset event, and no reset-from state_handoff_record" "$(resets rs-never)" "1:workflow_init:0"
case_end

case_begin "reset-from-workflow-off-records-nothing" "hooks/workflow-mark/reset-handler.js"
seed rs-off active
approve_gates rs-off
: >"$TMP/wf/rs-off.workflow-off"
CMD='echo "<<WORKFLOW_RESET_FROM_run_tests: rerun the suite>>"'
OUT="$(nj reset.js rs-off "$CMD")"
expect "R6: a reset under WORKFLOW_OFF is still applied" "$OUT" ""
expect "R6: run_tests is pending after the reset" "$(status rs-off run_tests)" "pending"
expect "R6: one reset event, and no reset-from state_handoff_record" "$(resets rs-off)" "1:run_tests:0"
case_end

case_begin "reset-from-revives-finished-session-leaves-one-reset-event" "hooks/workflow-mark/reset-handler.js"
seed rs-revive final
approve_gates rs-revive
CMD='echo "<<WORKFLOW_RESET_FROM_run_tests: reopen after the final report>>"'
OUT="$(nj reset.js rs-revive "$CMD")"
expect "R7: a reset after final_report is applied" "$OUT" ""
expect "R7: final_report is pending again" "$(status rs-revive final_report)" "pending"
expect "R7: one reset event from run_tests, and no reset-from state_handoff_record" "$(resets rs-revive)" "1:run_tests:0"
case_end

# ---- supervisor-write-audit-verdict

case_begin "verdict-warn-block-records" "bin/supervisor-write-audit-verdict"
seed vd-plain active
OUT="$(verdict_cli --session-id vd-plain --verdict WARN --verdict-summary 'drift found')"; RC=$?
expect "V1: the plain-path WARN keeps exit 0" "$RC" "0"
expect "V1: the plain-path WARN keeps its stdout" "$OUT" '{"accepted":true,"audit_run_id":null}'
expect "V1: the plain-path WARN records class E supervisor-audit:verdict" \
    "$(entry vd-plain supervisor-audit:verdict E - 'supervisor audit WARN: drift found' "$(verdict_ptr vd-plain)")" "OK"
seed vd-cas active
RUN="$(nj arm.js vd-cas)"
OUT="$(verdict_cli --session-id vd-cas --audit-run-id "$RUN" --verdict BLOCK --verdict-summary 'stop here')"; RC=$?
expect "V2: the CAS-accepted BLOCK keeps exit 0" "$RC" "0"
expect "V2: the CAS-accepted BLOCK records class E supervisor-audit:verdict" \
    "$(entry vd-cas supervisor-audit:verdict E - 'supervisor audit BLOCK: stop here' "$(verdict_ptr vd-cas)")" "OK"
case_end

case_begin "verdict-continue-mismatch-records-nothing" "bin/supervisor-write-audit-verdict"
seed vd-continue active
verdict_cli --session-id vd-continue --verdict CONTINUE --verdict-summary 'all good' >/dev/null
expect "V3: CONTINUE records nothing" "$(entry vd-continue supervisor-audit:verdict)" "COUNT:0"
seed vd-stale active
nj arm.js vd-stale >/dev/null
verdict_cli --session-id vd-stale --audit-run-id run-9999 --verdict WARN --verdict-summary 'late' >/dev/null; RC=$?
expect "V4: a superseded run still exits 3" "$RC" "3"
expect "V4: a superseded run records nothing" "$(entry vd-stale supervisor-audit:verdict)" "COUNT:0"
case_end

# V5 — a refused record must not change the verdict CLI's output. The old fixture (a directory
# at handoff.md) has no state-file counterpart that the CLI's own supervisor-state write would
# survive, so the refusal is driven by a session with no workflow state file (reason no-state).
case_begin "verdict-write-failure-keeps-output" "bin/supervisor-write-audit-verdict"
OUT="$(verdict_cli --session-id vd-nostate --verdict WARN --verdict-summary 'drift found')"; RC=$?
expect "V5: a refused record (no state file) keeps exit 0" "$RC" "0"
expect "V5: a refused record keeps stdout" "$OUT" '{"accepted":true,"audit_run_id":null}'
expect "V5: a refused record creates no state file" "$([ -e "$TMP/wf/vd-nostate.json" ] && echo created || echo none)" "none"
case_end

# ---- supervisor-write-audit --set-audit-verdict

case_begin "set-audit-verdict-records" "bin/supervisor-write-audit"
seed wa-warn active
seed wa-mirror active
audit_cli --session-id wa-warn --mirror-session-id wa-mirror --set-audit-verdict WARN --set-audit-verdict-summary 'drift found' >/dev/null; RC=$?
expect "W1: --set-audit-verdict WARN keeps exit 0" "$RC" "0"
expect "W1: --set-audit-verdict WARN records class E supervisor-audit:verdict" \
    "$(entry wa-warn supervisor-audit:verdict E - 'supervisor audit WARN' "$(verdict_ptr wa-warn)")" "OK"
expect "W1: the mirror session gets no record" "$(entry wa-mirror supervisor-audit:verdict)" "COUNT:0"
seed wa-continue active
audit_cli --session-id wa-continue --set-audit-verdict CONTINUE >/dev/null
expect "W2: --set-audit-verdict CONTINUE records nothing" "$(entry wa-continue supervisor-audit:verdict)" "COUNT:0"
case_end

# ---- the helper itself

case_begin "helper-owns-the-origin" "hooks/lib/auto-record.js"
cat > "$TMP/helper.js" <<'JS'
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const bad = [];
let H = null;
try { H = require(process.env.AGENTS + '/hooks/lib/auto-record.js'); } catch (e) { bad.push('require:' + e.message.split('\n')[0]); }
if (H) {
  let r;
  try { r = H.appendAutoRecord('hp-active', { cls: 'C', step: '-', key: 'probe', summary: 's', pointer: '-', origin: 'procedure-point' }, 'compaction'); }
  catch (e) { bad.push('threw:' + e.message); }
  if (!r || r.written !== true) bad.push('not-written:' + JSON.stringify(r));
  const e = ((S.readRawState('hp-active') || {}).events || []).filter((x) => x && x.kind === 'state_handoff_record' && x.record_key === 'probe');
  if (e.length !== 1 || e[0].origin !== 'auto-record' || e[0].provenance !== 'observed') bad.push('origin-not-forced:' + JSON.stringify(e));
  try { H.appendAutoRecord(null, null, 'not-a-source'); } catch (err) { bad.push('threw-on-garbage:' + err.message); }
}
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS
seed hp-active active
expect "H1: appendAutoRecord forces origin auto-record (provenance observed) into the state file and never throws" "$(nj helper.js)" "OK"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
