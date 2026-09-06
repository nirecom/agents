#!/usr/bin/env bash
# tests/feat-2218-inheritance-granularity.sh
# Tests: hooks/workflow-state/inheritance/apply.js, hooks/workflow-state/inheritance/adopt.js, hooks/workflow-state/state-io/step-context-class.js
# Tags: session-inherit, inheritance-granularity, context-independent-only, verified-equivalent, regression-2218, scope:issue-specific, pwsh-not-required, TL2

# Issue #2218 Step 4 — "context-independent-only" carries the plan-stage steps (evidence in PLANS_DIR) and leaves every worktree-bound step untouched. The round1-fix C4 corrections are the sharp edges: a worktree-dependent step must emit NO event at all (annotations included, not only status), and `cleanup` must NOT be force-skipped in this mode or the heir's own worktree is left un-cleaned while the record says otherwise.

# TL3 gap: the live /resume-session --from → adopt-session-state → session-start notice chain is not exercised here — only the shared applyInheritance/adoptState seam. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: workflow-state.

# TDD (write_code has not run): every case is expected to FAIL with "NOT YET IMPLEMENTED" until Step 4 lands.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

require_granularity() {
    local out
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID "$RWT" 30 node -e "
const missing = [];
const apply = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance/apply');
if (typeof apply.applyInheritance !== 'function' || apply.applyInheritance.length < 4) missing.push('applyInheritance(...,opts)');
if (typeof apply.describeGranularInheritance !== 'function') missing.push('describeGranularInheritance');
try { require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io/step-context-class'); }
catch (e) { missing.push('hooks/workflow-state/state-io/step-context-class.js'); }
process.stdout.write(missing.join(','));
" 2>&1)
    if [ -z "$out" ]; then return 0; fi
    fail "NOT YET IMPLEMENTED: [$out] — expected per issue #2218 Step 4 (write_code has not run)"
    return 1
}

# Donor fixture shared by the cases: completions on BOTH sides of the
# classification boundary, plus an annotation on a worktree-dependent step
# (run_tests reset_reason) and one on a context-independent step (outline
# skip_reason). Those two annotations are what round1-fix C4 turns on.
DONOR_JS="
writeState(donorSid, createInitialState(donorSid, { cwd: '/fixture/repo', git_branch: 'feature/x' }));
markStep(donorSid, 'workflow_init', 'complete');
markStep(donorSid, 'clarify_intent', 'complete');
markStep(donorSid, 'research', 'complete');
markStep(donorSid, 'outline', 'skipped', { skip_reason: 'trivial' });
markStep(donorSid, 'detail', 'complete');
markStep(donorSid, 'branching_complete', 'complete');
markStep(donorSid, 'write_tests', 'complete');
markStep(donorSid, 'review_tests', 'complete');
markStep(donorSid, 'run_tests', 'pending', { reset_reason: 'flaky-rerun' });
"

run_node() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "$1" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    printf '%s' "$out"
}

# G1 — the inherited / reverted partition, and the C4 rule that a
# worktree-dependent step emits NO event of any kind (status or annotation).
run_G1() {
    require_granularity || return 0
    local out
    out="$(run_node "
const { writeState, createInitialState, markStep, readState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance');
const { isContextIndependentStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io/step-context-class');
const donorSid = 'donor-g1';
$DONOR_JS
const donor = readState(donorSid);
const heirSid = 'heir-g1';
writeState(heirSid, createInitialState(heirSid, { cwd: '/other/repo', git_branch: 'main' }));
const res = applyInheritance(heirSid, '2026-03-01T00:00:00.000Z', donor, { granularity: 'context-independent-only' });
const problems = [];
if (!res || res.granularity !== 'context-independent-only') problems.push('granularity:' + JSON.stringify(res && res.granularity));
const heir = readState(heirSid);
const inheritedEvents = (heir.events || []).filter((e) => e.origin === 'session-inherit');
const leaked = inheritedEvents.filter((e) => !isContextIndependentStep(e.step));
if (leaked.length) problems.push('worktree-dependent-events-emitted:' + JSON.stringify(leaked.map((e) => [e.kind, e.step, e.status || e.key])));
if (!inheritedEvents.some((e) => e.step === 'detail')) problems.push('detail-not-inherited');
if (!inheritedEvents.some((e) => e.kind === 'step_annotation' && e.step === 'outline')) problems.push('outline-skip_reason-annotation-not-inherited');
for (const s of ['branching_complete', 'write_tests', 'review_tests']) {
  const st = (heir.steps && heir.steps[s] && heir.steps[s].status) || 'pending';
  if (st !== 'pending') problems.push('worktree-step-not-pending:' + s + '=' + st);
}
const rt = (heir.steps && heir.steps.run_tests) || {};
if (rt.reset_reason !== undefined) problems.push('run_tests-annotation-leaked:' + String(rt.reset_reason));
if (res && Array.isArray(res.inherited_steps)) {
  const wrong = res.inherited_steps.filter((s) => !isContextIndependentStep(s));
  if (wrong.length) problems.push('inherited_steps-includes-worktree-step:' + wrong.join(','));
  if (res.inherited_steps.indexOf('detail') === -1) problems.push('inherited_steps-missing-detail');
} else problems.push('inherited_steps-not-array');
if (res && Array.isArray(res.reverted_steps)) {
  for (const s of ['branching_complete', 'write_tests', 'cleanup']) {
    if (res.reverted_steps.indexOf(s) === -1) problems.push('reverted_steps-missing:' + s);
  }
} else problems.push('reverted_steps-not-array');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "G1: context-independent-only inherits plan steps only — worktree steps emit no status and no annotation"
    else
        fail "G1: expected 'OK', got '${out:-<err>}'"
    fi
}

# G2 — cleanup. Under "full" the #772 force-skip stays (same-worktree
# crash-resume); under "context-independent-only" it must stay pending, or the
# heir's own worktree teardown is silently marked done.
run_G2() {
    require_granularity || return 0
    local out
    out="$(run_node "
const { writeState, createInitialState, markStep, readState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance');
const donorSid = 'donor-g2';
$DONOR_JS
const donor = readState(donorSid);
const problems = [];
writeState('heir-g2-full', createInitialState('heir-g2-full', { cwd: '/fixture/repo', git_branch: 'feature/x' }));
applyInheritance('heir-g2-full', '2026-03-01T00:00:00.000Z', donor, { granularity: 'full' });
const full = readState('heir-g2-full');
const fullCleanup = (full.steps && full.steps.cleanup) || {};
if (fullCleanup.status !== 'skipped') problems.push('full-cleanup-status:' + String(fullCleanup.status));
if (fullCleanup.skip_reason !== 'inherited-from-prior-session') problems.push('full-cleanup-skip_reason:' + String(fullCleanup.skip_reason));
writeState('heir-g2-cio', createInitialState('heir-g2-cio', { cwd: '/other/repo', git_branch: 'main' }));
applyInheritance('heir-g2-cio', '2026-03-01T00:00:00.000Z', donor, { granularity: 'context-independent-only' });
const cio = readState('heir-g2-cio');
const cioCleanup = (cio.steps && cio.steps.cleanup) || {};
if ((cioCleanup.status || 'pending') !== 'pending') problems.push('cio-cleanup-status:' + String(cioCleanup.status));
if (cioCleanup.skip_reason !== undefined) problems.push('cio-cleanup-skip_reason-leaked:' + String(cioCleanup.skip_reason));
const cleanupEvents = (cio.events || []).filter((e) => e.origin === 'session-inherit' && e.step === 'cleanup');
if (cleanupEvents.length !== 0) problems.push('cio-cleanup-events:' + cleanupEvents.length);
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "G2: cleanup is force-skipped under 'full' and left pending with no events under 'context-independent-only'"
    else
        fail "G2: expected 'OK', got '${out:-<err>}'"
    fi
}

# G3 — the two gates that granularity must NOT open. isAllPending and
# evaluateResumability protect the heir and the donor respectively; only
# contextMatches is relaxed (detail.md Step 4 gate table).
run_G3() {
    require_granularity || return 0
    local out
    out="$(run_node "
const { writeState, createInitialState, markStep, readState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const { adoptState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance/adopt');
const problems = [];
const donorSid = 'donor-g3';
$DONOR_JS
// (a) heir already has recorded progress -> isAllPending rejects.
writeState('heir-g3a', createInitialState('heir-g3a', { cwd: '/other/repo', git_branch: 'main' }));
markStep('heir-g3a', 'workflow_init', 'complete');
const a = adoptState({ heirSid: 'heir-g3a', donorSid, granularity: 'context-independent-only' });
if (a.ok !== false) problems.push('isAllPending-bypassed:' + JSON.stringify(a));
// (b) donor already user-verified -> evaluateResumability rejects.
const donor2 = 'donor-g3b';
writeState(donor2, createInitialState(donor2, { cwd: '/fixture/repo', git_branch: 'feature/x' }));
markStep(donor2, 'workflow_init', 'complete');
markStep(donor2, 'user_verification', 'complete');
writeState('heir-g3b', createInitialState('heir-g3b', { cwd: '/other/repo', git_branch: 'main' }));
const b = adoptState({ heirSid: 'heir-g3b', donorSid: donor2, granularity: 'context-independent-only' });
if (b.ok !== false) problems.push('evaluateResumability-bypassed:' + JSON.stringify(b));
else if (String(b.error).indexOf('not resumable') === -1) problems.push('wrong-reason-b:' + b.error);
const heirB = readState('heir-g3b');
if ((heirB.events || []).some((e) => e.origin === 'session-inherit')) problems.push('events-written-despite-rejection');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "G3: isAllPending and evaluateResumability still reject under context-independent-only"
    else
        fail "G3: expected 'OK', got '${out:-<err>}'"
    fi
}

# G4 — contextMatches is the ONE gate granularity relaxes: a donor from a
# different cwd/branch is accepted, because nothing worktree-bound is carried.
run_G4() {
    require_granularity || return 0
    local out
    out="$(run_node "
const { writeState, createInitialState, markStep, readState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const { adoptState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance/adopt');
const problems = [];
const donorSid = 'donor-g4';
$DONOR_JS
writeState('heir-g4', createInitialState('heir-g4', { cwd: '/somewhere/else', git_branch: 'main' }));
const r = adoptState({ heirSid: 'heir-g4', donorSid, granularity: 'context-independent-only' });
if (r.ok !== true) problems.push('rejected:' + JSON.stringify(r));
const heir = readState('heir-g4');
if (((heir.steps && heir.steps.detail) || {}).status !== 'complete') problems.push('detail-not-inherited');
if (((heir.steps && heir.steps.write_tests) || {}).status === 'complete') problems.push('write_tests-inherited-across-worktrees');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "G4: context-independent-only proceeds through a contextMatches mismatch"
    else
        fail "G4: expected 'OK', got '${out:-<err>}'"
    fi
}

# G5 — verifiedEquivalent (round1-fix C2). "different path, PROVEN same
# content" bypasses the same gate but inherits at FULL granularity; without the
# flag the very same call must still be refused.
run_G5() {
    require_granularity || return 0
    local out
    out="$(run_node "
const { writeState, createInitialState, markStep, readState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const { adoptState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance/adopt');
const problems = [];
const donorSid = 'donor-g5';
$DONOR_JS
writeState('heir-g5a', createInitialState('heir-g5a', { cwd: '/sibling/worktree', git_branch: 'feature/x' }));
const withFlag = adoptState({ heirSid: 'heir-g5a', donorSid, granularity: 'full', verifiedEquivalent: true });
if (withFlag.ok !== true) problems.push('verified-equivalent-rejected:' + JSON.stringify(withFlag));
const heirA = readState('heir-g5a');
for (const s of ['detail', 'branching_complete', 'write_tests', 'review_tests']) {
  if (((heirA.steps && heirA.steps[s]) || {}).status !== 'complete') problems.push('full-not-inherited:' + s);
}
writeState('heir-g5b', createInitialState('heir-g5b', { cwd: '/sibling/worktree', git_branch: 'feature/x' }));
const noFlag = adoptState({ heirSid: 'heir-g5b', donorSid, granularity: 'full' });
if (noFlag.ok !== false) problems.push('full-without-flag-accepted:' + JSON.stringify(noFlag));
else if (String(noFlag.error).indexOf('context-mismatch') === -1) problems.push('wrong-reason:' + noFlag.error);
const heirB = readState('heir-g5b');
if ((heirB.events || []).some((e) => e.origin === 'session-inherit')) problems.push('events-written-despite-rejection');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "G5: granularity full + verifiedEquivalent inherits everything; full alone still refuses the mismatch"
    else
        fail "G5: expected 'OK', got '${out:-<err>}'"
    fi
}

# G6 — describeGranularInheritance is the single SSOT both adopt-session-state
# and resume-session render from (Step 6): it must name every reverted step in
# the degraded case, and produce a DIFFERENT, list-free text when nothing was
# reverted.
run_G6() {
    require_granularity || return 0
    local out
    out="$(run_node "
const { describeGranularInheritance } = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance/apply');
const problems = [];
const degraded = describeGranularInheritance({
  granularity: 'context-independent-only',
  inherited_steps: ['workflow_init', 'clarify_intent', 'detail'],
  reverted_steps: ['branching_complete', 'write_tests', 'cleanup'],
});
if (typeof degraded !== 'string' || degraded.trim().length === 0) problems.push('degraded-not-text:' + JSON.stringify(degraded));
else {
  for (const s of ['branching_complete', 'write_tests', 'cleanup', 'detail']) {
    if (degraded.indexOf(s) === -1) problems.push('degraded-missing-step:' + s);
  }
}
const symmetric = describeGranularInheritance({
  granularity: 'full',
  inherited_steps: ['workflow_init', 'clarify_intent', 'detail'],
  reverted_steps: [],
});
if (typeof symmetric !== 'string' || symmetric.trim().length === 0) problems.push('symmetric-not-text:' + JSON.stringify(symmetric));
else {
  if (symmetric === degraded) problems.push('same-text-for-both-outcomes');
  if (symmetric.indexOf('branching_complete') !== -1) problems.push('symmetric-lists-reverted-steps');
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "G6: describeGranularInheritance renders both the reverted and the zero-reverted outcome from one implementation"
    else
        fail "G6: expected 'OK', got '${out:-<err>}'"
    fi
}

run_G1
run_G2
run_G3
run_G4
run_G5
run_G6

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
