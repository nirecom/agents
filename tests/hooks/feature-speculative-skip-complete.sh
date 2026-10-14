#!/usr/bin/env bash
# Tests: hooks/workflow-state/state-io.js, hooks/workflow-mark/not-needed-handlers.js, bin/workflow/record-skip-verdict, bin/workflow/next-step, skills/clarify-intent/SKILL.md, skills/make-outline-plan/SKILL.md, settings.json, bin/workflow/lib/next-step/
# Tags: L1, L2, workflow, speculative-skip, scope:issue-specific
# #1392/#1352/#544/#1353 speculative-skip engine: pending outline/detail skip verdicts, confirm/veto via record-skip-verdict, next-step write_tests gate.
# Dispatcher (static cases here, behavioral suites in feature-speculative-skip-complete/, SKIP when impl absent); state via io.readState() (#1733 contract: tests/hooks/feature-1733-state-event-stream/annotation-fold.sh).
# L3 gap (what this test does NOT catch):
# - Real orchestrator skip path (real claude -p session speculative-skipping outline/detail)
# - a real confirm/veto resolution of a pending verdict reaching disk mid-session
# - write_tests gate blocking and unblocking across real workflow sessions
# Closest-to-action mitigation: wiring gap checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BARREL="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state.js"
BARREL_N="$(cygpath -m "$BARREL" 2>/dev/null || echo "$BARREL")"
STATEIO="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/state-io.js"
STATEIO_N="$(cygpath -m "$STATEIO" 2>/dev/null || echo "$STATEIO")"
COMPLETION_APPROVAL="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/completion-approval.js"
COMPLETION_APPROVAL_N="$(cygpath -m "$COMPLETION_APPROVAL" 2>/dev/null || echo "$COMPLETION_APPROVAL")"
HANDLERS="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark/not-needed-handlers.js"
HANDLERS_N="$(cygpath -m "$HANDLERS" 2>/dev/null || echo "$HANDLERS")"
NEXT_STEP="$SCRIPT_CHECKOUT_ROOT/bin/workflow/next-step"
RECORD_CLI="$SCRIPT_CHECKOUT_ROOT/bin/workflow/record-skip-verdict"

CI_SKILL="$SCRIPT_CHECKOUT_ROOT/skills/clarify-intent/SKILL.md"
MOP_SKILL="$SCRIPT_CHECKOUT_ROOT/skills/make-outline-plan/SKILL.md"
SETTINGS="$SCRIPT_CHECKOUT_ROOT/settings.json"
SETTINGS_N="$(cygpath -m "$SETTINGS" 2>/dev/null || echo "$SETTINGS")"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP (guarded): $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
  fi
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"
mkdir -p "$WORKFLOW_DIR"
WORKFLOW_DIR_N="$(cygpath -m "$WORKFLOW_DIR" 2>/dev/null || echo "$WORKFLOW_DIR")"

# Plans-dir isolation (#1799): supervisor-emit must never write into the
# developer's real ~/.workflow-plans/. Pinned alongside WORKFLOW_STATE_DIR.
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
WORKFLOW_PLANS_DIR="$(cygpath -m "$WORKFLOW_PLANS_DIR" 2>/dev/null || echo "$WORKFLOW_PLANS_DIR")"
export WORKFLOW_PLANS_DIR

# Clear inherited Claude Code session vars so resolveSessionId does not leak the
# outer session into --session-less probes.
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# --- Readiness probes --------------------------------------------------------
# API_READY: recordSkipVerdict + readSkipVerdict + hasSpeculativeSkipPending are
# all exported from the barrel (next-step and handlers consume via the barrel).
API_READY="$(node -e "
  try {
    const r = require('$BARREL_N');
    const ok = typeof r.recordSkipVerdict === 'function'
      && typeof r.readSkipVerdict === 'function'
      && typeof r.hasSpeculativeSkipPending === 'function';
    console.log(ok ? 'true' : 'false');
  } catch (e) { console.log('false'); }
" 2>/dev/null || echo "false")"

# CLI_READY: record-skip-verdict CLI file present.
CLI_READY="false"
[ -f "$RECORD_CLI" ] && CLI_READY="true"

# HANDLER_READY: recordSkipVerdict exported AND not-needed-handlers.js references it.
HANDLER_READY="false"
if [ "$API_READY" = "true" ] && [ -f "$HANDLERS" ] && grep -q 'recordSkipVerdict' "$HANDLERS"; then
  HANDLER_READY="true"
fi

# GATE_READY: next-step readSkipVerdict-based gate. API_READY suffices (gate reads it).
GATE_READY="$API_READY"

# ---- shared state helpers ---------------------------------------------------
node_call() {
  # Run a node snippet with WORKFLOW_STATE_DIR set; $1 = snippet.
  WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "$1" 2>&1
}

# Write a state file where a single step carries the given raw JSON object.
# Other steps are set to complete so next-step walks to the target step.
#
# The blanket-complete loop also completes the approval-gated steps
# (outline/detail, #1133) that are not the caller's target. Those completions
# would trip the completion-boundary invariant in writeState, so the fixture
# seeds a synthetic plan_approvals record for each non-target gated step. The
# source is a HASH_EXEMPT_SOURCES member, so no artifact hash is required and
# the fixture is independent of ambient CONFIRM_OUTLINE / CONFIRM_DETAIL.
write_gate_state() {
  local sid="$1" step="$2" step_json="$3"
  # #1733: state is an append-only event stream -- createInitialState() no
  # longer returns a .steps object to mutate directly (assertProjectionUnmutated
  # in writeState() would reject a hand-built projection anyway). Build the
  # fixture through the event API instead: markStep() for every step (the
  # target step last, with its raw JSON spread as extraFields so skip_reason /
  # skip_verdict / etc. round-trip as step_annotation events), and
  # recordPlanApproval() for the non-target approval-gated steps so the
  # completion-boundary invariant does not fire on the blanket-complete loop.
  WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    const approval = require('$COMPLETION_APPROVAL_N');
    io.writeState('$sid', io.createInitialState('$sid'));
    for (const k of io.VALID_STEPS) {
      if (k === '$step') continue;
      const extra = {};
      if (approval.isApprovalGatedStep(k)) {
        approval.recordPlanApproval('$sid', k, {
          source: 'confirm-flag-off',
          reason: 'test fixture',
        });
      }
      io.markStep('$sid', k, 'complete');
    }
    const targetEntry = $step_json;
    const targetExtra = Object.assign({}, targetEntry);
    delete targetExtra.status;
    delete targetExtra.updated_at;
    io.markStep('$sid', '$step', targetEntry.status, targetExtra);
  " 2>/dev/null
}

echo "=== speculative-skip-complete: API_READY=$API_READY CLI_READY=$CLI_READY HANDLER_READY=$HANDLER_READY GATE_READY=$GATE_READY ==="

# ==========================================================================
# STATIC (S1-S7 + S-API) — NON-SKIPPABLE. FAIL pre-impl, PASS post-impl (TDD).
# ==========================================================================

# S-API: barrel exports recordSkipVerdict / readSkipVerdict / hasSpeculativeSkipPending (C1 gap)
S_API_OUT="$(node -e "
  try {
    const r = require('$BARREL_N');
    const ok = typeof r.recordSkipVerdict === 'function'
      && typeof r.readSkipVerdict === 'function'
      && typeof r.hasSpeculativeSkipPending === 'function';
    console.log(ok ? 'yes' : 'no');
  } catch (e) { console.log('no'); }
" 2>/dev/null || echo 'no')"
assert_eq "S-API. barrel exports recordSkipVerdict+readSkipVerdict+hasSpeculativeSkipPending" 'yes' "$S_API_OUT"
echo ""
echo "=== STATIC cases (non-skippable) ==="

# S1 (#2460): jev-judge finalize is the only skip writer, so clarify-intent no longer
# calls record-complexity-and-skip (the A-4 pending verdict is co-written by the skip itself).
if [ -f "$CI_SKILL" ] && ! grep -qF "record-complexity-and-skip" "$CI_SKILL"; then
  pass "S1. clarify-intent no longer calls record-complexity-and-skip"
else
  fail "S1. clarify-intent is missing or still calls record-complexity-and-skip"
fi

# S1b: clarify-intent CI-C1c must NOT contain old 'manual' form (C1 gap)
if [ -f "$CI_SKILL" ] && grep -qF "process.stdout.write(v?'auto':'manual')" "$CI_SKILL"; then
  fail "S1b. clarify-intent CI-C1c still contains stale 'auto':'manual'"
else
  pass "S1b. clarify-intent CI-C1c has no stale 'auto':'manual'"
fi

# S2 (#2460): the check-outline-skip.sh / check-detail-skip.sh stubs are deleted with their
# MOP-1d / MOP-C1 callers.
MOP_OUTLINE_SKIP_S2="$SCRIPT_CHECKOUT_ROOT/skills/make-outline-plan/scripts/check-outline-skip.sh"
MOP_DETAIL_SKIP_S2="$SCRIPT_CHECKOUT_ROOT/skills/make-outline-plan/scripts/check-detail-skip.sh"
if [ ! -e "$MOP_OUTLINE_SKIP_S2" ] && [ ! -e "$MOP_DETAIL_SKIP_S2" ]; then
  pass "S2. check-outline-skip.sh and check-detail-skip.sh are deleted"
else
  fail "S2. a retired check-*-skip.sh stub still exists"
fi

# S3: make-outline-plan must NOT contain the old 'manual' form anywhere.
if [ -f "$MOP_SKILL" ] && grep -qF "process.stdout.write(v?'auto':'manual')" "$MOP_SKILL"; then
  fail "S3. make-outline-plan still contains stale 'auto':'manual'"
else
  pass "S3. make-outline-plan has no stale 'auto':'manual'"
fi

# S4 (#2460): the post-hoc skip-verifier agent is retired; the A-4 pending verdict stays and
# record-skip-verdict (S7) remains as its manual resolver.
if [ ! -e "$SCRIPT_CHECKOUT_ROOT/agents/skip-verifier.md" ]; then
  pass "S4. agents/skip-verifier.md is retired"
else
  fail "S4. agents/skip-verifier.md still exists"
fi

# S4b: its successor plan-skip-judge is a synchronous judge, never a verdict writer.
PLAN_SKIP_JUDGE="$SCRIPT_CHECKOUT_ROOT/agents/plan-skip-judge.md"
if [ -f "$PLAN_SKIP_JUDGE" ] && ! grep -qF "record-skip-verdict" "$PLAN_SKIP_JUDGE"; then
  pass "S4b. plan-skip-judge exists and does not write skip verdicts"
else
  fail "S4b. plan-skip-judge is missing or references record-skip-verdict"
fi

# S5: settings.json allow contains WORKFLOW_OUTLINE_NOT_NEEDED
S5_OUT="$(node -e "
  const s=require('$SETTINGS_N');
  const allow=(s.permissions&&s.permissions.allow)||[];
  console.log(allow.some(x=>/WORKFLOW_OUTLINE_NOT_NEEDED/.test(x))?'yes':'no');
" 2>/dev/null || echo 'no')"
assert_eq "S5. settings.json allow contains WORKFLOW_OUTLINE_NOT_NEEDED" 'yes' "$S5_OUT"

# S6: settings.json allow contains WORKFLOW_DETAIL_NOT_NEEDED
S6_OUT="$(node -e "
  const s=require('$SETTINGS_N');
  const allow=(s.permissions&&s.permissions.allow)||[];
  console.log(allow.some(x=>/WORKFLOW_DETAIL_NOT_NEEDED/.test(x))?'yes':'no');
" 2>/dev/null || echo 'no')"
assert_eq "S6. settings.json allow contains WORKFLOW_DETAIL_NOT_NEEDED" 'yes' "$S6_OUT"

# S6b: settings.json ask does NOT contain WORKFLOW_OUTLINE_NOT_NEEDED
S6B_OUT="$(node -e "
  const s=require('$SETTINGS_N');
  const ask=(s.permissions&&s.permissions.ask)||[];
  console.log(ask.some(x=>/WORKFLOW_OUTLINE_NOT_NEEDED/.test(x))?'yes':'no');
" 2>/dev/null || echo 'yes')"
assert_eq "S6b. settings.json ask does NOT contain WORKFLOW_OUTLINE_NOT_NEEDED" 'no' "$S6B_OUT"

# S6c: settings.json ask does NOT contain WORKFLOW_DETAIL_NOT_NEEDED
S6C_OUT="$(node -e "
  const s=require('$SETTINGS_N');
  const ask=(s.permissions&&s.permissions.ask)||[];
  console.log(ask.some(x=>/WORKFLOW_DETAIL_NOT_NEEDED/.test(x))?'yes':'no');
" 2>/dev/null || echo 'yes')"
assert_eq "S6c. settings.json ask does NOT contain WORKFLOW_DETAIL_NOT_NEEDED" 'no' "$S6C_OUT"

# S7: record-skip-verdict CLI file exists
if [ -f "$RECORD_CLI" ]; then
  pass "S7. bin/workflow/record-skip-verdict exists"
else
  fail "S7. bin/workflow/record-skip-verdict does NOT exist"
fi

# S8/S9 (#2460): no skill launches the retired skip-verifier any more.
if [ -f "$CI_SKILL" ] && ! grep -qF "skip-verifier" "$CI_SKILL"; then
  pass "S8. clarify-intent no longer launches skip-verifier"
else
  fail "S8. clarify-intent is missing or still names skip-verifier"
fi
if [ -f "$MOP_SKILL" ] && ! grep -qF "skip-verifier" "$MOP_SKILL"; then
  pass "S9. make-outline-plan no longer launches skip-verifier"
else
  fail "S9. make-outline-plan is missing or still names skip-verifier"
fi

# S10: A-5 detect-scope-change.sh exists (C5 gap)
DETECT_SCOPE="$SCRIPT_CHECKOUT_ROOT/bin/detect-scope-change.sh"
if [ -f "$DETECT_SCOPE" ]; then
  pass "S10. detect-scope-change.sh exists (A-5)"
else
  fail "S10. detect-scope-change.sh does NOT exist (pre-impl: expected FAIL)"
fi

# NS1: barrel exports recordSkipVerdict / readSkipVerdict / hasSpeculativeSkipPending
# (non-skippable static check — NOT guarded by API_READY)
NS1_OUT="$(node -e "
  try {
    const r = require('$BARREL_N');
    const ok = typeof r.recordSkipVerdict === 'function'
      && typeof r.readSkipVerdict === 'function'
      && typeof r.hasSpeculativeSkipPending === 'function';
    console.log(ok ? 'PRESENT' : 'MISSING:not-all-functions');
  } catch (e) { console.log('MISSING:' + e.message); }
" 2>/dev/null || echo 'MISSING:node-error')"
assert_eq "NS1. barrel exports recordSkipVerdict+readSkipVerdict+hasSpeculativeSkipPending (non-skippable)" 'PRESENT' "$NS1_OUT"

# ==========================================================================
# Behavioral suites (guarded) live in the sibling folder.
# ==========================================================================
SUITE_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-speculative-skip-complete"
# shellcheck source=./feature-speculative-skip-complete/l1-record-verdict.sh
. "$SUITE_DIR/l1-record-verdict.sh"
# shellcheck source=./feature-speculative-skip-complete/l1-read-verdict.sh
. "$SUITE_DIR/l1-read-verdict.sh"
# shellcheck source=./feature-speculative-skip-complete/l1-cli.sh
. "$SUITE_DIR/l1-cli.sh"
# shellcheck source=./feature-speculative-skip-complete/l2-handlers.sh
. "$SUITE_DIR/l2-handlers.sh"
# shellcheck source=./feature-speculative-skip-complete/l2-gate.sh
. "$SUITE_DIR/l2-gate.sh"

# ==========================================================================
echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"
