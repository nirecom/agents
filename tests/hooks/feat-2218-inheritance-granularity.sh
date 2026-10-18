#!/usr/bin/env bash
# tests/hooks/feat-2218-inheritance-granularity.sh
# Tests: hooks/workflow-state/inheritance/apply.js, hooks/workflow-state/inheritance/adopt.js, hooks/workflow-state/state-io/step-context-class.js
# Tags: session-inherit, inheritance-granularity, context-independent-only, verified-equivalent, regression-2218, scope:issue-specific, pwsh-not-required, TL2, feature-2297, feature-2304, state-copy, context-revert

# Issue #2218 Step 4, re-cut by #2304 / #2297 (feature #2633 commits 2a + 2c). The upstream state is now copied verbatim and the degraded mode REVERTS afterwards: every worktree-dependent step that was not pending is set back to pending with inherit_revert_reason "context:worktree-dependent" (origin session-inherit, provenance backfilled). Granularity is no longer something a caller asks for: adoptState decides it from where the downstream runs (SAME worktree -> full, anything else -> context-independent-only), so a different-cwd upstream is adopted degraded instead of refused, and the old verifiedEquivalent input is ignored. `cleanup` stays the sharp edge: force-skipped (#772) under full, left pending with no events under degraded.

# TL3 gap: the live /resume-session --from → adopt-session-state → session-start notice chain is not exercised here — only the shared applyInheritance/adoptState seam. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: workflow-state.

# TDD: G1/G2/G4/G5/G6 stay red until #2633 2a (copy + revert, upstream-sid signature) and 2c (decideInheritanceGranularity) land; G3 is a regression guard.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Real git fixture for G5: compareRepoIdentity needs on-disk repos to reach SAME
# or SIBLING — a bare fake path string can never be told apart from "unknown".
init_repo() {
    git init -q "$1" 2>/dev/null
    git -C "$1" config core.hooksPath /dev/null
    git -C "$1" config user.email 't@example.com'
    git -C "$1" config user.name 'fixture'
    git -C "$1" config commit.gpgsign false
    printf 'seed\n' > "$1/f.txt"
    git -C "$1" add -A
    GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
        git -C "$1" commit -q -m init
}

SCRIPT_CHECKOUT_ROOT_NODE="$(node_path "$SCRIPT_CHECKOUT_ROOT")"

# isolation (#2512): pin state and plans dirs file-wide; the per-call pins below still override them.
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

# The CONFIRM_DETAIL waiver is read from the settings root's file only, so the fixture owns one.
CFG_FIXTURE="$_ISOLATION_TMP_ROOT/cfg"
mkdir -p "$CFG_FIXTURE" "$_ISOLATION_TMP_ROOT/transcripts" "$_ISOLATION_TMP_ROOT/neutral"
printf 'CONFIRM_DETAIL=off\n' > "$CFG_FIXTURE/.env"
CFG_FIXTURE_NODE="$(node_path "$CFG_FIXTURE")"
export AGENTS_MAIN_ROOT="$CFG_FIXTURE_NODE"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(node_path "$_ISOLATION_TMP_ROOT/transcripts")"
cd "$_ISOLATION_TMP_ROOT/neutral" || exit 1

require_granularity() {
    local out
    out=$(env -u CLAUDE_CODE_SESSION_ID "$RWT" 30 node -e "
const missing = [];
const apply = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance/apply');
if (typeof apply.applyInheritance !== 'function') missing.push('applyInheritance');
if (typeof apply.describeGranularInheritance !== 'function') missing.push('describeGranularInheritance');
try { require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io/step-context-class'); }
catch (e) { missing.push('hooks/workflow-state/state-io/step-context-class.js'); }
process.stdout.write(missing.join(','));
" 2>&1)
    if [ -z "$out" ]; then return 0; fi
    fail "NOT YET IMPLEMENTED: [$out]"
    return 1
}

# The 2c decision function — the adopt-level cases (G4/G5) depend on it.
require_decide() {
    if [ -f "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/inheritance/granularity.js" ]; then return 0; fi
    fail "$1: NOT YET IMPLEMENTED: hooks/workflow-state/inheritance/granularity.js (decideInheritanceGranularity, #2297) does not exist"
    return 1
}

# Upstream fixture shared by the cases: completions on BOTH sides of the
# classification boundary, an annotation on a context-independent step (outline
# skip_reason) and a pending worktree-dependent step carrying a reset_reason.
DONOR_JS="
writeState(donorSid, createInitialState(donorSid, { cwd: '/fixture/repo', git_branch: 'feature/x' }));
markStep(donorSid, 'workflow_init', 'complete');
require('$SCRIPT_CHECKOUT_ROOT_NODE/tests/lib/plan-approval-fixture').approveLive(donorSid, 'clarify_intent');
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
    out=$(env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "$1" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    printf '%s' "$out"
}

# G1 — degraded = verbatim copy, then a context revert of every worktree-dependent
# step that was not pending. Context-independent steps keep their status and
# annotations; reverted_steps is the object list {step, cause, code, trigger}.
run_G1() {
    require_granularity || return 0
    local out
    out="$(run_node "
const { writeState, createInitialState, markStep, readState, readRawState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance');
const { isContextIndependentStep } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io/step-context-class');
const donorSid = 'donor-g1';
$DONOR_JS
const heirSid = 'heir-g1';
writeState(heirSid, createInitialState(heirSid, { cwd: '/other/repo', git_branch: 'main' }));
const problems = [];
let res = null;
try { res = applyInheritance(heirSid, '2026-03-01T00:00:00.000Z', donorSid, { granularity: 'context-independent-only' }); }
catch (e) { problems.push('threw:' + String(e && e.message).split('\n')[0]); }
if (!res || res.granularity !== 'context-independent-only') problems.push('granularity:' + JSON.stringify(res && res.granularity));
const heir = readState(heirSid) || {};
const raw = readRawState(heirSid) || {};
const st = (s) => ((heir.steps && heir.steps[s]) || {});
if (raw.upstream_session_id !== donorSid) problems.push('upstream_session_id:' + String(raw.upstream_session_id));
if ((raw.events || []).some((e) => 'inherited_from' in e)) problems.push('inherited_from-still-stamped');
for (const s of ['workflow_init', 'clarify_intent', 'research', 'detail']) {
  if (st(s).status !== 'complete') problems.push('ci-step-lost:' + s + '=' + st(s).status);
}
if (st('outline').status !== 'skipped' || st('outline').skip_reason !== 'trivial') problems.push('outline-annotation-lost');
for (const s of ['branching_complete', 'write_tests', 'review_tests']) {
  if ((st(s).status || 'pending') !== 'pending') problems.push('worktree-step-not-reverted:' + s + '=' + st(s).status);
  if (st(s).inherit_revert_reason !== 'context:worktree-dependent') problems.push('revert-reason:' + s + '=' + String(st(s).inherit_revert_reason));
}
const reverts = (raw.events || []).filter((e) => e.kind === 'step_annotation' && e.key === 'inherit_revert_reason');
if (reverts.some((e) => e.origin !== 'session-inherit' || e.provenance !== 'backfilled')) problems.push('revert-stamp:' + JSON.stringify(reverts.map((e) => [e.origin, e.provenance])));
if (reverts.some((e) => isContextIndependentStep(e.step))) problems.push('ci-step-reverted');
if (res && Array.isArray(res.inherited_steps)) {
  const wrong = res.inherited_steps.filter((s) => !isContextIndependentStep(s));
  if (wrong.length) problems.push('inherited_steps-includes-worktree-step:' + wrong.join(','));
  if (res.inherited_steps.indexOf('detail') === -1) problems.push('inherited_steps-missing-detail');
} else problems.push('inherited_steps-not-array');
if (res && Array.isArray(res.reverted_steps)) {
  for (const s of ['branching_complete', 'write_tests', 'review_tests']) {
    const hit = res.reverted_steps.find((r) => r && typeof r === 'object' && r.step === s);
    if (!hit) problems.push('reverted_steps-missing-object:' + s);
    else if (hit.cause !== 'context' || hit.code !== 'worktree-dependent' || hit.trigger != null) problems.push('reverted-shape:' + JSON.stringify(hit));
  }
  if (res.reverted_steps.some((r) => r && r.step === 'cleanup')) problems.push('pending-cleanup-listed-as-reverted');
} else problems.push('reverted_steps-not-array');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "G1: context-independent-only copies verbatim, then reverts worktree-dependent steps to pending with a context reason"
    else
        fail "G1: expected 'OK', got '${out:-<err>}'"
    fi
}

# G2 — cleanup. Under "full" the #772 force-skip stays (same-worktree
# crash-resume); under "context-independent-only" it must stay pending, or the
# downstream's own worktree teardown is silently marked done.
run_G2() {
    require_granularity || return 0
    local out
    out="$(run_node "
const { writeState, createInitialState, markStep, readState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance');
const donorSid = 'donor-g2';
$DONOR_JS
const problems = [];
try {
  writeState('heir-g2-full', createInitialState('heir-g2-full', { cwd: '/fixture/repo', git_branch: 'feature/x' }));
  applyInheritance('heir-g2-full', '2026-03-01T00:00:00.000Z', donorSid, { granularity: 'full' });
  writeState('heir-g2-cio', createInitialState('heir-g2-cio', { cwd: '/other/repo', git_branch: 'main' }));
  applyInheritance('heir-g2-cio', '2026-03-01T00:00:00.000Z', donorSid, { granularity: 'context-independent-only' });
} catch (e) { problems.push('threw:' + String(e && e.message).split('\n')[0]); }
const full = readState('heir-g2-full') || {};
const fullCleanup = (full.steps && full.steps.cleanup) || {};
if (fullCleanup.status !== 'skipped') problems.push('full-cleanup-status:' + String(fullCleanup.status));
if (fullCleanup.skip_reason !== 'inherited-from-prior-session') problems.push('full-cleanup-skip_reason:' + String(fullCleanup.skip_reason));
if (((full.steps && full.steps.write_tests) || {}).status !== 'complete') problems.push('full-write_tests-not-carried');
const cio = readState('heir-g2-cio') || {};
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

# G3 — the two refusals that survive the gate removal: overwrite protection on
# the downstream (it already recorded its own work, no upstream_session_id) and
# evaluateResumability on the upstream (already delivered).
run_G3() {
    require_granularity || return 0
    local out
    out="$(run_node "
const { writeState, createInitialState, markStep, readState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const { adoptState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance/adopt');
const problems = [];
const donorSid = 'donor-g3';
$DONOR_JS
writeState('heir-g3a', createInitialState('heir-g3a', { cwd: '/fixture/repo', git_branch: 'feature/x' }));
markStep('heir-g3a', 'workflow_init', 'complete');
const a = adoptState({ heirSid: 'heir-g3a', donorSid });
if (a.ok !== false) problems.push('overwrite-protection-bypassed:' + JSON.stringify(a));
// #2527: merge_to_main, not approval, ends a session.
const donor2 = 'donor-g3b';
writeState(donor2, createInitialState(donor2, { cwd: '/fixture/repo', git_branch: 'feature/x' }));
markStep(donor2, 'workflow_init', 'complete');
markStep(donor2, 'user_verification', 'complete');
markStep(donor2, 'merge_to_main', 'complete');
writeState('heir-g3b', createInitialState('heir-g3b', { cwd: '/fixture/repo', git_branch: 'feature/x' }));
const b = adoptState({ heirSid: 'heir-g3b', donorSid: donor2 });
if (b.ok !== false) problems.push('evaluateResumability-bypassed:' + JSON.stringify(b));
else if (String(b.error).indexOf('not resumable') === -1) problems.push('wrong-reason-b:' + b.error);
const heirB = readState('heir-g3b');
if ((heirB.events || []).some((e) => e.origin === 'session-inherit')) problems.push('events-written-despite-rejection');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "G3: overwrite protection and evaluateResumability still refuse"
    else
        fail "G3: expected 'OK', got '${out:-<err>}'"
    fi
}

# G4 — the context gate is gone: an upstream recorded in a different cwd/branch
# is adopted at context-independent-only instead of refused.
run_G4() {
    require_granularity || return 0
    require_decide "G4" || return 0
    local out
    out="$(run_node "
const { writeState, createInitialState, markStep, readState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const { adoptState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance/adopt');
const problems = [];
const donorSid = 'donor-g4';
$DONOR_JS
writeState('heir-g4', createInitialState('heir-g4', { cwd: '/somewhere/else', git_branch: 'main' }));
const r = adoptState({ heirSid: 'heir-g4', donorSid });
if (r.ok !== true) problems.push('rejected:' + JSON.stringify(r));
if (r.granularity !== 'context-independent-only') problems.push('granularity:' + String(r.granularity));
const heir = readState('heir-g4') || {};
if (((heir.steps && heir.steps.detail) || {}).status !== 'complete') problems.push('detail-not-inherited');
const wt = (heir.steps && heir.steps.write_tests) || {};
if ((wt.status || 'pending') !== 'pending') problems.push('write_tests-kept-across-worktrees');
if (wt.inherit_revert_reason !== 'context:worktree-dependent') problems.push('write_tests-revert-reason:' + String(wt.inherit_revert_reason));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "G4: a different-cwd upstream is adopted degraded, not refused"
    else
        fail "G4: expected 'OK', got '${out:-<err>}'"
    fi
}

# G5 — granularity is a fact about where the downstream runs. SAME worktree ->
# full; a SIBLING worktree -> degraded, even when the caller still passes the
# removed granularity / verifiedEquivalent inputs.
run_G5() {
    require_granularity || return 0
    require_decide "G5" || return 0
    local out fixture_tmp main wt main_n wt_n donor_js_g5
    fixture_tmp="$(make_tmp)"
    main="$fixture_tmp/main"; wt="$fixture_tmp/linked"
    init_repo "$main"
    git -C "$main" worktree add -q -b feature/g5 "$wt" 2>/dev/null
    if [ ! -d "$wt" ]; then
        rm -rf "$fixture_tmp" 2>/dev/null || true
        fail "G5: fixture setup failed — could not create a linked worktree"
        return 0
    fi
    main_n="$(node_path "$main")"; wt_n="$(node_path "$wt")"
    donor_js_g5="${DONOR_JS//\/fixture\/repo/$main_n}"
    out="$(run_node "
const { writeState, createInitialState, markStep, readState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const { adoptState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance/adopt');
const problems = [];
const donorSid = 'donor-g5';
$donor_js_g5
writeState('heir-g5a', createInitialState('heir-g5a', { cwd: '$main_n', git_branch: 'feature/x' }));
const same = adoptState({ heirSid: 'heir-g5a', donorSid });
if (same.ok !== true) problems.push('same-rejected:' + JSON.stringify(same));
else if (same.granularity !== 'full') problems.push('same-granularity:' + String(same.granularity));
const heirA = readState('heir-g5a') || {};
for (const s of ['detail', 'branching_complete', 'write_tests', 'review_tests']) {
  if (((heirA.steps && heirA.steps[s]) || {}).status !== 'complete') problems.push('same-not-full:' + s);
}
writeState('heir-g5b', createInitialState('heir-g5b', { cwd: '$wt_n', git_branch: 'feature/g5' }));
const sib = adoptState({ heirSid: 'heir-g5b', donorSid, granularity: 'full', verifiedEquivalent: true });
if (sib.ok !== true) problems.push('sibling-rejected:' + JSON.stringify(sib));
else if (sib.granularity !== 'context-independent-only') problems.push('sibling-granularity:' + String(sib.granularity));
const heirB = readState('heir-g5b') || {};
if ((((heirB.steps && heirB.steps.write_tests) || {}).status || 'pending') !== 'pending') problems.push('sibling-write_tests-kept');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    rm -rf "$fixture_tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "G5: SAME worktree adopts full; a SIBLING adopts degraded and the removed caller inputs are ignored"
    else
        fail "G5: expected 'OK', got '${out:-<err>}'"
    fi
}

# G6 — describeGranularInheritance is the single renderer adopt-session-state and
# resume-session print from: it names every reverted step from the object list
# and gives a different, list-free text when nothing was reverted.
run_G6() {
    require_granularity || return 0
    local out
    out="$(run_node "
const { describeGranularInheritance } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance/apply');
const problems = [];
const ctx = (step) => ({ step, cause: 'context', code: 'worktree-dependent', trigger: null });
const degraded = describeGranularInheritance({
  upstream_session_id: 'up-g6',
  granularity: 'context-independent-only',
  inherited_steps: ['workflow_init', 'clarify_intent', 'detail'],
  reverted_steps: [ctx('branching_complete'), ctx('write_tests'), ctx('review_tests')],
});
if (typeof degraded !== 'string' || degraded.trim().length === 0) problems.push('degraded-not-text:' + JSON.stringify(degraded));
else {
  for (const s of ['branching_complete', 'write_tests', 'review_tests', 'detail']) {
    if (degraded.indexOf(s) === -1) problems.push('degraded-missing-step:' + s);
  }
  if (degraded.indexOf('[object Object]') !== -1) problems.push('object-list-rendered-raw');
}
const symmetric = describeGranularInheritance({
  upstream_session_id: 'up-g6',
  granularity: 'full',
  inherited_steps: ['workflow_init', 'clarify_intent', 'detail'],
  reverted_steps: [],
});
if (typeof symmetric !== 'string' || symmetric.trim().length === 0) problems.push('symmetric-not-text:' + JSON.stringify(symmetric));
else {
  if (symmetric === degraded) problems.push('same-text-for-both-outcomes');
  if (symmetric.indexOf('branching_complete') !== -1) problems.push('symmetric-lists-reverted-steps');
  if (symmetric.indexOf('Nothing was held back') === -1) problems.push('symmetric-missing-nothing-held-back');
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "G6: describeGranularInheritance renders the reverted object list and the zero-reverted outcome from one implementation"
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
