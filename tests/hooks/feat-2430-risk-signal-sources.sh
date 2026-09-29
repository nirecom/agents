#!/usr/bin/env bash
# tests/hooks/feat-2430-risk-signal-sources.sh
# Tests: hooks/lib/handoff-risk-signal.js, hooks/post-compact.js, hooks/workflow-gate/handoff-record.js, hooks/workflow-mark/reset-handler.js, bin/supervisor-write-audit-verdict, bin/supervisor-write-audit, hooks/lib/supervisor-state-writer/append.js, hooks/workflow-run-tests.js
# Tags: handoff, risk-signal, nudge-trigger, post-compact, gate-block, reset-from, supervisor-verdict, supervisor-finding, run-tests, fail-open, regression-2430, scope:issue-specific, pwsh-not-required, TL2

# Issue #2430 — a "risk" is an event after which unrecorded working knowledge is most likely to be lost, so the omission-check nudge restarts its timer and halves its limits. Six producers stamp <PLANS_DIR>/<sid>-handoff-risk.json; everything else must leave it alone, or the halved limits become the permanent default. A test failure while tests are expected to be red (write_tests / review_tests / write_code) is the named exception.

# TL3 gap: the real dispatch of each producer (PostCompact, a live workflow-gate block, the PostToolUse run-tests hook after a real suite run) is not driven; each is fed the envelope or call it receives in production. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.

# TDD (write_code has not run): the "records" cases are expected to FAIL until hooks/lib/handoff-risk-signal.js exists and the six producers call it; the "records nothing" and "output unchanged" cases hold today and pin the contract.

set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"

TMP="$(make_tmp)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$TMP/wf" "$TMP/home" "$TMP/transcripts"
export CLAUDE_WORKFLOW_DIR="$(np "$TMP/wf")"
export WORKFLOW_PLANS_DIR="$CLAUDE_WORKFLOW_DIR"
export HOME="$(np "$TMP/home")" USERPROFILE="$(np "$TMP/home")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMP/transcripts")"
export AGENTS="$(np "$AGENTS_DIR")"
cd "$TMP" || exit 1

cat > "$TMP/seed.js" <<'JS'
// node seed.js <sid> [currentStep] — active state; with currentStep, every earlier
// step is settled (approval-gated ones skipped) and the result is verified.
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const { APPROVAL_GATED_STEPS } = require(process.env.AGENTS + '/hooks/workflow-state/completion-approval');
const { resolveCurrentEffectiveStep } = require(process.env.AGENTS + '/hooks/workflow-state/current-step');
const [sid, target] = process.argv.slice(2);
S.writeState(sid, S.createInitialState(sid, { cwd: '/x', git_branch: 'feature/x' }));
S.markStep(sid, 'workflow_init', 'complete');
if (target) {
  for (const step of S.VALID_STEPS.slice(1, S.VALID_STEPS.indexOf(target))) {
    S.markStep(sid, step, APPROVAL_GATED_STEPS.includes(step) ? 'skipped' : 'complete');
  }
  const cur = resolveCurrentEffectiveStep(sid);
  if (cur !== target) process.stdout.write('SEEDFAIL:current=' + cur);
}
JS
cat > "$TMP/risk.js" <<'JS'
// node risk.js <sid> <sinceMs> — "<source>" when a fresh stamp exists, NONE when absent.
const fs = require('fs');
const [sid, since] = process.argv.slice(2);
let raw;
try { raw = fs.readFileSync(process.env.WORKFLOW_PLANS_DIR + '/' + sid + '-handoff-risk.json', 'utf8'); }
catch (e) { process.stdout.write('NONE'); process.exit(0); }
let j;
try { j = JSON.parse(raw); } catch (e) { process.stdout.write('UNPARSEABLE'); process.exit(0); }
const at = new Date(j.last_risk_at).getTime();
if (!(at >= Number(since) - 1000 && at <= Date.now() + 1000)) { process.stdout.write('STALE:' + JSON.stringify(j)); process.exit(0); }
process.stdout.write(String(j.source));
JS
cat > "$TMP/call.js" <<'JS'
// node call.js <what> <sid> [arg] — drive a library producer; prints its return.
const A = process.env.AGENTS;
const [what, sid, arg] = process.argv.slice(2);
let r;
if (what === 'gate') r = require(A + '/hooks/workflow-gate/handoff-record.js').recordGateBlock(sid, 'blocked for the fixture', { command: 'git push' });
if (what === 'finding') r = require(A + '/hooks/lib/supervisor-state-writer').appendFinding(sid, { categories: ['workflow'], severity: arg, detail: 'fixture finding', reporter: 'write-tests' });
if (what === 'reset') {
  const msgs = [];
  require(A + '/hooks/workflow-mark/reset-handler').handle({ cmd: arg, sessionId: sid, pushMessage: (m) => msgs.push(m), signalFatal: (m) => msgs.push(m), repoCwd: process.cwd() });
  r = msgs.join(' ');
}
process.stdout.write(typeof r === 'string' ? r : JSON.stringify(r));
JS

cat > "$TMP/observed.js" <<'JS'
// node observed.js <sid> — "yes" when the run-tests hook recorded a failed run (non-vacuity guard).
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const st = S.readState(process.argv[2]);
process.stdout.write(JSON.stringify((st && st.steps && st.steps.run_tests) || {}).indexOf('"last_run_failed":true') !== -1 ? 'yes' : 'no');
JS

nj() { run_with_timeout 60 node "$(np "$TMP/$1")" "${@:2}" 2>&1; }
seed() { local o; o="$(nj seed.js "$@")"; [ -z "$o" ] || fail "fixture seed for $1" "$o"; }
now_ms() { run_with_timeout 10 node -e "process.stdout.write(String(Date.now()))"; }
risk() { nj risk.js "$1" "$2"; }
compact() { printf '{"session_id":"%s"}' "$1" | run_with_timeout 60 node "$AGENTS_DIR/hooks/post-compact.js" 2>/dev/null; }
verdict_cli() { run_with_timeout 60 node "$AGENTS_DIR/bin/supervisor-write-audit-verdict" --session-id "$1" --verdict "$2" --verdict-summary "fixture" 2>/dev/null; }
# run_tests_hook <sid> <exit> — the PostToolUse envelope after tests/run-all.sh.
run_tests_hook() {
    local contract="RUN_CONTRACT: PASS=3 FAIL=2 SKIP=0 EXECUTED=5"
    [ "$2" = "0" ] && contract="RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5"
    printf '{"tool_name":"Bash","tool_input":{"command":"bash %s/tests/run-all.sh","cwd":"%s"},"tool_response":{"exit_code":%s,"stdout":"%s\\n"},"session_id":"%s"}' \
        "$AGENTS" "$AGENTS" "$2" "$contract" "$1" \
        | run_with_timeout 60 node "$AGENTS_DIR/hooks/workflow-run-tests.js" >/dev/null 2>&1
}
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$3 got=${2:0:300}"; fi; }
injected() { case "$1" in *'"additionalContext"'*) printf 'yes' ;; *) printf 'no:%s' "${1:0:120}" ;; esac; }
RESET_OK='echo "<<WORKFLOW_RESET_FROM_clarify_intent: redo the intent check>>"'

case_begin "risk-module-contract" "hooks/lib/handoff-risk-signal.js"
cat > "$TMP/unit.js" <<'JS'
const fs = require('fs');
const W = process.env.WORKFLOW_PLANS_DIR;
const R = require(process.env.AGENTS + '/hooks/lib/handoff-risk-signal.js');
const bad = [];
const want = ['compaction', 'gate-block', 'reset-from', 'supervisor-verdict', 'supervisor-finding', 'test-failure'];
if (JSON.stringify(R.RISK_SOURCES) !== JSON.stringify(want)) bad.push('RISK_SOURCES:' + JSON.stringify(R.RISK_SOURCES));
if (R.readLastRiskAt('u-none') !== null) bad.push('absent-not-null');
R.recordRiskSignal('u-ok', 'gate-block');
const at = R.readLastRiskAt('u-ok');
if (typeof at !== 'number' || Math.abs(at - Date.now()) > 5000) bad.push('readLastRiskAt:' + String(at));
R.recordRiskSignal('u-bad-source', 'not-a-source');
if (fs.existsSync(W + '/u-bad-source-handoff-risk.json')) bad.push('unknown-source-written');
for (const sid of ['../escape', '', null]) { try { R.recordRiskSignal(sid, 'gate-block'); } catch (e) { bad.push('threw:' + e.message); } }
if (fs.readdirSync(W).some((f) => f.indexOf('escape') !== -1)) bad.push('invalid-sid-written');
for (const sid of ['../escape', '', null]) { try { if (R.readLastRiskAt(sid) !== null) bad.push('invalid-sid-read-not-null'); } catch (e) { bad.push('read-threw:' + e.message); } }
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS
expect "U1: RISK_SOURCES is the six-source list; unknown sources and invalid sids write nothing and read back null; the stamp reads back as ms" "$(nj unit.js)" "OK"
case_end

case_begin "compaction-stamps-risk" "hooks/post-compact.js"
seed rk-compact; T="$(now_ms)"
compact rk-compact >/dev/null
expect "RS1: a compaction stamps source compaction" "$(risk rk-compact "$T")" "compaction"
case_end

case_begin "gate-block-stamps-risk" "hooks/workflow-gate/handoff-record.js"
seed rk-gate; T="$(now_ms)"
nj call.js gate rk-gate >/dev/null
expect "RS2: a gate block stamps source gate-block" "$(risk rk-gate "$T")" "gate-block"
case_end

case_begin "reset-from-stamps-risk-only-on-success" "hooks/workflow-mark/reset-handler.js"
seed rk-reset; T="$(now_ms)"
expect "RS3: the reset is applied" "$(nj call.js reset rk-reset "$RESET_OK")" ""
expect "RS3: a successful RESET_FROM stamps source reset-from" "$(risk rk-reset "$T")" "reset-from"
seed rk-reset-rej
nj call.js reset rk-reset-rej 'echo "<<WORKFLOW_RESET_FROM_no_such_step: a valid reason>>"' >/dev/null
expect "N3: a rejected RESET_FROM stamps nothing" "$(risk rk-reset-rej 0)" "NONE"
case_end

case_begin "verdict-stamps-risk-for-warn-block" "bin/supervisor-write-audit-verdict"
for v in WARN BLOCK; do
    seed "rk-verdict-$v"; T="$(now_ms)"
    verdict_cli "rk-verdict-$v" "$v" >/dev/null
    expect "RS4: verdict $v stamps source supervisor-verdict" "$(risk "rk-verdict-$v" "$T")" "supervisor-verdict"
done
seed rk-verdict-continue
verdict_cli rk-verdict-continue CONTINUE >/dev/null
expect "N1: verdict CONTINUE stamps nothing" "$(risk rk-verdict-continue 0)" "NONE"
case_end

case_begin "set-audit-verdict-stamps-risk" "bin/supervisor-write-audit"
seed rk-wa-block; T="$(now_ms)"
run_with_timeout 60 node "$AGENTS_DIR/bin/supervisor-write-audit" --session-id rk-wa-block --set-audit-verdict BLOCK --set-audit-verdict-summary fixture >/dev/null 2>&1
expect "RS4b: --set-audit-verdict BLOCK stamps source supervisor-verdict" "$(risk rk-wa-block "$T")" "supervisor-verdict"
case_end

case_begin "finding-stamps-risk_at_warning_and_above" "hooks/lib/supervisor-state-writer/append.js"
for sev in warning error; do
    seed "rk-finding-$sev"; T="$(now_ms)"
    expect "RS5: a $sev finding is still accepted" "$(nj call.js finding "rk-finding-$sev" "$sev")" "true"
    expect "RS5: a $sev finding stamps source supervisor-finding" "$(risk "rk-finding-$sev" "$T")" "supervisor-finding"
done
seed rk-finding-notice
nj call.js finding rk-finding-notice notice >/dev/null
expect "N2: a notice finding stamps nothing" "$(risk rk-finding-notice 0)" "NONE"
case_end

case_begin "test-failure-stamps-risk_after_implementation" "hooks/workflow-run-tests.js"
seed rk-tests-run run_tests; T="$(now_ms)"
run_tests_hook rk-tests-run 1
expect "RS6: the hook did observe the failing run" "$(nj observed.js rk-tests-run)" "yes"
expect "RS6: a failing suite at run_tests stamps source test-failure" "$(risk rk-tests-run "$T")" "test-failure"
for step in write_tests review_tests write_code; do
    seed "rk-tests-$step" "$step"
    run_tests_hook "rk-tests-$step" 1
    expect "N4: the hook did observe the failing run during $step" "$(nj observed.js "rk-tests-$step")" "yes"
    expect "N4: a failing suite during $step (red expected) stamps nothing" "$(risk "rk-tests-$step" 0)" "NONE"
done
seed rk-tests-green run_tests
run_tests_hook rk-tests-green 0
expect "N5: a green suite stamps nothing" "$(risk rk-tests-green 0)" "NONE"
case_end

# An unwritable risk file (a directory at its path) must cost nothing but the
# stamp: every producer's own output and exit code stay what they were.
case_begin "risk_write_failure_changes_no_producer" "bin/supervisor-write-audit-verdict"
for sid in rk-io-compact rk-io-gate rk-io-reset rk-io-verdict rk-io-finding; do seed "$sid"; mkdir -p "$TMP/wf/$sid-handoff-risk.json"; done
expect "I1: PostCompact still re-injects" "$(injected "$(compact rk-io-compact)")" "yes"
expect "I1: recordGateBlock still writes its entry" "$(nj call.js gate rk-io-gate)" '{"written":true,"reason":"ok"}'
expect "I1: the reset is still applied" "$(nj call.js reset rk-io-reset "$RESET_OK")" ""
OUT="$(verdict_cli rk-io-verdict WARN)"; RC=$?
expect "I1: the verdict CLI keeps exit 0" "$RC" "0"
expect "I1: the verdict CLI keeps its stdout" "$OUT" '{"accepted":true,"audit_run_id":null}'
expect "I1: appendFinding still returns true" "$(nj call.js finding rk-io-finding warning)" "true"
seed rk-io-tests run_tests; mkdir -p "$TMP/wf/rk-io-tests-handoff-risk.json"
run_tests_hook rk-io-tests 1; RC=$?
expect "I1: the run-tests hook keeps exit 0" "$RC" "0"
expect "I1: the run-tests hook still records the failed run" "$(nj observed.js rk-io-tests)" "yes"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
