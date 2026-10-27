#!/usr/bin/env bash
# tests/hooks/feat-2218-inheritance-equivalence.sh
# Tests: hooks/workflow-state/inheritance/apply.js, hooks/workflow-state/inheritance/adopt.js, hooks/workflow-state/inheritance.js
# Tags: session-inherit, inheritance-granularity, equivalence-pin, regression-1305, regression-2218, scope:issue-specific, pwsh-not-required, TL2, regression-2304, feature-2297, sibling-degraded

# Issue #2218 Step 4 / Risks #1 — granularity is added to the SAME applyInheritance the automatic (lineage-keyed) path uses. Since #2304 the pin is structural: with `opts` omitted the heir holds the donor's stream verbatim up to upstream_copy_seq plus only the #772 cleanup triple, and every default spelling yields the same stream.

# TL3 gap: a real SessionStart-driven inheritance inside a live Claude Code session is not exercised here — only the shared applyInheritance/adoptState seam that hook path calls. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: workflow-state.

# E1/E2/E4 are RED until #2633 2a (upstream-sid signature, verbatim copy) lands; E3 is owned by the #2297 gate change.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

SCRIPT_CHECKOUT_ROOT_NODE="$(node_path "$SCRIPT_CHECKOUT_ROOT")"

# isolation (#2512): pin state and plans dirs file-wide; the per-call pins below still override them.
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

# The CONFIRM_DETAIL waiver is read from the settings root's file only, so the fixture owns one.
CFG_FIXTURE="$_ISOLATION_TMP_ROOT/cfg"
mkdir -p "$CFG_FIXTURE"
printf 'CONFIRM_DETAIL=off\n' > "$CFG_FIXTURE/.env"
CFG_FIXTURE_NODE="$(node_path "$CFG_FIXTURE")"
export AGENTS_MAIN_ROOT="$CFG_FIXTURE_NODE"

# #2304: the heir stream is the donor's verbatim, then only the #772 cleanup triple.
EXPECTED_POST="step_annotations_cleared|cleanup||||session-inherit|backfilled
step_status|cleanup|skipped|||session-inherit|backfilled
step_annotation|cleanup||skip_reason|inherited-from-prior-session|session-inherit|backfilled"

# The granularity capability under test. apply.js already exists, so the RED
# signal here is the missing 4th parameter / the missing describe export.
require_granularity() {
    local out
    out=$(env -u CLAUDE_CODE_SESSION_ID "$RWT" 30 node -e "
const apply = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance/apply');
const missing = [];
if (typeof apply.applyInheritance !== 'function' || apply.applyInheritance.length < 4) missing.push('applyInheritance(sessionId,createdAt,donor,opts)');
if (typeof apply.describeGranularInheritance !== 'function') missing.push('describeGranularInheritance');
process.stdout.write(missing.join(','));
" 2>&1)
    if [ -z "$out" ]; then return 0; fi
    fail "NOT YET IMPLEMENTED: hooks/workflow-state/inheritance/apply.js is missing [$out] — expected per issue #2218 Step 4 (write_code has not run)"
    return 1
}

# Builds the fixture donor + heir and prints the verbatim-copy verdict plus the
# normalized post-boundary events for the given `opts` literal ('OMIT' = no 4th arg).
project_stream() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    out=$(env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "
const { writeState, createInitialState, markStep } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance');
const donorSid = 'donor-2218-eq';
writeState(donorSid, createInitialState(donorSid, { cwd: '/fixture/repo', git_branch: 'feature/x' }));
markStep(donorSid, 'workflow_init', 'complete');
require('$SCRIPT_CHECKOUT_ROOT_NODE/tests/lib/plan-approval-fixture').approveLive(donorSid, 'clarify_intent');
markStep(donorSid, 'clarify_intent', 'complete');
markStep(donorSid, 'outline', 'skipped', { skip_reason: 'trivial' });
markStep(donorSid, 'detail', 'complete');
markStep(donorSid, 'branching_complete', 'complete');
markStep(donorSid, 'write_tests', 'complete');
markStep(donorSid, 'review_tests', 'complete');
markStep(donorSid, 'run_tests', 'pending', { reset_reason: 'flaky-rerun' });
const fs = require('fs'), path = require('path');
const rawOf = (sid) => JSON.parse(fs.readFileSync(path.join(process.env.WORKFLOW_STATE_DIR, sid + '.json'), 'utf8'));
const donorEvents = rawOf(donorSid).events;
const heirSid = 'heir-2218-eq';
const heirCreatedAt = '2026-03-01T00:00:00.000Z';
writeState(heirSid, createInitialState(heirSid, { cwd: '/fixture/repo', git_branch: 'feature/x' }));
const mode = '$1';
if (mode === 'OMIT') applyInheritance(heirSid, heirCreatedAt, donorSid);
else applyInheritance(heirSid, heirCreatedAt, donorSid, JSON.parse(mode));
const heir = rawOf(heirSid);
const b = heir.upstream_copy_seq;
const pre = heir.events.filter((e) => e.seq <= b);
const post = heir.events.filter((e) => !(e.seq <= b)).map((e) => [
  e.kind, e.step, e.status || '', e.key || '',
  e.value === undefined ? '' : (typeof e.value === 'string' ? e.value : JSON.stringify(e.value)),
  e.origin, e.provenance,
].join('|'));
process.stdout.write('VERBATIM=' + (typeof b === 'number' && b === donorEvents.length && JSON.stringify(pre) === JSON.stringify(donorEvents)) + '\n');
process.stdout.write('INHERITED_FROM=' + heir.events.filter((e) => 'inherited_from' in e).length + '\n');
process.stdout.write(post.join('\n'));
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    printf '%s' "$out"
}

# E1 — the structural pin (#2304). With `opts` omitted the heir holds the donor's
# events verbatim up to upstream_copy_seq and only the #772 cleanup triple after
# it. On mismatch the actual output is printed so the diff is readable.
run_E1() {
    local out want
    out="$(project_stream OMIT)"
    want="VERBATIM=true
INHERITED_FROM=0
$EXPECTED_POST"
    if [ "$out" = "$want" ]; then
        pass "E1: opts-omitted inheritance copies the donor stream verbatim and appends only the cleanup triple"
    else
        fail "E1: event stream drifted from verbatim copy + cleanup triple"
        echo "----- actual stream -----"
        printf '%s\n' "$out"
        echo "-------------------------"
    fi
}

# E2 — the three "default" spellings must be one behaviour, not three. Omitted,
# `{}` and `{granularity:"full"}` are the forms every existing caller and every
# future caller of the automatic path can produce.
run_E2() {
    require_granularity || return 0
    local a b c
    a="$(project_stream OMIT)"
    b="$(project_stream '{}')"
    c="$(project_stream '{"granularity":"full"}')"
    if [ "$a" = "$b" ] && [ "$a" = "$c" ]; then
        pass "E2: omitted / {} / {granularity:'full'} emit an identical event stream"
    else
        fail "E2: default spellings diverged"
        echo "--- omitted ---"; printf '%s\n' "$a"
        echo "--- {} ---";      printf '%s\n' "$b"
        echo "--- full ---";    printf '%s\n' "$c"
    fi
}

# E3 (#2297) — "same content" no longer buys full. A SIBLING worktree at the
# same commit as the upstream's is adopted degraded (worktree-dependent steps
# back to pending), the removed verifiedEquivalent/granularity inputs change
# nothing, and an unrelated repo is degraded too: #1305 is now kept by the
# context revert, not by a context-mismatch refusal.
e3_init_repo() {
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
run_E3() {
    if [ ! -f "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/inheritance/granularity.js" ]; then
        fail "E3: NOT YET IMPLEMENTED: hooks/workflow-state/inheritance/granularity.js (decideInheritanceGranularity, #2297) does not exist"
        return 0
    fi
    local tmp tn out main wt other main_n wt_n other_n
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    main="$tmp/main"; wt="$tmp/linked"; other="$tmp/other"
    e3_init_repo "$main"; e3_init_repo "$other"
    git -C "$main" worktree add -q -b feature/e3 "$wt" 2>/dev/null
    if [ ! -d "$wt" ]; then
        rm -rf "$tmp" 2>/dev/null || true
        fail "E3: fixture setup failed — could not create a linked worktree"
        return 0
    fi
    main_n="$(node_path "$main")"; wt_n="$(node_path "$wt")"; other_n="$(node_path "$other")"
    out=$(cd "$tn" && env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" CLAUDE_TRANSCRIPT_BASE_DIR="$tn/transcripts" \
        "$RWT" 60 node -e "
const { writeState, createInitialState, markStep, readState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const { adoptState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance/adopt');
const problems = [];
writeState('donor-e3', createInitialState('donor-e3', { cwd: '$main_n', git_branch: 'master' }));
markStep('donor-e3', 'workflow_init', 'complete');
require('$SCRIPT_CHECKOUT_ROOT_NODE/tests/lib/plan-approval-fixture').approveLive('donor-e3', 'clarify_intent');
markStep('donor-e3', 'clarify_intent', 'complete');
markStep('donor-e3', 'branching_complete', 'complete');
markStep('donor-e3', 'write_tests', 'complete');
const cases = [
  ['heir-e3-sib', '$wt_n', {}],
  ['heir-e3-sib-claim', '$wt_n', { verifiedEquivalent: true, granularity: 'full' }],
  ['heir-e3-other', '$other_n', {}],
];
for (const [heir, cwd, extra] of cases) {
  writeState(heir, createInitialState(heir, { cwd, git_branch: 'feature/e3' }));
  const r = adoptState(Object.assign({ heirSid: heir, donorSid: 'donor-e3' }, extra));
  if (r.ok !== true) { problems.push(heir + ':refused:' + r.error); continue; }
  if (r.granularity !== 'context-independent-only') problems.push(heir + ':granularity=' + String(r.granularity));
  const st = readState(heir) || {};
  const s = (k) => ((st.steps && st.steps[k]) || {});
  if (s('clarify_intent').status !== 'complete') problems.push(heir + ':clarify_intent-lost');
  for (const k of ['branching_complete', 'write_tests']) {
    if ((s(k).status || 'pending') !== 'pending') problems.push(heir + ':' + k + '=' + s(k).status);
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "E3: a SIBLING with equal content is still degraded (the claim is ignored); an unrelated repo is degraded, not refused"
    else
        fail "E3: expected 'OK', got '${out:-<err>}'"
    fi
}

# E4 — the new return value is additive. applyInheritance now reports
# {inherited_steps, reverted_steps, granularity}, but under the default that
# extra reporting must not change a single emitted event (E1 pins the stream;
# this pins the shape that accompanies it).
run_E4() {
    require_granularity || return 0
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    out=$(env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "
const { writeState, createInitialState, markStep, readState } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/inheritance');
const problems = [];
writeState('donor-e4', createInitialState('donor-e4', { cwd: '/fixture/repo', git_branch: 'feature/x' }));
markStep('donor-e4', 'workflow_init', 'complete');
markStep('donor-e4', 'detail', 'complete');
markStep('donor-e4', 'write_tests', 'complete');
writeState('heir-e4', createInitialState('heir-e4', { cwd: '/fixture/repo', git_branch: 'feature/x' }));
const res = applyInheritance('heir-e4', '2026-03-01T00:00:00.000Z', 'donor-e4');
if (!res || typeof res !== 'object') problems.push('no-return-value:' + JSON.stringify(res));
else {
  if (res.granularity !== 'full') problems.push('granularity:' + String(res.granularity));
  if (res.upstream_session_id !== 'donor-e4') problems.push('upstream_session_id:' + String(res.upstream_session_id));
  if (['copied', 'absent', 'failed'].indexOf(res.supervisor_state) === -1) problems.push('supervisor_state:' + String(res.supervisor_state));
  if (!Array.isArray(res.inherited_steps)) problems.push('inherited_steps-not-array');
  else {
    for (const s of ['workflow_init', 'detail', 'write_tests']) {
      if (res.inherited_steps.indexOf(s) === -1) problems.push('not-reported-inherited:' + s);
    }
  }
  if (!Array.isArray(res.reverted_steps)) problems.push('reverted_steps-not-array');
  else if (res.reverted_steps.length !== 0) problems.push('full-mode-reverted:' + JSON.stringify(res.reverted_steps));
}
const heir = readState('heir-e4');
const cleanup = heir.steps && heir.steps.cleanup;
if (!cleanup || cleanup.status !== 'skipped') problems.push('full-mode-cleanup-not-force-skipped:' + JSON.stringify(cleanup));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "E4: default applyInheritance reports {inherited_steps, reverted_steps:[], granularity:'full'} and still force-skips cleanup"
    else
        fail "E4: expected 'OK', got '${out:-<err>}'"
    fi
}

run_E1
run_E2
run_E3
run_E4

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
