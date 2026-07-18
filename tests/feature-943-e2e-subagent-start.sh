#!/usr/bin/env bash
# tests/feature-943-e2e-subagent-start.sh
# Tests: hooks/subagent-start.js
# Tags: e2e, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - direct-stdin passes agent_type in the payload and PLAN_LANG via process.env;
#   the real SubagentStart event and the Task-tool dispatch that carries agent_type
#   are not exercised, so agent_type propagation quirks only surface in a real run.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/subagent-start.js"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found" >&2; exit 77; }
[ -f "$HOOK" ] || { echo "SKIP: hook not found: $HOOK" >&2; exit 77; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_hook() {
  local agent="$1"
  printf '%s' "{\"hook_event_name\":\"SubagentStart\",\"agent_type\":\"$agent\"}" \
    | node "$HOOK"
}

# --- E1: PLAN_LANG set + plan agent → PLAN_LANG directive injected [ACTIVE] ----
# outline-planner is whitelisted in PLAN_AGENTS. CONV_LANG cleared to isolate.
set +e
OUT1="$(CONV_LANG=english PLAN_LANG=japanese run_hook "outline-planner")"; EXIT1=$?
set -e
if [ "$EXIT1" -eq 0 ] \
  && printf '%s' "$OUT1" | grep -q "Write planning artifacts" \
  && printf '%s' "$OUT1" | grep -q "japanese"; then
  pass "E1. PLAN_LANG=japanese + outline-planner → PLAN_LANG directive injected"
else
  fail "E1. expected 'Write planning artifacts ... japanese'; got exit=$EXIT1 out=$OUT1"
fi

# --- E2: non-plan agent → no PLAN_LANG directive (conditional) ----------------
# A worker agent (not in PLAN_AGENTS) must NOT receive the PLAN_LANG directive
# even when PLAN_LANG is set.
set +e
OUT2="$(CONV_LANG=english PLAN_LANG=japanese run_hook "test-runner")"; EXIT2=$?
set -e
if [ "$EXIT2" -eq 0 ] && ! printf '%s' "$OUT2" | grep -q "Write planning artifacts"; then
  pass "E2. non-plan agent (test-runner) → no PLAN_LANG directive"
else
  fail "E2. non-plan agent should not get PLAN_LANG; got exit=$EXIT2 out=$OUT2"
fi

# --- E3: CONV_LANG injection for all agents (including workers) [ACTIVE] -------
# subagent-start.js calls getConvLangInjection() unconditionally for all agents.
# A non-plan agent (test-runner) with CONV_LANG=japanese → CONV_LANG directive.
set +e
OUT3="$(CONV_LANG=japanese PLAN_LANG=english run_hook "test-runner")"; EXIT3=$?
set -e
if [ "$EXIT3" -eq 0 ] && printf '%s' "$OUT3" | grep -q "Respond to the user in japanese"; then
  pass "E3. CONV_LANG=japanese + any agent → CONV_LANG directive injected"
else
  fail "E3. expected CONV_LANG directive for test-runner; got exit=$EXIT3 out=$OUT3"
fi

# --- E4: other PLAN_AGENTS whitelist member (CPR-5) ---------------------------
# detail-planner is also in PLAN_AGENTS; test that the Set lookup works for a
# second member (validates the Set itself, not just the outline-planner branch).
set +e
OUT4="$(CONV_LANG=english PLAN_LANG=japanese run_hook "detail-planner")"; EXIT4=$?
set -e
if [ "$EXIT4" -eq 0 ] && printf '%s' "$OUT4" | grep -q "Write planning artifacts"; then
  pass "E4. detail-planner (PLAN_AGENTS member) → PLAN_LANG directive injected"
else
  fail "E4. expected PLAN_LANG for detail-planner; got exit=$EXIT4 out=$OUT4"
fi

# --- E5: outline-reviewer (PLAN_AGENTS member, CPR-5 full-set) ----------------
# PLAN_AGENTS = {outline-planner, outline-reviewer, detail-planner, detail-reviewer}.
# E1 covers outline-planner, E4 covers detail-planner. Adding outline-reviewer
# validates that the Set lookup works for reviewer-type members as well.
set +e
OUT5="$(CONV_LANG=english PLAN_LANG=japanese run_hook "outline-reviewer")"; EXIT5=$?
set -e
if [ "$EXIT5" -eq 0 ] && printf '%s' "$OUT5" | grep -q "Write planning artifacts"; then
  pass "E5. outline-reviewer (PLAN_AGENTS member) → PLAN_LANG directive injected"
else
  fail "E5. expected PLAN_LANG for outline-reviewer; got exit=$EXIT5 out=$OUT5"
fi

# --- E6: no agent_type in payload → default empty output ({}) ------------------
# When agent_type is absent, PLAN_AGENTS.has(undefined) is false → no PLAN_LANG.
# With no CONV_LANG set either, lines is empty → hook outputs bare {}.
# Verifies the fail-open path for unknown/absent agent_type.
set +e
OUT6="$(printf '%s' '{"hook_event_name":"SubagentStart"}' | CONV_LANG=english PLAN_LANG=english node "$HOOK")"; EXIT6=$?
set -e
if [ "$EXIT6" -eq 0 ] && [ "$(printf '%s' "$OUT6" | tr -d '[:space:]')" = "{}" ]; then
  pass "E6. no agent_type + no lang settings → bare {} output"
else
  fail "E6. expected {} for absent agent_type; got exit=$EXIT6 out=$OUT6"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
