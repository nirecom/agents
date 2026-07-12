#!/usr/bin/env bash
# Tests: hooks/lib/workflow-state/state-io.js, hooks/workflow-mark/not-needed-handlers.js, bin/workflow/record-skip-verdict, bin/workflow/next-step, agents/skip-verifier.md, skills/clarify-intent/SKILL.md, skills/make-outline-plan/SKILL.md, settings.json
# Tags: L1, L2, workflow, speculative-skip, scope:issue-specific
#
# Issues #1392, #1352, #544, #1353 — speculative-skip engine: outline/detail
# skips are recorded as speculative "pending" verdicts, verified by a
# skip-verifier subagent (confirm/veto), and gated at the write_tests step by
# next-step which reads the recorded verdict.
#
# Pre-implementation model: static cases (S1-S7) FAIL until write-code lands (expected).
# Behavioral cases guard on API_READY/CLI_READY and SKIP (not FAIL) when impl absent.
#
# This is a dispatcher (file-split rule: >500 lines). Static cases live here;
# behavioral suites live in the sibling feature-speculative-skip-complete/ folder.
#
# L3 gap (what this test does NOT catch):
# - Real orchestrator skip path (real claude -p session speculative-skipping outline/detail)
# - skip-verifier agent actually launching in parallel and writing verdict to disk
# - write_tests gate blocking and unblocking across real workflow sessions
# Closest-to-action mitigation: wiring gap checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BARREL="$AGENTS_DIR/hooks/lib/workflow-state.js"
BARREL_N="$(cygpath -m "$BARREL" 2>/dev/null || echo "$BARREL")"
STATEIO="$AGENTS_DIR/hooks/lib/workflow-state/state-io.js"
STATEIO_N="$(cygpath -m "$STATEIO" 2>/dev/null || echo "$STATEIO")"
HANDLERS="$AGENTS_DIR/hooks/workflow-mark/not-needed-handlers.js"
HANDLERS_N="$(cygpath -m "$HANDLERS" 2>/dev/null || echo "$HANDLERS")"
NEXT_STEP="$AGENTS_DIR/bin/workflow/next-step"
RECORD_CLI="$AGENTS_DIR/bin/workflow/record-skip-verdict"

CI_SKILL="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
MOP_SKILL="$AGENTS_DIR/skills/make-outline-plan/SKILL.md"
SKIP_VERIFIER="$AGENTS_DIR/agents/skip-verifier.md"
SETTINGS="$AGENTS_DIR/settings.json"
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

# Clear inherited Claude Code session vars so resolveSessionId does not leak the
# outer session into --session-less probes.
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset CLAUDE_SESSION_ID 2>/dev/null || true

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
  # Run a node snippet with CLAUDE_WORKFLOW_DIR set; $1 = snippet.
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "$1" 2>&1
}

# Write a state file where a single step carries the given raw JSON object.
# Other steps are set to complete so next-step walks to the target step.
write_gate_state() {
  local sid="$1" step="$2" step_json="$3"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    const s = io.createInitialState('$sid');
    for (const k of Object.keys(s.steps)) {
      s.steps[k] = { status: 'complete', updated_at: '2026-04-11T10:00:00.000Z' };
    }
    s.steps['$step'] = $step_json;
    io.writeState('$sid', s);
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

# S1: clarify-intent CI-C1c uses 'judgment' not 'manual'
if [ -f "$CI_SKILL" ] && grep -qF "process.stdout.write(v?'auto':'judgment')" "$CI_SKILL"; then
  pass "S1. clarify-intent CI-C1c emits 'auto':'judgment' (not 'manual')"
else
  fail "S1. clarify-intent CI-C1c does NOT emit 'auto':'judgment'"
fi

# S1b: clarify-intent CI-C1c must NOT contain old 'manual' form (C1 gap)
if [ -f "$CI_SKILL" ] && grep -qF "process.stdout.write(v?'auto':'manual')" "$CI_SKILL"; then
  fail "S1b. clarify-intent CI-C1c still contains stale 'auto':'manual'"
else
  pass "S1b. clarify-intent CI-C1c has no stale 'auto':'manual'"
fi

# S2: make-outline-plan MOP-1d/MOP-C1 both use 'judgment' (≥2 occurrences, C2 gap)
S2_COUNT="$(grep -cF "process.stdout.write(v?'auto':'judgment')" "$MOP_SKILL" 2>/dev/null || echo 0)"
if [ -f "$MOP_SKILL" ] && [ "$S2_COUNT" -ge 2 ]; then
  pass "S2. make-outline-plan contains 'auto':'judgment' ×${S2_COUNT} (MOP-1d + MOP-C1)"
else
  fail "S2. make-outline-plan should have ≥2 'auto':'judgment', found=${S2_COUNT}"
fi

# S3: make-outline-plan must NOT contain the old 'manual' form anywhere.
if [ -f "$MOP_SKILL" ] && grep -qF "process.stdout.write(v?'auto':'manual')" "$MOP_SKILL"; then
  fail "S3. make-outline-plan still contains stale 'auto':'manual'"
else
  pass "S3. make-outline-plan has no stale 'auto':'manual'"
fi

# S4: skip-verifier subagent exists
if [ -f "$SKIP_VERIFIER" ]; then
  pass "S4. agents/skip-verifier.md exists"
else
  fail "S4. agents/skip-verifier.md does NOT exist"
fi

# S4b: skip-verifier.md references record-skip-verdict CLI (C4 gap)
if [ -f "$SKIP_VERIFIER" ] && grep -qF "record-skip-verdict" "$SKIP_VERIFIER"; then
  pass "S4b. skip-verifier.md references record-skip-verdict"
else
  fail "S4b. skip-verifier.md does NOT reference record-skip-verdict (pre-impl: expected FAIL)"
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

# S8: CI-C1c (clarify-intent) instructs parallel skip-verifier launch (C3 gap)
if [ -f "$CI_SKILL" ] && grep -qF "skip-verifier" "$CI_SKILL"; then
  pass "S8. clarify-intent CI-C1c wires skip-verifier parallel launch"
else
  fail "S8. clarify-intent CI-C1c does NOT wire skip-verifier (pre-impl: expected FAIL)"
fi

# S9: MOP-C1 (make-outline-plan) instructs parallel skip-verifier launch (C3 gap)
if [ -f "$MOP_SKILL" ] && grep -qF "skip-verifier" "$MOP_SKILL"; then
  pass "S9. make-outline-plan MOP-C1 wires skip-verifier parallel launch"
else
  fail "S9. make-outline-plan MOP-C1 does NOT wire skip-verifier (pre-impl: expected FAIL)"
fi

# S10: A-5 detect-scope-change.sh exists (C5 gap)
DETECT_SCOPE="$AGENTS_DIR/skills/make-detail-plan/scripts/detect-scope-change.sh"
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
