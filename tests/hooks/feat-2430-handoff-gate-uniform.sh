#!/usr/bin/env bash
# tests/hooks/feat-2430-handoff-gate-uniform.sh
# Tests: bin/workflow/handoff-append, bin/supervisor-report, hooks/lib/handoff-gated-append.js, hooks/lib/handoff-auto-record.js, hooks/workflow-gate/handoff-record.js
# Tags: handoff, active-period, gate, flush-mark, workflow-off, supervisor, regression-2430, scope:issue-specific, pwsh-not-required, TL2

# Issue #2430 — the handoff's only reader is /resume-session, and outside the workflow active period (no state, WORKFLOW_OFF, final_report complete) there is no workflow to resume. So every handoff write — flush, procedure-point, auto-record — goes through one gate and records nothing there, while the primary job of each producer (the supervisor finding, the CLI exit code) is untouched. recordGateBlock is the single named exception and keeps writing; this file pins that so a later diff cannot change it silently. A successful flush also leaves a flush mark sized from the session's own transcript, which the omission-check nudge measures from.

# TL3 gap: the model-side flush (a real session deciding to run handoff-append) and the transcript Claude Code itself writes are not driven; the CLI is invoked with the argv the flush rule prescribes and the transcript is a planted fixture file. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.

# TDD (write_code has not run): the inactive "records nothing" cases, the procedure-point origin, the auto-record helper and the flush mark are expected to FAIL until the gate (hooks/lib/handoff-gated-append.js), the renamed origin and recordFlushMark exist; the gate-block exception and the supervisor finding cases already hold.

set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP="$(make_tmp)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$TMP/wf" "$TMP/home" "$TMP/transcripts/c--fixture-project"
export WORKFLOW_STATE_DIR="$(np "$TMP/wf")"
export WORKFLOW_PLANS_DIR="$WORKFLOW_STATE_DIR"
export HOME="$(np "$TMP/home")" USERPROFILE="$(np "$TMP/home")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMP/transcripts")"
export AGENTS="$(np "$SCRIPT_CHECKOUT_ROOT")"
cd "$TMP" || exit 1

cat > "$TMP/seed.js" <<'JS'
// node seed.js <sid> <active|off|final|paused|none>
const fs = require('fs');
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const [sid, mode] = process.argv.slice(2);
if (mode !== 'none') {
  S.writeState(sid, S.createInitialState(sid, { cwd: '/x', git_branch: 'feature/x' }));
  S.markStep(sid, 'workflow_init', 'complete');
  if (mode === 'final') S.markStep(sid, 'final_report', 'complete');
  if (mode === 'off') fs.writeFileSync(process.env.WORKFLOW_STATE_DIR + '/' + sid + '.workflow-off', '');
  if (mode === 'paused') {
    // The real v2 marker, scoped to the step the session is on right now.
    const step = require(process.env.AGENTS + '/hooks/workflow-state/current-step').resolveCurrentEffectiveStep(sid);
    require(process.env.AGENTS + '/hooks/lib/next-step-pause-marker').writePauseMarker(sid, { reason: '[for=' + step + '] fixture pause' });
  }
}
JS
cat > "$TMP/count.js" <<'JS'
// node count.js <sid> <key> — COUNT:<entries with that key>
const { readHandoff } = require(process.env.AGENTS + '/hooks/lib/handoff-artifact.js');
const [sid, key] = process.argv.slice(2);
const n = [].concat.apply([], Object.values(readHandoff(sid).entriesByClass || {})).filter((e) => e.key === key).length;
process.stdout.write('COUNT:' + n);
JS
cat > "$TMP/lib.js" <<'JS'
// node lib.js <gate|auto> <sid> — drive one library producer.
const A = process.env.AGENTS;
const [what, sid] = process.argv.slice(2);
let r;
if (what === 'gate') r = require(A + '/hooks/workflow-gate/handoff-record.js').recordGateBlock(sid, 'blocked for the fixture', { command: 'git push' });
if (what === 'auto') r = require(A + '/hooks/lib/handoff-auto-record.js').appendAutoRecord(sid, { cls: 'B', step: '-', key: 'auto-probe', summary: 'probe', pointer: '-', origin: 'auto-record' }, 'compaction');
process.stdout.write(JSON.stringify(r));
JS
cat > "$TMP/mark.js" <<'JS'
// node mark.js <sid> <wantBytes> <sinceMs> — OK / NONE / BAD:...
const fs = require('fs');
const [sid, want, since] = process.argv.slice(2);
let raw;
try { raw = fs.readFileSync(process.env.WORKFLOW_STATE_DIR + '/' + sid + '.control/handoff-flush-mark.json', 'utf8'); }
catch (e) { process.stdout.write('NONE'); process.exit(0); }
const bad = [];
let j = {};
try { j = JSON.parse(raw); } catch (e) { bad.push('unparseable'); }
if (j.bytes !== (want === 'null' ? null : Number(want))) bad.push('bytes:' + j.bytes);
const at = new Date(j.at).getTime();
if (!(at >= Number(since) - 1000 && at <= Date.now() + 1000)) bad.push('at:' + j.at);
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS

nj() { run_with_timeout 60 node "$(np "$TMP/$1")" "${@:2}" 2>&1; }
seed() { nj seed.js "$1" "$2" >/dev/null; }
count() { nj count.js "$1" "$2"; }
now_ms() { run_with_timeout 10 node -e "process.stdout.write(String(Date.now()))"; }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$3 got=${2:0:300}"; fi; }
# append <sid> <origin> <key> — the flush-rule argv; prints "<stdout>|rc=<n>".
append() {
    local out rc
    out="$(run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/workflow/handoff-append" --session "$1" --class D --step - --key "$3" --summary 'a workaround the fixture took' --pointer - --origin "$2" 2>/dev/null)"; rc=$?
    printf '%s|rc=%s' "$out" "$rc"
}
report() {
    run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-report" --session-id "$1" --categories workflow --severity warning --detail 'fixture finding' --reporter write-tests >/dev/null 2>&1
}
# transcript <sid> — plant the session transcript; prints its size in bytes.
transcript() {
    printf '{"type":"user","message":"fixture line"}\n%.0s' 1 2 3 4 5 > "$TMP/transcripts/c--fixture-project/$1.jsonl"
    wc -c < "$TMP/transcripts/c--fixture-project/$1.jsonl" | tr -d ' '
}

# The four ways to be outside the active period, each its own session.
MODES="none off final paused"
for mode in $MODES; do seed "gu-$mode" "$mode"; transcript "gu-$mode" >/dev/null; done

case_begin "inactive-period-cli-records-nothing" "bin/workflow/handoff-append"
for mode in $MODES; do
    sid="gu-$mode"
    expect "G1[$mode]: --origin flush prints WRITTEN=0 REASON=inactive and exits 0" "$(append "$sid" flush fl-probe)" "WRITTEN=0 REASON=inactive|rc=0"
    expect "G1[$mode]: --origin flush records nothing" "$(count "$sid" fl-probe)" "COUNT:0"
    expect "G1[$mode]: a gated-out flush leaves no flush mark" "$(nj mark.js "$sid" 0 0)" "NONE"
    expect "G1[$mode]: --origin procedure-point prints WRITTEN=0 REASON=inactive and exits 0" "$(append "$sid" procedure-point pp-probe)" "WRITTEN=0 REASON=inactive|rc=0"
    expect "G1[$mode]: --origin procedure-point records nothing" "$(count "$sid" pp-probe)" "COUNT:0"
done
case_end

case_begin "inactive-supervisor-report-keeps-its-finding" "bin/supervisor-report"
for mode in $MODES; do
    sid="gu-$mode"
    report "$sid"; rc=$?
    expect "G2[$mode]: supervisor-report still exits 0" "$rc" "0"
    expect "G2[$mode]: supervisor-report still writes the finding" "$([ -f "$TMP/wf/$sid.control/supervisor-state.json" ] && echo yes || echo no)" "yes"
    expect "G2[$mode]: supervisor-report records no handoff entry" "$(count "$sid" supervisor-reported)" "COUNT:0"
done
case_end

case_begin "inactive-auto-record-records-nothing" "hooks/lib/handoff-auto-record.js"
for mode in $MODES; do
    sid="gu-$mode"
    expect "G3[$mode]: appendAutoRecord reports inactive" "$(nj lib.js auto "$sid")" '{"written":false,"reason":"inactive"}'
    expect "G3[$mode]: appendAutoRecord records nothing" "$(count "$sid" auto-probe)" "COUNT:0"
done
case_end

case_begin "gate-block-is-the-named-exception" "hooks/workflow-gate/handoff-record.js"
for mode in $MODES; do
    expect "G4[$mode]: recordGateBlock still writes outside the active period" "$(nj lib.js gate "gu-$mode")" '{"written":true,"reason":"ok"}'
done
case_end

case_begin "active-period-every-path-records" "hooks/lib/handoff-gated-append.js"
sid="gu-active"
seed "$sid" active
expect "G5: --origin flush writes" "$(append "$sid" flush fl-probe)" "WRITTEN=1 REASON=ok|rc=0"
expect "G5: --origin procedure-point writes" "$(append "$sid" procedure-point pp-probe)" "WRITTEN=1 REASON=ok|rc=0"
report "$sid"
expect "G5: supervisor-report records its entry" "$(count "$sid" supervisor-reported)" "COUNT:1"
nj lib.js auto "$sid" >/dev/null
expect "G5: appendAutoRecord records its entry" "$(count "$sid" auto-probe)" "COUNT:1"
expect "G5: recordGateBlock writes" "$(nj lib.js gate "$sid")" '{"written":true,"reason":"ok"}'
cat > "$TMP/gated.js" <<'JS'
const G = require(process.env.AGENTS + '/hooks/lib/handoff-gated-append.js');
const e = { cls: 'D', step: '-', key: 'gated-probe', summary: 's', pointer: '-', origin: 'flush' };
const out = [JSON.stringify(G.appendHandoffEntryIfActive('gu-active', e)), JSON.stringify(G.appendHandoffEntryIfActive('gu-none', e))];
try { out.push(JSON.stringify(G.appendHandoffEntryIfActive(null, null))); } catch (err) { out.push('threw:' + err.message); }
process.stdout.write(out.join(' '));
JS
expect "G5: appendHandoffEntryIfActive writes when active, reports inactive otherwise, never throws" "$(nj gated.js)" \
    '{"written":true,"reason":"ok"} {"written":false,"reason":"inactive"} {"written":false,"reason":"inactive"}'
case_end

case_begin "flush-mark-follows-a-successful-flush" "bin/workflow/handoff-append"
sid="gu-mark"
seed "$sid" active
SIZE="$(transcript "$sid")"; T="$(now_ms)"
append "$sid" flush mark-probe >/dev/null
expect "G6: a successful flush writes a mark sized from the session transcript" "$(nj mark.js "$sid" "$SIZE" "$T")" "OK"
sid="gu-mark-pp"
seed "$sid" active; transcript "$sid" >/dev/null
append "$sid" procedure-point mark-probe >/dev/null
expect "G6: a procedure-point write leaves no flush mark" "$(nj mark.js "$sid" 0 0)" "NONE"
sid="gu-mark-notranscript"
seed "$sid" active; T="$(now_ms)"
OUT="$(append "$sid" flush mark-probe)"
expect "G6: a flush without a transcript still writes" "$OUT" "WRITTEN=1 REASON=ok|rc=0"
expect "G6: a flush without a transcript marks bytes null" "$(nj mark.js "$sid" null "$T")" "OK"
sid="gu-mark-rejected"
seed "$sid" active; transcript "$sid" >/dev/null
run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/workflow/handoff-append" --session "$sid" --class Z --step - --key rej --summary s --pointer - --origin flush >/dev/null 2>&1; RC=$?
expect "G6: a flush with an invalid class is rejected (exit 2)" "$RC" "2"
expect "G6: a rejected flush leaves no flush mark" "$(nj mark.js "$sid" 0 0)" "NONE"
cat > "$TMP/badmark.js" <<'JS'
const fs = require('fs');
const P = require(process.env.AGENTS + '/hooks/lib/handoff-pressure.js');
const bad = [];
if (typeof P.recordFlushMark !== 'function') bad.push('recordFlushMark-not-exported');
else for (const sid of ['../escape', '', null]) { try { P.recordFlushMark(sid, null, new Date().toISOString()); } catch (e) { bad.push('threw:' + e.message); } }
const W = process.env.WORKFLOW_STATE_DIR;
if ([W, W + '/..'].some((d) => fs.readdirSync(d).some((f) => f.indexOf('escape') !== -1 || f === '-handoff-flush-mark.json' || f === '.control'))) bad.push('invalid-sid-written');
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS
expect "G6: recordFlushMark with an invalid sid writes nothing and never throws" "$(nj badmark.js)" "OK"
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
require('fs').writeFileSync(ctlDir + '/handoff-pressure.json',
  JSON.stringify({ baseline_bytes: 0, baseline_at: new Date(Date.now() - 2 * 3600 * 1000).toISOString() }));
JS
# nudge <sid> — the UserPromptSubmit payload Claude Code sends; prints the hook's stdout.
nudge() {
    local tp
    tp="$(np "$TMP/transcripts/c--fixture-project/$1.jsonl")"
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"go"}' "$1" "$tp" "$(np "$TMP")" \
        | run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/hooks/handoff-pressure-nudge.js" 2>/dev/null
}

case_begin "paused-mode-is-a-live-step-scoped-pause" "hooks/lib/handoff-gated-append.js"
# Non-vacuity for the paused mode: the marker is scoped to the current step (not
# session-wide), unexpired, and it is the only thing taking the session out of the period.
OUT="$(nj pausecheck.js gu-paused)"
expect "G7: the paused session carries a live pause scoped to its current step, so it is outside the period" "$OUT" "scoped:true:false"
rm -f "$TMP/wf/gu-paused.next-step-paused"
expect "G7: the same session without the pause marker is inside the period" "$(nj pausecheck.js gu-paused)" "for=undefined:false:true"
seed gu-paused paused
expect "G7: re-pausing restores the step-scoped live pause" "$(nj pausecheck.js gu-paused)" "scoped:true:false"
case_end

case_begin "inactive-nudge-stays-silent" "hooks/lib/handoff-gated-append.js"
seed gu-nudge-ctl active; transcript gu-nudge-ctl >/dev/null; nj stale.js gu-nudge-ctl >/dev/null
OUT="$(nudge gu-nudge-ctl)"
expect "G8[control]: an active session with a stale baseline gets the omission-check nudge" \
    "$(case "$OUT" in *'[handoff check]'*) echo fired ;; *) echo "other:${OUT:0:120}" ;; esac)" "fired"
for mode in $MODES; do
    sid="gu-$mode"
    nj stale.js "$sid" >/dev/null
    expect "G8[$mode]: the nudge hook prints {} outside the active period" "$(nudge "$sid")" "{}"
done
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
