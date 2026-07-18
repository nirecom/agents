#!/usr/bin/env bash
# tests/feature-943-e2e-lang-inject.sh
# Tests: hooks/lang-inject.js
# Tags: e2e, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - CONV_LANG is injected via process.env (which wins over .env); a real session
#   resolves it from $AGENTS_CONFIG_DIR/.env, so .env-file parsing / OS-block
#   filtering interactions only surface in a real run.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/lang-inject.js"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found" >&2; exit 77; }
[ -f "$HOOK" ] || { echo "SKIP: hook not found: $HOOK" >&2; exit 77; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# On MSYS/Git-Bash, node resolves paths as native Windows. No-op on POSIX.
if command -v cygpath >/dev/null 2>&1; then TMP="$(cygpath -m "$TMP")"; fi

# Isolate workflow state so isPlanning() reads no state → no PLAN_LANG noise.
export CLAUDE_WORKFLOW_DIR="$TMP/workflow"
mkdir -p "$CLAUDE_WORKFLOW_DIR"

SID="feature943-li-00000000-0000-0000-0000-000000000008"

run_hook() {
  printf '%s' "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID\",\"prompt\":\"hi\"}" \
    | node "$HOOK"
}

# --- E1: CONV_LANG set → injection present ------------------------------------
set +e
OUT1="$(CONV_LANG=japanese run_hook)"; EXIT1=$?
set -e
if [ "$EXIT1" -eq 0 ] \
  && printf '%s' "$OUT1" | grep -q "Respond to the user in japanese" \
  && printf '%s' "$OUT1" | grep -q "additionalContext"; then
  pass "E1. CONV_LANG=japanese → conv-lang directive injected"
else
  fail "E1. expected japanese directive in additionalContext; got exit=$EXIT1 out=$OUT1"
fi

# --- E2: CONV_LANG=english (noop) → no injection (bare {}) --------------------
# "english" and "any" are the conv-lang noop values → null directive. Empty-string
# would let a .env CONV_LANG win (load-env treats "" as unset), so use "english".
set +e
OUT2="$(CONV_LANG=english PLAN_LANG=english run_hook)"; EXIT2=$?
set -e
if [ "$EXIT2" -eq 0 ] \
  && ! printf '%s' "$OUT2" | grep -q "Respond to the user in" \
  && [ "$(printf '%s' "$OUT2" | tr -d '[:space:]')" = "{}" ]; then
  pass "E2. CONV_LANG unset → no injection (emits {})"
else
  fail "E2. expected bare {} with no directive; got exit=$EXIT2 out=$OUT2"
fi

# --- E3: PLAN_LANG injection when planning step is pending [ACTIVE] ------------
# Create a state file with clarify_intent=pending so isPlanning() returns true.
# Then set PLAN_LANG=japanese → both CONV_LANG and PLAN_LANG directives appear.
STATE_FILE="$CLAUDE_WORKFLOW_DIR/$SID.json"
node -e '
  const fs = require("fs");
  const f = process.argv[1];
  const sid = process.argv[2];
  const state = {
    session_id: sid,
    steps: {
      workflow_init:    { status: "complete",  updated_at: null },
      clarify_intent:   { status: "pending",   updated_at: null },
      research:         { status: "pending",   updated_at: null },
      outline:          { status: "pending",   updated_at: null },
      detail:           { status: "pending",   updated_at: null },
      branching_complete: { status: "pending", updated_at: null },
      write_tests:      { status: "pending",   updated_at: null },
      review_tests:     { status: "pending",   updated_at: null },
      run_tests:        { status: "pending",   updated_at: null },
      review_security:  { status: "pending",   updated_at: null },
      docs:             { status: "pending",   updated_at: null },
      user_verification:{ status: "pending",   updated_at: null },
      cleanup:          { status: "pending",   updated_at: null },
      pre_final_report_gate: { status: "pending", updated_at: null },
    }
  };
  fs.writeFileSync(f, JSON.stringify(state), "utf8");
' "$STATE_FILE" "$SID"
set +e
OUT3="$(CONV_LANG=japanese PLAN_LANG=japanese run_hook)"; EXIT3=$?
set -e
rm -f "$STATE_FILE"
if [ "$EXIT3" -eq 0 ] \
  && printf '%s' "$OUT3" | grep -q "Respond to the user in japanese" \
  && printf '%s' "$OUT3" | grep -q "Write planning artifacts"; then
  pass "E3. PLAN_LANG=japanese + planning step pending → both CONV_LANG and PLAN_LANG injected"
else
  fail "E3. expected both conv-lang and plan-lang directives; got exit=$EXIT3 out=$OUT3"
fi

# --- E4: planning steps all complete → PLAN_LANG NOT injected (CPR-5) ---------
# isPlanning() returns false when all PLAN_STEPS are complete or skipped.
# This is the symmetric counterpart of E3 — the classifier boundary must suppress
# PLAN_LANG injection once planning is done.
STATE_FILE_DONE="$CLAUDE_WORKFLOW_DIR/${SID}-done.json"
node -e '
  const fs = require("fs");
  const f = process.argv[1]; const sid = process.argv[2];
  const state = { session_id: sid, steps: {
    workflow_init:    { status: "complete", updated_at: null },
    clarify_intent:   { status: "complete", updated_at: null },
    research:         { status: "complete", updated_at: null },
    outline:          { status: "complete", updated_at: null },
    detail:           { status: "complete", updated_at: null },
    write_tests:      { status: "pending",  updated_at: null },
    review_tests:     { status: "pending",  updated_at: null },
    run_tests:        { status: "pending",  updated_at: null },
    review_security:  { status: "pending",  updated_at: null },
    docs:             { status: "pending",  updated_at: null },
    user_verification:{ status: "pending",  updated_at: null },
    cleanup:          { status: "pending",  updated_at: null },
    pre_final_report_gate: { status: "pending", updated_at: null },
  }};
  fs.writeFileSync(f, JSON.stringify(state), "utf8");
' "$STATE_FILE_DONE" "${SID}-done"
SID_DONE="${SID}-done"
set +e
OUT4_DONE="$(CONV_LANG=japanese PLAN_LANG=japanese \
  printf '%s' "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID_DONE\",\"prompt\":\"hi\"}" \
  | node "$HOOK")"; EXIT4_DONE=$?
set -e
rm -f "$STATE_FILE_DONE"
if [ "$EXIT4_DONE" -eq 0 ] \
  && printf '%s' "$OUT4_DONE" | grep -q "Respond to the user in japanese" \
  && ! printf '%s' "$OUT4_DONE" | grep -q "Write planning artifacts"; then
  pass "E4. all planning steps complete → CONV_LANG injected but PLAN_LANG suppressed"
else
  fail "E4. expected no PLAN_LANG when planning done; got exit=$EXIT4_DONE out=$OUT4_DONE"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
