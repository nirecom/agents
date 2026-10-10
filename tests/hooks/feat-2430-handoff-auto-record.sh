#!/usr/bin/env bash
# tests/hooks/feat-2430-handoff-auto-record.sh
# Tests: hooks/post-compact.js, hooks/workflow-mark/reset-handler.js, bin/supervisor-write-audit-verdict, bin/supervisor-write-audit, hooks/lib/handoff-auto-record.js
# Tags: handoff, auto-record, post-compact, reset-from, supervisor-verdict, active-period, workflow-off, fail-open, regression-2430, scope:issue-specific, pwsh-not-required, TL2

# Issue #2430 — three events a resuming session cannot reconstruct from the compacted transcript (a compaction, a RESET_FROM rollback, a WARN/BLOCK audit verdict) are recorded mechanically at the code that performs them, as origin auto-record, through the one helper that owns that origin (CPR-SSOT). They are recorded only inside the workflow active period, and a lost breadcrumb never changes the primary job's output or exit code.

# TL3 gap: the real dispatch (Claude Code firing PostCompact, the workflow-mark PostToolUse hook routing a real RESET_FROM echo, the supervisor-audit agent calling the verdict CLI) is not driven; each producer is fed the envelope or argv it receives in production. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.

# TDD (write_code has not run): the "records" cases are expected to FAIL until hooks/lib/handoff-auto-record.js exists and the producers call it; the "records nothing" and "output unchanged" cases already hold today and pin the contract against regression. R3 (C2) is expected to FAIL until reset-handler records the breadcrumb when the session was active BEFORE the reset, not only after it.

set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP="$(make_tmp)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$TMP/wf" "$TMP/home"
export WORKFLOW_STATE_DIR="$(np "$TMP/wf")"
export WORKFLOW_PLANS_DIR="$WORKFLOW_STATE_DIR"
export HOME="$(np "$TMP/home")" USERPROFILE="$(np "$TMP/home")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMP/transcripts")"
export AGENTS="$(np "$SCRIPT_CHECKOUT_ROOT")"
mkdir -p "$TMP/transcripts"
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
const { readHandoff } = require(process.env.AGENTS + '/hooks/lib/handoff-artifact.js');
const [sid, key, cls, step, prefix, pointer] = process.argv.slice(2);
const all = [].concat.apply([], Object.values(readHandoff(sid).entriesByClass || {})).filter((e) => e.key === key);
if (!cls) { process.stdout.write('COUNT:' + all.length); process.exit(0); }
const bad = [];
if (all.length !== 1) bad.push('entries:' + all.length);
else {
  const e = all[0];
  if (e.class !== cls) bad.push('class:' + e.class);
  if (e.step !== step) bad.push('step:' + e.step);
  if (e.origin !== 'auto-record') bad.push('origin:' + e.origin);
  if (String(e.summary).indexOf(prefix) !== 0) bad.push('summary:' + e.summary);
  if (pointer !== '-' && !String(e.pointer).replace(/\\/g, '/').endsWith(pointer)) bad.push('pointer:' + e.pointer);
  if (pointer === '-' && e.pointer !== '-' && e.pointer !== '') bad.push('pointer:' + e.pointer);
}
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
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

nj() { run_with_timeout 60 node "$(np "$TMP/$1")" "${@:2}" 2>&1; }
seed() { nj seed.js "$1" "$2" >/dev/null; }
entry() { nj entry.js "$@"; }
verdict_cli() { run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-write-audit-verdict" "$@" 2>/dev/null; }
audit_cli() { run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-write-audit" "$@" 2>/dev/null; }
compact() { printf '{"session_id":"%s"}' "$1" | run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/hooks/post-compact.js" 2>/dev/null; }
verdict_ptr() { printf '%s' "$1.control/supervisor-state.json"; }

# expect <name> <got> <want> — one verdict line.
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
expect "A1: it records B / compaction / auto-record" \
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
case_end

# ---- RESET_FROM

case_begin "reset-from-success-records" "hooks/workflow-mark/reset-handler.js"
seed rs-ok active
CMD='echo "<<WORKFLOW_RESET_FROM_clarify_intent: redo the intent check>>"'
OUT="$(nj reset.js rs-ok "$CMD")"
expect "R1: the reset itself is applied (no rejection message)" "$OUT" ""
expect "R1: a successful RESET_FROM records E / fromStep / reset-from / auto-record" \
    "$(entry rs-ok reset-from E clarify_intent 'RESET_FROM clarify_intent: redo the intent check' -)" "OK"
case_end

case_begin "reset-from-rejected-records-nothing" "hooks/workflow-mark/reset-handler.js"
seed rs-empty active
CMD='echo "<<WORKFLOW_RESET_FROM_clarify_intent: >>"'
OUT="$(nj reset.js rs-empty "$CMD")"
expect "R2: an empty-reason RESET_FROM is rejected" "$(rejected "$OUT")" "yes"
expect "R2: an empty-reason RESET_FROM records nothing" "$(entry rs-empty reset-from)" "COUNT:0"
seed rs-unknown active
CMD='echo "<<WORKFLOW_RESET_FROM_no_such_step: a valid reason>>"'
OUT="$(nj reset.js rs-unknown "$CMD")"
expect "R2: an unknown-step RESET_FROM is rejected" "$(rejected "$OUT")" "yes"
expect "R2: an unknown-step RESET_FROM records nothing" "$(entry rs-unknown reset-from)" "COUNT:0"
CMD='echo "<<WORKFLOW_RESET_FROM_clarify_intent: a valid reason>>"'
OUT="$(nj reset.js rs-nostate "$CMD")"
expect "R2: a RESET_FROM with no state is rejected" "$(rejected "$OUT")" "yes"
expect "R2: a RESET_FROM with no state records nothing" "$(entry rs-nostate reset-from)" "COUNT:0"
case_end

# ---- RESET_FROM vs the active-period gate (C2): the breadcrumb is recorded when
# the session was active before the reset OR is active after it.

cat > "$TMP/status.js" <<'JS'
// node status.js <sid> <step> — the step's current status, or NOSTATE.
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const st = S.readState(process.argv[2]);
process.stdout.write(st && st.steps && st.steps[process.argv[3]] ? String(st.steps[process.argv[3]].status) : 'NOSTATE');
JS
status() { nj status.js "$1" "$2"; }

case_begin "reset-from-workflow-init-records" "hooks/workflow-mark/reset-handler.js"
seed rs-init active
CMD='echo "<<WORKFLOW_RESET_FROM_workflow_init: restart the whole session>>"'
OUT="$(nj reset.js rs-init "$CMD")"
expect "R3: RESET_FROM_workflow_init is applied (no rejection message)" "$OUT" ""
expect "R3: the reset rolled workflow_init back to pending" "$(status rs-init workflow_init)" "pending"
expect "R3: a reset that ends the active period still records E / workflow_init / reset-from (active before)" \
    "$(entry rs-init reset-from E workflow_init 'RESET_FROM workflow_init: restart the whole session' -)" "OK"
case_end

case_begin "reset-from-mid-step-records" "hooks/workflow-mark/reset-handler.js"
seed rs-mid active
CMD='echo "<<WORKFLOW_RESET_FROM_run_tests: rerun the suite>>"'
OUT="$(nj reset.js rs-mid "$CMD")"
expect "R4: RESET_FROM_run_tests is applied" "$OUT" ""
expect "R4: an active-session reset of a mid step records E / run_tests / reset-from" \
    "$(entry rs-mid reset-from E run_tests 'RESET_FROM run_tests: rerun the suite' -)" "OK"
case_end

case_begin "reset-from-never-active-records-nothing" "hooks/workflow-mark/reset-handler.js"
seed rs-never init-only
CMD='echo "<<WORKFLOW_RESET_FROM_workflow_init: restart the whole session>>"'
OUT="$(nj reset.js rs-never "$CMD")"
expect "R5: a reset on a never-initialised session is still applied" "$OUT" ""
expect "R5: workflow_init stays pending" "$(status rs-never workflow_init)" "pending"
expect "R5: inactive before and after, so nothing is recorded" "$(entry rs-never reset-from)" "COUNT:0"
case_end

case_begin "reset-from-workflow-off-records-nothing" "hooks/workflow-mark/reset-handler.js"
seed rs-off active
: > "$TMP/wf/rs-off.workflow-off"
CMD='echo "<<WORKFLOW_RESET_FROM_run_tests: rerun the suite>>"'
OUT="$(nj reset.js rs-off "$CMD")"
expect "R6: a reset under WORKFLOW_OFF is still applied" "$OUT" ""
expect "R6: run_tests is pending after the reset" "$(status rs-off run_tests)" "pending"
expect "R6: under WORKFLOW_OFF nothing is recorded" "$(entry rs-off reset-from)" "COUNT:0"
case_end

case_begin "reset-from-revives-finished-session-records" "hooks/workflow-mark/reset-handler.js"
seed rs-revive final
CMD='echo "<<WORKFLOW_RESET_FROM_run_tests: reopen after the final report>>"'
OUT="$(nj reset.js rs-revive "$CMD")"
expect "R7: a reset after final_report is applied" "$OUT" ""
expect "R7: final_report is pending again" "$(status rs-revive final_report)" "pending"
expect "R7: a reset that revives a finished session records (active after)" \
    "$(entry rs-revive reset-from E run_tests 'RESET_FROM run_tests: reopen after the final report' -)" "OK"
case_end

# ---- supervisor-write-audit-verdict

case_begin "verdict-warn-block-records" "bin/supervisor-write-audit-verdict"
seed vd-plain active
OUT="$(verdict_cli --session-id vd-plain --verdict WARN --verdict-summary 'drift found')"; RC=$?
expect "V1: the plain-path WARN keeps exit 0" "$RC" "0"
expect "V1: the plain-path WARN keeps its stdout" "$OUT" '{"accepted":true,"audit_run_id":null}'
expect "V1: the plain-path WARN records E / supervisor-audit:verdict" \
    "$(entry vd-plain supervisor-audit:verdict E - 'supervisor audit WARN: drift found' "$(verdict_ptr vd-plain)")" "OK"
seed vd-cas active
RUN="$(nj arm.js vd-cas)"
OUT="$(verdict_cli --session-id vd-cas --audit-run-id "$RUN" --verdict BLOCK --verdict-summary 'stop here')"; RC=$?
expect "V2: the CAS-accepted BLOCK keeps exit 0" "$RC" "0"
expect "V2: the CAS-accepted BLOCK records E / supervisor-audit:verdict" \
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

case_begin "verdict-write-failure-keeps-output" "bin/supervisor-write-audit-verdict"
seed vd-unwritable active
mkdir -p "$TMP/wf/vd-unwritable.control/handoff.md"
OUT="$(verdict_cli --session-id vd-unwritable --verdict WARN --verdict-summary 'drift found')"; RC=$?
expect "V5: an unwritable handoff keeps exit 0" "$RC" "0"
expect "V5: an unwritable handoff keeps stdout" "$OUT" '{"accepted":true,"audit_run_id":null}'
case_end

# ---- supervisor-write-audit --set-audit-verdict

case_begin "set-audit-verdict-records" "bin/supervisor-write-audit"
seed wa-warn active
seed wa-mirror active
audit_cli --session-id wa-warn --mirror-session-id wa-mirror --set-audit-verdict WARN --set-audit-verdict-summary 'drift found' >/dev/null; RC=$?
expect "W1: --set-audit-verdict WARN keeps exit 0" "$RC" "0"
expect "W1: --set-audit-verdict WARN records E / supervisor-audit:verdict" \
    "$(entry wa-warn supervisor-audit:verdict E - 'supervisor audit WARN' "$(verdict_ptr wa-warn)")" "OK"
expect "W1: the mirror store gets no breadcrumb" "$(entry wa-mirror supervisor-audit:verdict)" "COUNT:0"
seed wa-continue active
audit_cli --session-id wa-continue --set-audit-verdict CONTINUE >/dev/null
expect "W2: --set-audit-verdict CONTINUE records nothing" "$(entry wa-continue supervisor-audit:verdict)" "COUNT:0"
case_end

# ---- the helper itself

case_begin "helper-owns-the-origin" "hooks/lib/handoff-auto-record.js"
cat > "$TMP/helper.js" <<'JS'
const H = require(process.env.AGENTS + '/hooks/lib/handoff-auto-record.js');
const { readHandoff } = require(process.env.AGENTS + '/hooks/lib/handoff-artifact.js');
const bad = [];
let r;
try { r = H.appendAutoRecord('hp-active', { cls: 'C', step: '-', key: 'probe', summary: 's', pointer: '-', origin: 'flush' }, 'compaction'); }
catch (e) { bad.push('threw:' + e.message); }
const e = [].concat.apply([], Object.values(readHandoff('hp-active').entriesByClass || {})).filter((x) => x.key === 'probe');
if (e.length !== 1 || e[0].origin !== 'auto-record') bad.push('origin-not-forced:' + JSON.stringify(e));
try { H.appendAutoRecord(null, null, 'not-a-source'); } catch (err) { bad.push('threw-on-garbage:' + err.message); }
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS
seed hp-active active
expect "H1: appendAutoRecord forces origin auto-record and never throws" "$(nj helper.js)" "OK"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
