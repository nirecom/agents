#!/usr/bin/env bash
# tests/feat-2218-step-context-class.sh
# Tests: hooks/workflow-state/state-io/step-context-class.js, hooks/workflow-state/state-io.js
# Tags: workflow-state, step-classification, context-independence, handoff, regression-2218, scope:issue-specific, pwsh-not-required, TL1

# Issue #2218 Step 3 — SSOT for "does this step's completion evidence live in the worktree, or in PLANS_DIR?". Inheritance granularity (Step 4) reads this map, so a missing or wrong entry silently carries a prior session's worktree-bound completions into a worktree where that evidence never existed (detail.md Risks #2).

# TL3 gap: a real /resume-session --from run in a second worktree, where a misclassified step surfaces as "complete" with no artifact on disk, is not exercised here; neither is drift against a VALID_STEPS addition made on a branch that never runs this file. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: workflow-state.

# TDD (write_code has not run): every case below is expected to FAIL with "MODULE NOT FOUND: hooks/workflow-state/state-io/step-context-class.js" until the module is implemented.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

TARGET="hooks/workflow-state/state-io/step-context-class.js"

# RED gate: the module under test does not exist yet. Fail loudly and name the
# expected path rather than skipping — a silent skip would read as green.
require_module() {
    if [ -f "$AGENTS_DIR/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2218, not yet implemented (write_code has not run)"
    return 1
}

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

# L1 — totality: every VALID_STEPS member is classified, and the map carries no
# step VALID_STEPS does not know about (both directions; a one-way check would
# let a typo'd key pass as a harmless extra entry).
run_L1() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const { VALID_STEPS } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io/core');
const { STEP_CONTEXT_CLASS } = require('$AGENTS_DIR_NODE/$TARGET');
const problems = [];
const keys = Object.keys(STEP_CONTEXT_CLASS);
const missing = VALID_STEPS.filter((s) => !(s in STEP_CONTEXT_CLASS));
const extra = keys.filter((k) => !VALID_STEPS.includes(k));
if (missing.length) problems.push('unclassified-steps:' + missing.join(','));
if (extra.length) problems.push('unknown-keys:' + extra.join(','));
if (VALID_STEPS.length !== 16) problems.push('valid-steps-count:' + VALID_STEPS.length);
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "L1: STEP_CONTEXT_CLASS covers VALID_STEPS exactly (totality, both directions)"
    else
        fail "L1: expected 'OK', got '${out:-<err>}'"
    fi
}

# L2 — table-driven classification of all 16 steps against detail.md Step 3.
# The expected table is restated here on purpose: it is the reviewed decision,
# not a mirror of whatever the implementation happens to say.
run_L2() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const { STEP_CONTEXT_CLASS } = require('$AGENTS_DIR_NODE/$TARGET');
const EXPECTED = {
  workflow_init: 'context-independent',
  clarify_intent: 'context-independent',
  research: 'context-independent',
  outline: 'context-independent',
  detail: 'context-independent',
  branching_complete: 'worktree-dependent',
  write_tests: 'worktree-dependent',
  review_tests: 'worktree-dependent',
  write_code: 'worktree-dependent',
  run_tests: 'worktree-dependent',
  review_security: 'worktree-dependent',
  docs: 'worktree-dependent',
  user_verification: 'worktree-dependent',
  cleanup: 'worktree-dependent',
  pre_final_report_gate: 'worktree-dependent',
  final_report: 'worktree-dependent',
};
const problems = [];
for (const step of Object.keys(EXPECTED)) {
  const got = STEP_CONTEXT_CLASS[step];
  if (got !== EXPECTED[step]) problems.push(step + ':want=' + EXPECTED[step] + ',got=' + String(got));
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "L2: all 16 steps carry the classification recorded in detail.md Step 3"
    else
        fail "L2: expected 'OK', got '${out:-<err>}'"
    fi
}

# L3 — the boundary pair. `detail` is the LAST context-independent step and
# `branching_complete` the FIRST worktree-dependent one; an off-by-one here is
# the most damaging misclassification (it inherits a branch/worktree completion
# into a session that has neither).
run_L3() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const { STEP_CONTEXT_CLASS, isContextIndependentStep } = require('$AGENTS_DIR_NODE/$TARGET');
const { VALID_STEPS } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io/core');
const problems = [];
if (STEP_CONTEXT_CLASS.detail !== 'context-independent') problems.push('detail:' + String(STEP_CONTEXT_CLASS.detail));
if (STEP_CONTEXT_CLASS.branching_complete !== 'worktree-dependent') problems.push('branching_complete:' + String(STEP_CONTEXT_CLASS.branching_complete));
if (isContextIndependentStep('detail') !== true) problems.push('isContextIndependentStep(detail)!==true');
if (isContextIndependentStep('branching_complete') !== false) problems.push('isContextIndependentStep(branching_complete)!==false');
const bIdx = VALID_STEPS.indexOf('branching_complete');
const late = VALID_STEPS.slice(bIdx).filter((s) => isContextIndependentStep(s));
if (late.length) problems.push('context-independent-after-branching:' + late.join(','));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "L3: boundary pair detail / branching_complete, and no context-independent step after branching"
    else
        fail "L3: expected 'OK', got '${out:-<err>}'"
    fi
}

# L4 — isContextIndependentStep() on unknown / malformed input. A classifier the
# inheritance loop consults must answer for every verdict and must not throw; an
# unknown step is NOT context-independent (the conservative side leaves it
# pending instead of inheriting it).
run_L4() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const { isContextIndependentStep } = require('$AGENTS_DIR_NODE/$TARGET');
const problems = [];
const cases = [['plan', false], ['', false], ['DETAIL', false], ['detail ', false]];
for (const c of cases) {
  let got;
  try { got = isContextIndependentStep(c[0]); }
  catch (e) { problems.push('threw-on:' + JSON.stringify(c[0]) + ':' + e.message); continue; }
  if (got !== c[1]) problems.push(JSON.stringify(c[0]) + ':want=' + c[1] + ',got=' + String(got));
}
for (const bad of [null, undefined, 42, {}]) {
  let got;
  try { got = isContextIndependentStep(bad); }
  catch (e) { problems.push('threw-on:' + String(bad) + ':' + e.message); continue; }
  if (got !== false) problems.push('nonstring:' + String(bad) + ':got=' + String(got));
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "L4: isContextIndependentStep is total and fail-safe on unknown / non-string input"
    else
        fail "L4: expected 'OK', got '${out:-<err>}'"
    fi
}

# L5 — CONTEXT_CLASS_VALUES is the vocabulary SSOT, and STEP_CONTEXT_CLASS is
# frozen so a consumer cannot re-classify a step at runtime.
run_L5() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const mod = require('$AGENTS_DIR_NODE/$TARGET');
const problems = [];
const values = mod.CONTEXT_CLASS_VALUES;
if (!Array.isArray(values)) problems.push('CONTEXT_CLASS_VALUES-not-array:' + String(values));
else {
  const sorted = values.slice().sort().join(',');
  if (sorted !== 'context-independent,worktree-dependent') problems.push('vocabulary:' + sorted);
}
const used = Array.from(new Set(Object.values(mod.STEP_CONTEXT_CLASS))).sort().join(',');
if (used !== 'context-independent,worktree-dependent') problems.push('values-used:' + used);
if (!Object.isFrozen(mod.STEP_CONTEXT_CLASS)) problems.push('map-not-frozen');
try { mod.STEP_CONTEXT_CLASS.detail = 'worktree-dependent'; } catch (e) { /* strict-mode TypeError is acceptable */ }
if (mod.STEP_CONTEXT_CLASS.detail !== 'context-independent') problems.push('map-mutated-at-runtime');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "L5: CONTEXT_CLASS_VALUES is the 2-value vocabulary and STEP_CONTEXT_CLASS is frozen"
    else
        fail "L5: expected 'OK', got '${out:-<err>}'"
    fi
}

# L6 — barrel re-export. detail.md Step 3 places the classification next to
# VALID_STEPS in the state-io barrel; hooks/workflow-state.js spreads that
# barrel, so both entrypoints must expose the same identity.
run_L6() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
const direct = require('$AGENTS_DIR_NODE/$TARGET');
const barrel = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const top = require('$AGENTS_DIR_NODE/hooks/workflow-state');
const problems = [];
for (const name of ['STEP_CONTEXT_CLASS', 'isContextIndependentStep', 'CONTEXT_CLASS_VALUES']) {
  if (barrel[name] === undefined) problems.push('state-io-missing:' + name);
  else if (barrel[name] !== direct[name]) problems.push('state-io-not-same-identity:' + name);
  if (top[name] === undefined) problems.push('workflow-state-missing:' + name);
}
if (barrel.VALID_STEPS === undefined) problems.push('barrel-lost-VALID_STEPS');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "L6: state-io.js and hooks/workflow-state.js re-export the classification alongside VALID_STEPS"
    else
        fail "L6: expected 'OK', got '${out:-<err>}'"
    fi
}

run_L1
run_L2
run_L3
run_L4
run_L5
run_L6

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
