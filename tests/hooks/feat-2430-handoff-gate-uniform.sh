#!/usr/bin/env bash
# tests/hooks/feat-2430-handoff-gate-uniform.sh
# Tests: bin/workflow/handoff-append, bin/supervisor-report, hooks/workflow-gate/handoff-record.js
# Tags: handoff, active-period, gate, flush-mark, workflow-off, supervisor, regression-2430, regression-2594, regression-2578, regression-2652, state-handoff-record, progress-nudge, scope:issue-specific, pwsh-not-required, TL2

# Issue #2430 — outside the window where a workflow can be resumed there is nothing to hand over, so every state handoff record write goes through one period check and records nothing there, while the primary job of each producer (the supervisor finding, the CLI exit code, the gate's block) is untouched. #2652 moves the records into the state file and makes the check the same for every writer: the period is "workflow_init complete and no terminal step complete" only, so NEXT_STEP_PAUSE and WORKFLOW_OFF no longer silence a record (#2578), and gate-block stops being the one writer that records outside the period. The progress nudge still asks the unchanged active-period predicate, so it stays quiet while paused or off.
# Header note: hooks/lib/state-handoff-record.js and hooks/lib/auto-record.js are case targets but not header tokens — the #2502 language gate refuses a new js token in a bash header; the deleted handoff-gated-append.js / handoff-auto-record.js tokens were dropped.

# TL3 gap: the model-side call (a real session deciding to run handoff-append) and the transcript Claude Code itself writes are not driven; the CLI is invoked with the argv the handoff-record procedure prescribes and the transcript is a planted fixture file. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.

# TDD (write_code has not run): every row that reads the state file's state_handoff_record events, the outside-period / no-state stderr line, the paused/off writes and the gate-block period check is expected to FAIL until hooks/lib/state-handoff-record.js and hooks/lib/auto-record.js exist; the supervisor finding, the flush-mark retirement, the pause fixture and the nudge rows already hold.

set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP="$(make_tmp)"
readonly TMP
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$TMP/wf" "$TMP/home" "$TMP/transcripts/c--fixture-project"
export WORKFLOW_STATE_DIR="$(np "$TMP/wf")"
export WORKFLOW_PLANS_DIR="$WORKFLOW_STATE_DIR"
export HOME="$(np "$TMP/home")" USERPROFILE="$(np "$TMP/home")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMP/transcripts")"
export AGENTS="$(np "$SCRIPT_CHECKOUT_ROOT")"
unset CLAUDE_CODE_SESSION_ID
cd "$TMP" || exit 1

cat > "$TMP/seed.js" <<'JS'
// node seed.js <sid> <active|init|off|final|paused|none>
const fs = require('fs');
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const [sid, mode] = process.argv.slice(2);
if (mode !== 'none') {
  S.writeState(sid, S.createInitialState(sid, { cwd: '/x', git_branch: 'feature/x' }));
  if (mode !== 'init') S.markStep(sid, 'workflow_init', 'complete');
  if (mode === 'final') S.markStep(sid, 'final_report', 'complete');
  if (mode === 'off') fs.writeFileSync(process.env.WORKFLOW_STATE_DIR + '/' + sid + '.workflow-off', '');
  if (mode === 'paused') {
    // The real v2 marker, scoped to the step the session is on right now.
    const step = require(process.env.AGENTS + '/hooks/workflow-state/current-step').resolveCurrentEffectiveStep(sid);
    require(process.env.AGENTS + '/hooks/lib/next-step-pause-marker').writePauseMarker(sid, { reason: '[for=' + step + '] fixture pause' });
  }
}
JS
cat > "$TMP/rec.js" <<'JS'
// node rec.js <sid> <key> — COUNT:<n> for that key's state_handoff_record events,
// then the last one's "cls/origin/provenance" when n > 0.
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const [sid, key] = process.argv.slice(2);
let events = [];
try { events = ((S.readRawState(sid) || {}).events || []); } catch (e) { events = []; }
const recs = events.filter((e) => e && e.kind === 'state_handoff_record' && e.record_key === key);
const last = recs[recs.length - 1];
process.stdout.write('COUNT:' + recs.length + (last ? ' ' + [last.cls, last.origin, last.provenance].join('/') : ''));
JS
cat > "$TMP/lib.js" <<'JS'
// node lib.js <gate|auto> <sid> — drive one library writer; prints W:true or W:false:<reason>.
const A = process.env.AGENTS;
const [what, sid] = process.argv.slice(2);
let r;
try {
  if (what === 'gate') r = require(A + '/hooks/workflow-gate/handoff-record.js').recordGateBlock(sid, 'blocked for the fixture', { command: 'git push' });
  if (what === 'auto') r = require(A + '/hooks/lib/auto-record.js').appendAutoRecord(sid, { cls: 'B', step: '-', key: 'auto-probe', summary: 'probe', pointer: '-', origin: 'auto-record' }, 'compaction');
} catch (e) { process.stdout.write('THREW:' + e.message); process.exit(0); }
process.stdout.write(r && r.written === true ? 'W:true' : 'W:false:' + (r && r.reason));
JS
cat > "$TMP/mark.js" <<'JS'
// node mark.js <sid> — NONE when no flush mark exists, FOUND otherwise.
const fs = require('fs');
process.stdout.write(fs.existsSync(process.env.WORKFLOW_STATE_DIR + '/' + process.argv[2] + '.control/handoff-flush-mark.json') ? 'FOUND' : 'NONE');
JS

nj() { run_with_timeout 60 node "$(np "$TMP/$1")" "${@:2}" 2>&1; }
seed() { nj seed.js "$1" "$2" >/dev/null; }
rec() { nj rec.js "$1" "$2"; }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$3 got=${2:0:300}"; fi; }
# append <sid> <origin> <key> — the handoff-record argv; leaves rc in APPEND_RC,
# stdout in $TMP/append.out and stderr in $TMP/append.err.
append() {
    run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/workflow/handoff-append" --session "$1" --class D --step - --key "$3" --summary 'a workaround the fixture took' --pointer - --origin "$2" >"$TMP/append.out" 2>"$TMP/append.err"
    APPEND_RC=$?
}
# refusal <reason> — "rc=0 lines=1 reason=yes" when the last append exited 0, wrote one
# stderr line, and named the reason token on stdout or stderr.
refusal() {
    local lines named
    lines="$(grep -c . "$TMP/append.err" 2>/dev/null)"
    named=no; grep -q -- "$1" "$TMP/append.out" "$TMP/append.err" 2>/dev/null && named=yes
    printf 'rc=%s lines=%s reason=%s' "$APPEND_RC" "${lines:-0}" "$named"
}
# written — "rc=<n> <count of WRITTEN=1>" for the last append.
written() { printf 'rc=%s %s' "$APPEND_RC" "$(grep -c 'WRITTEN=1' "$TMP/append.out")"; }
report() {
    run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-report" --session-id "$1" --categories workflow --severity warning --detail 'fixture finding' --reporter write-tests >/dev/null 2>&1
}
transcript() {
    printf '{"type":"user","message":"fixture line"}\n%.0s' 1 2 3 4 5 > "$TMP/transcripts/c--fixture-project/$1.jsonl"
}
# reason_for <mode> — the refusal reason each outside mode must carry.
reason_for() { if [ "$1" = none ]; then echo no-state; else echo outside-period; fi; }

# The three ways to be outside the recording period, and the two that no longer are (#2578).
OUTSIDE="none init final"
INSIDE="paused off"
for mode in $OUTSIDE $INSIDE; do seed "gu-$mode" "$mode"; transcript "gu-$mode"; done

case_begin "inactive-period-cli-records-nothing" "bin/workflow/handoff-append"
for mode in $OUTSIDE; do
    sid="gu-$mode"; why="$(reason_for "$mode")"
    append "$sid" procedure-point pp-probe
    expect "G1[$mode]: --origin procedure-point exits 0, prints one stderr line, names $why" "$(refusal "$why")" "rc=0 lines=1 reason=yes"
    expect "G1[$mode]: --origin procedure-point records nothing" "$(rec "$sid" pp-probe)" "COUNT:0"
done
expect "G1[none]: a refused write creates no state file" "$([ -e "$TMP/wf/gu-none.json" ] && echo created || echo none)" "none"
for mode in $INSIDE; do
    append "gu-$mode" procedure-point pp-probe
    expect "G1[$mode]: --origin procedure-point still writes while $mode (#2578)" "$(written)" "rc=0 1"
    expect "G1[$mode]: one class D procedure-point record lands in the state file" "$(rec "gu-$mode" pp-probe)" "COUNT:1 D/procedure-point/declared"
done
case_end

case_begin "inactive-supervisor-report-keeps-its-finding" "bin/supervisor-report"
for mode in $OUTSIDE; do
    sid="gu-$mode"
    report "$sid"; rc=$?
    expect "G2[$mode]: supervisor-report still exits 0" "$rc" "0"
    expect "G2[$mode]: supervisor-report still writes the finding" "$([ -f "$TMP/wf/$sid.control/supervisor-state.json" ] && echo yes || echo no)" "yes"
    expect "G2[$mode]: supervisor-report records no state handoff record" "$(rec "$sid" supervisor-reported)" "COUNT:0"
done
for mode in $INSIDE; do
    report "gu-$mode"
    expect "G2[$mode]: supervisor-report records class E supervisor-reported while $mode" "$(rec "gu-$mode" supervisor-reported)" "COUNT:1 E/procedure-point/declared"
done
case_end

case_begin "inactive-auto-record-records-nothing" "hooks/lib/auto-record.js"
for mode in $OUTSIDE; do
    sid="gu-$mode"
    expect "G3[$mode]: appendAutoRecord reports $(reason_for "$mode")" "$(nj lib.js auto "$sid")" "W:false:$(reason_for "$mode")"
    expect "G3[$mode]: appendAutoRecord records nothing" "$(rec "$sid" auto-probe)" "COUNT:0"
done
for mode in $INSIDE; do
    expect "G3[$mode]: appendAutoRecord writes while $mode" "$(nj lib.js auto "gu-$mode")" "W:true"
    expect "G3[$mode]: the record is class B auto-record, observed" "$(rec "gu-$mode" auto-probe)" "COUNT:1 B/auto-record/observed"
done
case_end

case_begin "gate-block-follows-the-recording-period" "hooks/workflow-gate/handoff-record.js"
for mode in $OUTSIDE; do
    sid="gu-$mode"
    expect "G4[$mode]: recordGateBlock is refused outside the period ($(reason_for "$mode"))" "$(nj lib.js gate "$sid")" "W:false:$(reason_for "$mode")"
    expect "G4[$mode]: recordGateBlock records nothing" "$(rec "$sid" gate:block)" "COUNT:0"
done
for mode in $INSIDE; do
    expect "G4[$mode]: recordGateBlock writes while $mode" "$(nj lib.js gate "gu-$mode")" "W:true"
    expect "G4[$mode]: the record is class C gate:block, gate-block, observed" "$(rec "gu-$mode" gate:block)" "COUNT:1 C/gate-block/observed"
done
case_end

case_begin "active-period-every-path-records" "hooks/lib/state-handoff-record.js"
sid="gu-active"
seed "$sid" active
append "$sid" procedure-point pp-probe
expect "G5: --origin procedure-point exits 0 and reports WRITTEN=1" "$(written)" "rc=0 1"
expect "G5: the CLI record lands in the state file" "$(rec "$sid" pp-probe)" "COUNT:1 D/procedure-point/declared"
report "$sid"
expect "G5: supervisor-report records its entry" "$(rec "$sid" supervisor-reported)" "COUNT:1 E/procedure-point/declared"
nj lib.js auto "$sid" >/dev/null
expect "G5: appendAutoRecord records its entry" "$(rec "$sid" auto-probe)" "COUNT:1 B/auto-record/observed"
nj lib.js gate "$sid" >/dev/null
expect "G5: recordGateBlock records its entry" "$(rec "$sid" gate:block)" "COUNT:1 C/gate-block/observed"
cat > "$TMP/direct.js" <<'JS'
const W = require(process.env.AGENTS + '/hooks/lib/state-handoff-record.js');
const e = { cls: 'D', step: '-', key: 'direct-probe', summary: 's', pointer: '-', origin: 'procedure-point' };
const fmt = (r) => (r && r.written === true ? 'W:true' : 'W:false:' + (r && r.reason));
const out = [fmt(W.appendStateHandoffRecord('gu-active', e)), fmt(W.appendStateHandoffRecord('gu-final', e)), fmt(W.appendStateHandoffRecord('gu-none', e))];
try { out.push(fmt(W.appendStateHandoffRecord(null, null))); } catch (err) { out.push('threw:' + err.message); }
process.stdout.write(out.join(' '));
JS
expect "G5: appendStateHandoffRecord writes when inside, reports outside-period / no-state otherwise, never throws" "$(nj direct.js)" \
    'W:true W:false:outside-period W:false:no-state W:false:invalid'
case_end

# #2594 retired the flush mark, and #2652 retires the flush origin itself: the CLI refuses it
# with the usage, and nothing — record or mark — is left behind.
case_begin "flush-is-refused-and-leaves-no-mark" "bin/workflow/handoff-append"
sid="gu-mark"
seed "$sid" active
transcript "$sid"
append "$sid" flush mark-probe
expect "G6: --origin flush exits 2" "$APPEND_RC" "2"
expect "G6: a refused flush records nothing" "$(rec "$sid" mark-probe)" "COUNT:0"
expect "G6: a refused flush leaves no flush mark" "$(nj mark.js "$sid")" "NONE"
append "$sid" procedure-point mark-probe
expect "G6: a procedure-point write leaves no flush mark" "$(nj mark.js "$sid")" "NONE"
cat > "$TMP/nomark.js" <<'JS'
// The progress-pressure lib owns no flush-mark writer, and the old lib is gone.
const fs = require('fs');
const A = process.env.AGENTS;
const bad = [];
let P = null;
try { P = require(A + '/hooks/lib/progress-pressure.js'); } catch (e) { bad.push('progress-pressure-missing'); }
if (P && typeof P.recordFlushMark !== 'undefined') bad.push('recordFlushMark-still-exported');
if (fs.existsSync(A + '/hooks/lib/handoff-pressure.js')) bad.push('handoff-pressure.js-still-present');
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS
expect "G6: no flush-mark writer is left (progress-pressure.js exports none, handoff-pressure.js is gone)" "$(nj nomark.js)" "OK"
case_end

cat > "$TMP/pausecheck.js" <<'JS'
// node pausecheck.js <sid> — "<step>:<pause live for it>:<active period>"
const A = process.env.AGENTS;
const sid = process.argv[2];
const step = require(A + '/hooks/workflow-state/current-step').resolveCurrentEffectiveStep(sid);
const m = require(A + '/hooks/lib/next-step-pause-marker').readPauseMarker(sid) || {};
const live = require(A + '/hooks/lib/next-step-pause-marker').isPauseActive(sid, step);
const active = require(A + '/hooks/lib/workflow-active-period.js').isWorkflowActivePeriod(sid);
process.stdout.write((m.for_step === step ? 'scoped' : 'for=' + m.for_step) + ':' + live + ':' + active);
JS
cat > "$TMP/stale.js" <<'JS'
// node stale.js <sid> — a baseline two hours old at 0 bytes, so any transcript fires "elapsed".
const ctlDir = process.env.WORKFLOW_STATE_DIR + '/' + process.argv[2] + '.control';
require('fs').mkdirSync(ctlDir, { recursive: true });
require('fs').writeFileSync(ctlDir + '/progress-pressure.json',
  JSON.stringify({ baseline_bytes: 0, baseline_at: new Date(Date.now() - 2 * 3600 * 1000).toISOString() }));
JS
# nudge <sid> — the UserPromptSubmit payload Claude Code sends to the #2594 progress nudge.
nudge() {
    local tp
    tp="$(np "$TMP/transcripts/c--fixture-project/$1.jsonl")"
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"go"}' "$1" "$tp" "$(np "$TMP")" \
        | run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/hooks/progress-nudge.js" 2>/dev/null
}
quiet_or() { case "$(printf '%s' "$1" | tr -d ' \r\n')" in ''|'{}') echo quiet ;; *) echo "other:${1:0:120}" ;; esac; }

# The active-period predicate itself is unchanged by #2652 (its users are now the progress
# nudge and post-compact); this pins that the paused fixture really is outside it.
case_begin "paused-mode-is-a-live-step-scoped-pause" "hooks/lib/workflow-active-period.js"
OUT="$(nj pausecheck.js gu-paused)"
expect "G7: the paused session carries a live pause scoped to its current step, so it is outside the active period" "$OUT" "scoped:true:false"
rm -f "$TMP/wf/gu-paused.next-step-paused"
expect "G7: the same session without the pause marker is inside the active period" "$(nj pausecheck.js gu-paused)" "for=undefined:false:true"
seed gu-paused paused
expect "G7: re-pausing restores the step-scoped live pause" "$(nj pausecheck.js gu-paused)" "scoped:true:false"
case_end

case_begin "inactive-nudge-stays-silent" "hooks/lib/workflow-active-period.js"
seed gu-nudge-ctl active; transcript gu-nudge-ctl; nj stale.js gu-nudge-ctl >/dev/null
OUT="$(nudge gu-nudge-ctl)"
expect "G8[control]: an active session with a stale baseline gets the progress request" \
    "$(case "$OUT" in *'[progress check]'*) echo fired ;; *) echo "other:${OUT:0:120}" ;; esac)" "fired"
for mode in none off final paused; do
    sid="gu-$mode"
    nj stale.js "$sid" >/dev/null
    expect "G8[$mode]: the progress nudge prints nothing or {} outside the active period" "$(quiet_or "$(nudge "$sid")")" "quiet"
done
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
