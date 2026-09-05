#!/usr/bin/env bash
# tests/feat-2218-inheritance-equivalence.sh
# Tests: hooks/workflow-state/inheritance/apply.js, hooks/workflow-state/inheritance/adopt.js, hooks/workflow-state/inheritance.js
# Tags: session-inherit, inheritance-granularity, equivalence-pin, regression-1305, regression-2218, scope:issue-specific, pwsh-not-required, TL2

# Issue #2218 Step 4 / Risks #1 — granularity is added to the SAME applyInheritance the automatic (lineage-keyed) path uses. The pin below is the whole mitigation: with `opts` omitted the emitted event stream must stay byte-identical to the pre-change behaviour, or #1305 (inheriting a foreign session's completions) reopens through the new parameter.

# TL3 gap: a real SessionStart-driven inheritance inside a live Claude Code session is not exercised here — only the shared applyInheritance/adoptState seam that hook path calls. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: workflow-state.

# The golden below was generated from the CURRENT implementation before any granularity code existed, via feat-2218-inheritance-equivalence/gen-golden.sh (same fixture donor as E1) — re-run that script to regenerate it after an approved change to the automatic path. E1 therefore passes today by design — it is a regression pin, not a pending feature. The remaining cases are RED until Step 4 lands.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

# Pre-change event stream for the fixture donor: 13 session-inherit events,
# sha256 over the normalized projection joined by newline.
GOLDEN_SHA="a935f223cbe7b434030c6a71f97e08676dae718435baf1c48f2a2e2306d5e646"
GOLDEN_COUNT="13"

# The granularity capability under test. apply.js already exists, so the RED
# signal here is the missing 4th parameter / the missing describe export.
require_granularity() {
    local out
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID "$RWT" 30 node -e "
const apply = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance/apply');
const missing = [];
if (typeof apply.applyInheritance !== 'function' || apply.applyInheritance.length < 4) missing.push('applyInheritance(sessionId,createdAt,donor,opts)');
if (typeof apply.describeGranularInheritance !== 'function') missing.push('describeGranularInheritance');
process.stdout.write(missing.join(','));
" 2>&1)
    if [ -z "$out" ]; then return 0; fi
    fail "NOT YET IMPLEMENTED: hooks/workflow-state/inheritance/apply.js is missing [$out] — expected per issue #2218 Step 4 (write_code has not run)"
    return 1
}

# Builds the fixture donor + heir and prints the normalized session-inherit
# event projection for the given `opts` literal ('OMIT' means: pass no 4th arg).
project_stream() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "
const crypto = require('crypto');
const { readState, writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance');
const donorSid = 'donor-2218-eq';
writeState(donorSid, createInitialState(donorSid, { cwd: '/fixture/repo', git_branch: 'feature/x' }));
markStep(donorSid, 'workflow_init', 'complete');
markStep(donorSid, 'clarify_intent', 'complete');
markStep(donorSid, 'outline', 'skipped', { skip_reason: 'trivial' });
markStep(donorSid, 'detail', 'complete');
markStep(donorSid, 'branching_complete', 'complete');
markStep(donorSid, 'write_tests', 'complete');
markStep(donorSid, 'review_tests', 'complete');
markStep(donorSid, 'run_tests', 'pending', { reset_reason: 'flaky-rerun' });
const donor = readState(donorSid);
const heirSid = 'heir-2218-eq';
const heirCreatedAt = '2026-03-01T00:00:00.000Z';
writeState(heirSid, createInitialState(heirSid, { cwd: '/other/repo', git_branch: 'main' }));
const mode = '$1';
if (mode === 'OMIT') applyInheritance(heirSid, heirCreatedAt, donor);
else applyInheritance(heirSid, heirCreatedAt, donor, JSON.parse(mode));
const heir = readState(heirSid);
const norm = heir.events.filter((e) => e.origin === 'session-inherit').map((e) => [
  e.kind, e.step, e.status || '', e.key || '',
  typeof e.value === 'string' ? e.value : JSON.stringify(e.value === undefined ? null : e.value),
  e.origin, e.provenance, e.inherited_from, e.at,
].join('|'));
process.stdout.write('COUNT=' + norm.length + '\n');
process.stdout.write('SHA=' + crypto.createHash('sha256').update(norm.join('\n')).digest('hex') + '\n');
process.stdout.write(norm.join('\n'));
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    printf '%s' "$out"
}

# E1 — the golden pin. `opts` omitted must reproduce the recorded pre-change
# stream exactly. On mismatch the actual stream is printed so the diff is
# readable without re-running anything.
run_E1() {
    local out sha count
    out="$(project_stream OMIT)"
    sha="$(printf '%s' "$out" | sed -n 's/^SHA=//p')"
    count="$(printf '%s' "$out" | sed -n 's/^COUNT=//p')"
    if [ "$sha" = "$GOLDEN_SHA" ] && [ "$count" = "$GOLDEN_COUNT" ]; then
        pass "E1: opts-omitted inheritance reproduces the pre-change event stream ($GOLDEN_COUNT events, sha $GOLDEN_SHA)"
    else
        fail "E1: event stream drifted — want count=$GOLDEN_COUNT sha=$GOLDEN_SHA, got count=${count:-<none>} sha=${sha:-<none>}"
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

# E3 — #1305 itself: the automatic path must keep rejecting a donor from a
# different cwd/branch. Adding granularity must not turn adoptState's default
# into the permissive column of detail.md Step 4's gate table.
run_E3() {
    require_granularity || return 0
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "
const { writeState, createInitialState, markStep, readState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const { adoptState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance/adopt');
const problems = [];
writeState('donor-e3', createInitialState('donor-e3', { cwd: '/fixture/repo', git_branch: 'feature/x' }));
markStep('donor-e3', 'workflow_init', 'complete');
markStep('donor-e3', 'clarify_intent', 'complete');
writeState('heir-e3', createInitialState('heir-e3', { cwd: '/other/repo', git_branch: 'main' }));
const r = adoptState({ heirSid: 'heir-e3', donorSid: 'donor-e3' });
if (r.ok !== false) problems.push('context-mismatch-accepted:' + JSON.stringify(r));
else if (String(r.error).indexOf('context-mismatch') === -1) problems.push('wrong-reason:' + r.error);
const heir = readState('heir-e3');
const inherited = (heir.events || []).filter((e) => e.origin === 'session-inherit');
if (inherited.length !== 0) problems.push('events-written-despite-rejection:' + inherited.length);
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "E3: default adoptState still rejects a cross-context donor and writes no events (#1305)"
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
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "
const { writeState, createInitialState, markStep, readState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const { applyInheritance } = require('$AGENTS_DIR_NODE/hooks/workflow-state/inheritance');
const problems = [];
writeState('donor-e4', createInitialState('donor-e4', { cwd: '/fixture/repo', git_branch: 'feature/x' }));
markStep('donor-e4', 'workflow_init', 'complete');
markStep('donor-e4', 'detail', 'complete');
markStep('donor-e4', 'write_tests', 'complete');
const donor = readState('donor-e4');
writeState('heir-e4', createInitialState('heir-e4', { cwd: '/fixture/repo', git_branch: 'feature/x' }));
const res = applyInheritance('heir-e4', '2026-03-01T00:00:00.000Z', donor);
if (!res || typeof res !== 'object') problems.push('no-return-value:' + JSON.stringify(res));
else {
  if (res.granularity !== 'full') problems.push('granularity:' + String(res.granularity));
  if (!Array.isArray(res.inherited_steps)) problems.push('inherited_steps-not-array');
  else {
    for (const s of ['workflow_init', 'detail', 'write_tests']) {
      if (res.inherited_steps.indexOf(s) === -1) problems.push('not-reported-inherited:' + s);
    }
  }
  if (!Array.isArray(res.reverted_steps)) problems.push('reverted_steps-not-array');
  else if (res.reverted_steps.length !== 0) problems.push('full-mode-reverted:' + res.reverted_steps.join(','));
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
