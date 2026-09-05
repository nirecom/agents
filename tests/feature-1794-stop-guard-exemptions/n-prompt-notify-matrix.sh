# n-prompt-notify-matrix.sh — N1-N3: the promptNotify column (hooks/lib/stop-exemption-policy.js) cross-checked against hooks/user-prompt-submit-mechanism-check.js (#2169). Sourced by tests/feature-1794-stop-guard-exemptions.sh.
# Tests: hooks/lib/stop-exemption-policy.js, hooks/user-prompt-submit-mechanism-check.js
# Tags: stop-hook, exemption-matrix, prompt-notify, regression-2169, scope:issue-specific, pwsh-not-required, TL1

# ---------------------------------------------------------------------------
# N1: the matrix rows registered promptNotify:true and the hook's own PROMPT_NOTIFY_EXEMPTIONS id list are identical, in the same order — the exact CPR-ORTH asymmetry #2169 was caused by (an unregistered consumer).
# ---------------------------------------------------------------------------
run_N1() {
    local out
    out=$("$RWT" 20 node -e "
const { EXEMPTION_MATRIX } = require('$POLICY_NODE');
const ups = require('$UPS_HOOK_NODE');
const matrixTrue = Object.keys(EXEMPTION_MATRIX).filter((k) => EXEMPTION_MATRIX[k].promptNotify);
const tableIds = (ups.PROMPT_NOTIFY_EXEMPTIONS || []).map((e) => e.id);
const problems = [];
if (matrixTrue.join(',') !== tableIds.join(',')) {
  problems.push('drift matrix=' + matrixTrue.join(',') + ' table=' + tableIds.join(','));
}
if (matrixTrue.join(',') !== 'pre-workflow-init') {
  problems.push('unexpected-rows=' + matrixTrue.join(','));
}
process.stdout.write(problems.length ? 'BAD ' + problems.join(' | ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "N1: promptNotify:true rows == PROMPT_NOTIFY_EXEMPTIONS ids == {pre-workflow-init}"
    else
        fail "N1: matrix/table drift; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# N2 (round-4 — #2169 per-finding gate): isPromptNotifyExempt(sid, finding,
# deps), table-driven (skills/_shared/test-design/parser-regex-tests.md).
# Exempt only when BOTH isWorkflowStarted(sid)===false AND
# isLookaheadOnlyInFlight(sid, finding.step)===true; a throw from either
# dependency is NOT exempt (fail-closed) — the per-row try/catch inside
# isPromptNotifyExempt, distinct from N3's setup-level failure below.
# ---------------------------------------------------------------------------
run_N2() {
    local out
    out=$("$RWT" 20 node -e "
const { isPromptNotifyExempt } = require('$UPS_HOOK_NODE');
const cases = [
  { label: 'not-started+lookahead', isWorkflowStarted: () => false, isLookaheadOnlyInFlight: () => true, want: true },
  { label: 'started+lookahead', isWorkflowStarted: () => true, isLookaheadOnlyInFlight: () => true, want: false },
  { label: 'not-started+genuine-stall', isWorkflowStarted: () => false, isLookaheadOnlyInFlight: () => false, want: false },
  { label: 'isWorkflowStarted-throws', isWorkflowStarted: () => { throw new Error('boom'); }, isLookaheadOnlyInFlight: () => true, want: false },
  { label: 'isLookaheadOnlyInFlight-throws', isWorkflowStarted: () => false, isLookaheadOnlyInFlight: () => { throw new Error('boom'); }, want: false },
];
const problems = [];
for (const c of cases) {
  const deps = { isWorkflowStarted: c.isWorkflowStarted, isLookaheadOnlyInFlight: c.isLookaheadOnlyInFlight };
  const got = isPromptNotifyExempt('s', { step: 'research', kind: 'in-flight-expired' }, deps);
  if (got !== c.want) problems.push(c.label + ':want=' + c.want + ' got=' + got);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "N2: isPromptNotifyExempt(sid, finding, deps) is true only when isWorkflowStarted()===false AND isLookaheadOnlyInFlight()===true for that finding's step, and a throw from either dependency is NOT exempt (table-driven, 5 cases)"
    else
        fail "N2: isPromptNotifyExempt semantics wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# N3 (round-2 redesign — review C2): a require('./workflow-state') failure
# INSIDE buildPromptNotifyDeps() — the predicate machinery itself unavailable
# — resolves to NOT exempt (fail toward notifying). Distinct from
# isWorkflowStarted's OWN fail-closed (lifecycle.js) — not re-tested here.
# Export renamed post-#2169: isSessionExemptFromPromptNotify ->
# isFindingExemptFromPromptNotify(sid, finding) (per-finding, 2 args).
# ---------------------------------------------------------------------------
run_N3() {
    local out
    out=$("$RWT" 20 node -e "
const Module = require('module');
const origRequire = Module.prototype.require;
Module.prototype.require = function (request) {
  if (request === './workflow-state') throw new Error('simulated require failure (#2169 N3)');
  return origRequire.apply(this, arguments);
};
const { isFindingExemptFromPromptNotify } = require('$UPS_HOOK_NODE');
let threw = false, result;
try { result = isFindingExemptFromPromptNotify('___n3-require-failure-probe___', { step: 'research', kind: 'in-flight-expired' }); }
catch (e) { threw = true; }
process.stdout.write(threw ? 'BAD:threw' : (result === false ? 'OK' : 'BAD:' + JSON.stringify(result)));" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "N3: a require('./workflow-state') failure inside buildPromptNotifyDeps() resolves to NOT exempt (fail toward notifying, never toward silence) — distinct from isWorkflowStarted's own state-read fail-closed"
    else
        fail "N3: require/setup failure at the gate's own dependency wiring did not resolve to not-exempt; got '${out:-<err>}'"
    fi
}
