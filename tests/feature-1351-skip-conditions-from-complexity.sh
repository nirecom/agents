#!/usr/bin/env bash
# tests/feature-1351-skip-conditions-from-complexity.sh
# Tests: hooks/lib/workflow-state/skip-signal-resolver.js
# Tags: L1, workflow, speculative-skip, scope:issue-specific
# Security: N/A — pure read-only logic; no shell expansion, I/O mutation, or external untrusted input
# L3 gap (what this test does NOT catch):
# - Real orchestrator reading resolveSkipConditionsFromComplexity result and branching correctly at CI-C1c/MOP-1d/MOP-C1
# - End-to-end: 0-signal session auto-skipping outline/detail in a real claude -p session
# - SC-W1/SC-W2 grep the SKILL.md for the symbol name; they do NOT prove the orchestrator
#   invokes it at the correct step, with the correct target, or wired to record-skip-judgment
# Closest-to-action mitigation: wiring gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# Issue #1351 — resolveSkipConditionsFromComplexity(sessionId, targetStep) derives
# per-gate skip-condition objects from the persisted #1350 complexity evaluation.
#   0-signal-sonnet (ce.signals.length===0 AND ce.verdict==="sonnet"):
#     outline → {so_c1:true, so_c2:true}
#     detail  → {sd_c1:true, sd_c2:true, sd_c3:true}
#   all other cases (opus verdict, non-empty signals, invalid targetStep,
#     missing/corrupt state) → null (fail-open).
#   Return keys mirror CONDITION_SCHEMAS[targetStep]; values strictly === true.
#
# Pre-implementation model: the function may not exist yet. Static cases (SC-0,
# SC-W1, SC-W2) are NON-SKIPPABLE and FAIL until the impl + SKILL.md wiring land.
# Behavioral cases (SC-1..SC-11) guard on API_READY and SKIP (not FAIL) when the
# function is absent, so pre-impl the suite reports 3 FAIL + SKIPs (expected).

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$AGENTS_DIR/hooks/lib/workflow-state/skip-signal-resolver.js"
RESOLVER_N="$(cygpath -m "$RESOLVER" 2>/dev/null || echo "$RESOLVER")"
STATEIO="$AGENTS_DIR/hooks/lib/workflow-state/state-io.js"
STATEIO_N="$(cygpath -m "$STATEIO" 2>/dev/null || echo "$STATEIO")"

CI_SKILL="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
MOP_SKILL="$AGENTS_DIR/skills/make-outline-plan/SKILL.md"

# --- API presence probe (behavioral cases skip when absent) ------------------
API_READY="$(node -e "
  try {
    const r = require('$RESOLVER_N');
    console.log(typeof r.resolveSkipConditionsFromComplexity === 'function' ? 'true' : 'false');
  } catch (e) { console.log('false'); }
" 2>/dev/null || echo "false")"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"
mkdir -p "$WORKFLOW_DIR"
WORKFLOW_DIR_N="$(cygpath -m "$WORKFLOW_DIR" 2>/dev/null || echo "$WORKFLOW_DIR")"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP (pre-impl): $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    pass "$desc"
  else
    fail "$desc -- want [$want], got [$got]"
  fi
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

# record a complexity evaluation via the state-io write API.
node_record() {
  local sid="$1" verdict="$2" signals_json="$3"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    io.recordComplexityEvaluation('$sid', '$verdict', $signals_json);
  " 2>&1
}

# call resolveSkipConditionsFromComplexity; print canonical-key-sorted JSON or 'null'.
node_resolve() {
  local sid="$1" step="$2"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.resolveSkipConditionsFromComplexity('$sid', '$step');
    if (v === null || v === undefined) { console.log('null'); }
    else {
      const sorted = {};
      for (const k of Object.keys(v).sort()) sorted[k] = v[k];
      console.log(JSON.stringify(sorted));
    }
  " 2>/dev/null
}

# Hand-craft an opus-verdict record whose signals array is empty (SC-8 boundary).
record_opus_empty_signals() {
  local sid="$1"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    const s = io.createInitialState('$sid');
    s.complexity_evaluation = { verdict: 'opus', signals: [], recorded_at: new Date().toISOString() };
    io.writeState('$sid', s);
  " 2>/dev/null
}

write_raw_state() {
  local sid="$1" raw="$2"
  printf '%s' "$raw" > "$WORKFLOW_DIR/${sid}.json"
}

# Write an arbitrary complexity_evaluation JSON blob into a valid state file.
write_ce_state() {
  local sid="$1" ce_json="$2"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    const s = io.createInitialState('$sid');
    s.complexity_evaluation = $ce_json;
    io.writeState('$sid', s);
  " 2>/dev/null
}

# ==========================================================================
# SC-0: module exports resolveSkipConditionsFromComplexity (NON-SKIPPABLE)
# ==========================================================================
echo ""
echo "=== SC-0: function exported (static, non-skippable) ==="
SC0_OUT="$(node -e "
  try {
    const r = require('$RESOLVER_N');
    console.log(typeof r.resolveSkipConditionsFromComplexity);
  } catch (e) { console.log('load-error'); }
" 2>/dev/null || echo 'load-error')"
assert_eq "SC-0. resolveSkipConditionsFromComplexity is a function" 'function' "$SC0_OUT"

# ==========================================================================
# SC-W1: clarify-intent SKILL.md wires the resolver (NON-SKIPPABLE)
# ==========================================================================
echo ""
echo "=== SC-W1: clarify-intent SKILL.md references resolver (static) ==="
if [ -f "$CI_SKILL" ] && grep -q 'resolveSkipConditionsFromComplexity' "$CI_SKILL"; then
  pass "SC-W1. clarify-intent SKILL.md references resolveSkipConditionsFromComplexity"
else
  fail "SC-W1. clarify-intent SKILL.md does NOT reference resolveSkipConditionsFromComplexity"
fi

# ==========================================================================
# SC-W2: make-outline-plan SKILL.md wires the resolver (NON-SKIPPABLE)
# ==========================================================================
echo ""
echo "=== SC-W2: make-outline-plan SKILL.md references resolver (static) ==="
if [ -f "$MOP_SKILL" ] && grep -q 'resolveSkipConditionsFromComplexity' "$MOP_SKILL"; then
  pass "SC-W2. make-outline-plan SKILL.md references resolveSkipConditionsFromComplexity"
else
  fail "SC-W2. make-outline-plan SKILL.md does NOT reference resolveSkipConditionsFromComplexity"
fi

# ==========================================================================
# SC-W3: clarify-intent SKILL.md passes 'outline' to resolver (NON-SKIPPABLE)
# ==========================================================================
echo ""
echo "=== SC-W3: clarify-intent SKILL.md passes 'outline' to resolver (static) ==="
if [ -f "$CI_SKILL" ] && grep -qE "resolveSkipConditionsFromComplexity.*outline|'outline'.*resolveSkipConditionsFromComplexity" "$CI_SKILL"; then
  pass "SC-W3. clarify-intent SKILL.md passes 'outline' to resolveSkipConditionsFromComplexity"
else
  fail "SC-W3. clarify-intent SKILL.md does NOT pass 'outline' to resolveSkipConditionsFromComplexity"
fi

# ==========================================================================
# SC-W4: make-outline-plan SKILL.md uses 'outline' at MOP-1d (NON-SKIPPABLE)
# ==========================================================================
echo ""
echo "=== SC-W4: make-outline-plan SKILL.md uses 'outline' at MOP-1d (static) ==="
if [ -f "$MOP_SKILL" ] && grep -qE "resolveSkipConditionsFromComplexity.*outline|'outline'.*resolveSkipConditionsFromComplexity" "$MOP_SKILL"; then
  pass "SC-W4. make-outline-plan SKILL.md passes 'outline' to resolveSkipConditionsFromComplexity"
else
  fail "SC-W4. make-outline-plan SKILL.md does NOT pass 'outline' to resolveSkipConditionsFromComplexity"
fi

# ==========================================================================
# SC-W5: make-outline-plan SKILL.md uses 'detail' at MOP-C1 (NON-SKIPPABLE)
# ==========================================================================
echo ""
echo "=== SC-W5: make-outline-plan SKILL.md uses 'detail' at MOP-C1 (static) ==="
if [ -f "$MOP_SKILL" ] && grep -qE "resolveSkipConditionsFromComplexity.*detail|'detail'.*resolveSkipConditionsFromComplexity" "$MOP_SKILL"; then
  pass "SC-W5. make-outline-plan SKILL.md passes 'detail' to resolveSkipConditionsFromComplexity"
else
  fail "SC-W5. make-outline-plan SKILL.md does NOT pass 'detail' to resolveSkipConditionsFromComplexity"
fi

# ==========================================================================
# SC-W6: clarify-intent SKILL.md contains auto/manual branching logic (NON-SKIPPABLE)
# ==========================================================================
echo ""
echo "=== SC-W6: clarify-intent SKILL.md contains auto/manual branch (static) ==="
if [ -f "$CI_SKILL" ] && grep -qE "'auto'" "$CI_SKILL"; then
  pass "SC-W6. clarify-intent SKILL.md contains 'auto' branch logic"
else
  fail "SC-W6. clarify-intent SKILL.md does NOT contain 'auto' branch logic"
fi

# ==========================================================================
# SC-1: 0-signal-sonnet + outline → {so_c1:true, so_c2:true}
# ==========================================================================
echo ""
echo "=== SC-1: sonnet+[] outline → so_c1/so_c2 true ==="
if [ "$API_READY" = "true" ]; then
  SID="sc1-$$"
  node_record "$SID" "sonnet" '[]' >/dev/null
  assert_eq "SC-1. outline conditions from 0-signal-sonnet" '{"so_c1":true,"so_c2":true}' "$(node_resolve "$SID" outline)"
else
  skip "SC-1 (API absent)"
fi

# ==========================================================================
# SC-2: 0-signal-sonnet + detail → {sd_c1:true, sd_c2:true, sd_c3:true}
# ==========================================================================
echo ""
echo "=== SC-2: sonnet+[] detail → sd_c1/sd_c2/sd_c3 true ==="
if [ "$API_READY" = "true" ]; then
  SID="sc2-$$"
  node_record "$SID" "sonnet" '[]' >/dev/null
  assert_eq "SC-2. detail conditions from 0-signal-sonnet" '{"sd_c1":true,"sd_c2":true,"sd_c3":true}' "$(node_resolve "$SID" detail)"
else
  skip "SC-2 (API absent)"
fi

# ==========================================================================
# SC-3: opus + non-empty signals + outline → null
# ==========================================================================
echo ""
echo "=== SC-3: opus+[S1] outline → null ==="
if [ "$API_READY" = "true" ]; then
  SID="sc3-$$"
  node_record "$SID" "opus" '["S1-multi-file"]' >/dev/null
  assert_eq "SC-3. opus verdict → null (outline)" 'null' "$(node_resolve "$SID" outline)"
else
  skip "SC-3 (API absent)"
fi
# SC-8: verdict guard is load-bearing — opus+signals:[] intentionally returns null (see detail.md accepted tradeoffs)

# ==========================================================================
# SC-4: opus + non-empty signals + detail → null
# ==========================================================================
echo ""
echo "=== SC-4: opus+[S1] detail → null ==="
if [ "$API_READY" = "true" ]; then
  SID="sc4-$$"
  node_record "$SID" "opus" '["S1-multi-file"]' >/dev/null
  assert_eq "SC-4. opus verdict → null (detail)" 'null' "$(node_resolve "$SID" detail)"
else
  skip "SC-4 (API absent)"
fi

# ==========================================================================
# SC-5: no state file → null (fail-open)
# ==========================================================================
echo ""
echo "=== SC-5: missing state → null ==="
if [ "$API_READY" = "true" ]; then
  SID="sc5-missing-$$"
  assert_eq "SC-5. missing state file → null" 'null' "$(node_resolve "$SID" outline)"
else
  skip "SC-5 (API absent)"
fi

# ==========================================================================
# SC-6: invalid targetStep → null
# ==========================================================================
echo ""
echo "=== SC-6: sonnet+[] bogus step → null ==="
if [ "$API_READY" = "true" ]; then
  SID="sc6-$$"
  node_record "$SID" "sonnet" '[]' >/dev/null
  assert_eq "SC-6. invalid targetStep → null" 'null' "$(node_resolve "$SID" bogus)"
else
  skip "SC-6 (API absent)"
fi

# ==========================================================================
# SC-7: sonnet with signals present → null (signals must be empty)
# ==========================================================================
echo ""
echo "=== SC-7: sonnet+[S1,S2] detail → null ==="
if [ "$API_READY" = "true" ]; then
  SID="sc7-$$"
  node_record "$SID" "sonnet" '["S1","S2"]' >/dev/null
  assert_eq "SC-7. sonnet with non-empty signals → null" 'null' "$(node_resolve "$SID" detail)"
else
  skip "SC-7 (API absent)"
fi

# ==========================================================================
# SC-8: opus verdict + signals:[] → null (verdict guard, SC-8 load-bearing)
# ==========================================================================
echo ""
echo "=== SC-8: opus verdict + empty signals → null (verdict guard) ==="
if [ "$API_READY" = "true" ]; then
  SID="sc8-$$"
  record_opus_empty_signals "$SID"
  assert_eq "SC-8. opus+[] → null (verdict guard, not signals-only)" 'null' "$(node_resolve "$SID" outline)"
else
  skip "SC-8 (API absent)"
fi

# ==========================================================================
# SC-9: corrupt JSON state → null (fail-open, try/catch)
# ==========================================================================
echo ""
echo "=== SC-9: corrupt JSON state → null ==="
if [ "$API_READY" = "true" ]; then
  SID="sc9-$$"
  write_raw_state "$SID" '{invalid json'
  assert_eq "SC-9. corrupt state file → null" 'null' "$(node_resolve "$SID" outline)"
else
  skip "SC-9 (API absent)"
fi

# ==========================================================================
# SC-10: detail return has EXACTLY the CONDITION_SCHEMAS.detail keys (no extras)
# ==========================================================================
echo ""
echo "=== SC-10: detail return keys match CONDITION_SCHEMAS.detail exactly ==="
if [ "$API_READY" = "true" ]; then
  SID="sc10-$$"
  node_record "$SID" "sonnet" '[]' >/dev/null
  SC10_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.resolveSkipConditionsFromComplexity('$SID', 'detail');
    const expected = r.CONDITION_SCHEMAS.detail.slice().sort();
    const actual = Object.keys(v).sort();
    const same = actual.length === expected.length && actual.every((k, i) => k === expected[i]);
    console.log(same ? 'MATCH' : 'MISMATCH:' + JSON.stringify(actual));
  " 2>/dev/null)"
  assert_eq "SC-10. detail keys === CONDITION_SCHEMAS.detail (exact set)" 'MATCH' "$SC10_OUT"
else
  skip "SC-10 (API absent)"
fi

# ==========================================================================
# SC-11: outline values are strictly === true (not merely truthy)
# ==========================================================================
echo ""
echo "=== SC-11: outline values strictly === true ==="
if [ "$API_READY" = "true" ]; then
  SID="sc11-$$"
  node_record "$SID" "sonnet" '[]' >/dev/null
  SC11_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.resolveSkipConditionsFromComplexity('$SID', 'outline');
    const allStrictTrue = Object.values(v).every((x) => x === true);
    console.log(allStrictTrue ? 'STRICT_TRUE' : 'NOT_STRICT:' + JSON.stringify(Object.values(v)));
  " 2>/dev/null)"
  assert_eq "SC-11. outline values strictly === true" 'STRICT_TRUE' "$SC11_OUT"
else
  skip "SC-11 (API absent)"
fi

# ==========================================================================
# SC-12..SC-16: malformed complexity_evaluation fields → null (C4 coverage)
# ==========================================================================
echo ""
echo "=== SC-12..SC-16: malformed CE fields → null (fail-open) ==="
if [ "$API_READY" = "true" ]; then
  SID="sc12-$$"
  write_ce_state "$SID" '{"verdict":"sonnet","signals":null,"recorded_at":"2026-01-01T00:00:00Z"}'
  assert_eq "SC-12. signals:null → null" 'null' "$(node_resolve "$SID" outline)"

  SID="sc13-$$"
  write_ce_state "$SID" '{"verdict":"sonnet","signals":"","recorded_at":"2026-01-01T00:00:00Z"}'
  assert_eq "SC-13. signals:\"\" (string) → null" 'null' "$(node_resolve "$SID" outline)"

  SID="sc14-$$"
  write_ce_state "$SID" '{"verdict":"sonnet","recorded_at":"2026-01-01T00:00:00Z"}'
  assert_eq "SC-14. missing signals field → null" 'null' "$(node_resolve "$SID" outline)"

  SID="sc15-$$"
  write_ce_state "$SID" '{"signals":[],"recorded_at":"2026-01-01T00:00:00Z"}'
  assert_eq "SC-15. missing verdict field → null" 'null' "$(node_resolve "$SID" outline)"

  SID="sc16-$$"
  write_ce_state "$SID" '{"verdict":"","signals":[],"recorded_at":"2026-01-01T00:00:00Z"}'
  assert_eq "SC-16. verdict:\"\" → null" 'null' "$(node_resolve "$SID" outline)"
else
  skip "SC-12..SC-16 (API absent)"
  skip "SC-12..SC-16 (API absent)"
  skip "SC-12..SC-16 (API absent)"
  skip "SC-12..SC-16 (API absent)"
  skip "SC-12..SC-16 (API absent)"
fi

# ==========================================================================
# SC-17: idempotency — two calls on same state yield same result (C7)
# ==========================================================================
# ==========================================================================
# SC-18: adversarial sessionId (path traversal attempt) → null or safe-error
# The function must never read/write files outside WORKFLOW_DIR, so a
# traversal sessionId should fail gracefully (null) rather than crash.
# ==========================================================================
echo ""
echo "=== SC-18: adversarial sessionId → null (no path traversal) ==="
if [ "$API_READY" = "true" ]; then
  ADV_OUT="$(node_resolve "../../../etc/passwd" outline 2>/dev/null || echo "null")"
  assert_eq "SC-18. path-traversal sessionId → null" 'null' "$ADV_OUT"
else
  skip "SC-18 (API absent)"
fi

# ==========================================================================
echo ""
echo "=== SC-17: idempotency — two calls return identical result ==="
if [ "$API_READY" = "true" ]; then
  SID="sc17-$$"
  node_record "$SID" "sonnet" '[]' >/dev/null
  R1="$(node_resolve "$SID" outline)"
  R2="$(node_resolve "$SID" outline)"
  assert_eq "SC-17. idempotent: second call matches first" "$R1" "$R2"
else
  skip "SC-17 (API absent)"
fi


# ==========================================================================
# SC-19: single-element signals array → null (not treated as empty)
# ==========================================================================
echo ""
echo "=== SC-19: signals:[\"S1\"] (non-empty) → null ==="
if [ "$API_READY" = "true" ]; then
  SID="sc19-$$"
  node_record "$SID" "sonnet" '["S1"]' >/dev/null
  assert_eq "SC-19. single-element signals → null" 'null' "$(node_resolve "$SID" outline)"
else
  skip "SC-19 (API absent)"
fi

# ==========================================================================
# SC-20: duplicate signals → null (non-empty, not a special case)
# ==========================================================================
echo ""
echo "=== SC-20: signals:[\"S1\",\"S1\"] → null ==="
if [ "$API_READY" = "true" ]; then
  SID="sc20-$$"
  node_record "$SID" "sonnet" '["S1","S1"]' >/dev/null
  assert_eq "SC-20. duplicate signals → null" 'null' "$(node_resolve "$SID" outline)"
else
  skip "SC-20 (API absent)"
fi

# ==========================================================================
# SC-21: outline return has EXACTLY the CONDITION_SCHEMAS.outline keys
# (mirrors SC-10 for outline; both targets need key-set exactness check)
# ==========================================================================
echo ""
echo "=== SC-21: outline return keys match CONDITION_SCHEMAS.outline exactly ==="
if [ "$API_READY" = "true" ]; then
  SID="sc21-$$"
  node_record "$SID" "sonnet" '[]' >/dev/null
  SC21_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.resolveSkipConditionsFromComplexity('$SID', 'outline');
    const expected = r.CONDITION_SCHEMAS.outline.slice().sort();
    const actual = Object.keys(v).sort();
    const same = actual.length === expected.length && actual.every((k, i) => k === expected[i]);
    console.log(same ? 'MATCH' : 'MISMATCH:' + JSON.stringify(actual));
  " 2>/dev/null)"
  assert_eq "SC-21. outline keys === CONDITION_SCHEMAS.outline (exact set)" 'MATCH' "$SC21_OUT"
else
  skip "SC-21 (API absent)"
fi

# ==========================================================================
# SC-18b: absolute-path sessionId → null (no traversal outside WORKFLOW_DIR)
# ==========================================================================
echo ""
echo "=== SC-18b: absolute-path sessionId → null ==="
if [ "$API_READY" = "true" ]; then
  ABS_OUT="$(node_resolve "/etc/passwd" outline 2>/dev/null || echo "null")"
  assert_eq "SC-18b. absolute-path sessionId → null" 'null' "$ABS_OUT"
else
  skip "SC-18b (API absent)"
fi

# ==========================================================================
# SC-22: sessionId with slash → null (assertValidSessionId rejects non-[A-Za-z0-9_-])
# ==========================================================================
echo ""
echo "=== SC-22: sessionId with slash → null ==="
if [ "$API_READY" = "true" ]; then
  SC22_OUT="$(node_resolve "a/b" outline 2>/dev/null || echo "null")"
  assert_eq "SC-22. slash in sessionId → null" 'null' "$SC22_OUT"
else
  skip "SC-22 (API absent)"
fi

# ==========================================================================
# SC-23: sessionId with semicolon → null (assertValidSessionId rejects non-[A-Za-z0-9_-])
# ==========================================================================
echo ""
echo "=== SC-23: sessionId with semicolon → null ==="
if [ "$API_READY" = "true" ]; then
  SC23_OUT="$(node_resolve "a;b" outline 2>/dev/null || echo "null")"
  assert_eq "SC-23. semicolon in sessionId → null" 'null' "$SC23_OUT"
else
  skip "SC-23 (API absent)"
fi

# ==========================================================================
# SC-24: empty-string sessionId → null (assertValidSessionId rejects empty)
# ==========================================================================
echo ""
echo "=== SC-24: empty sessionId → null ==="
if [ "$API_READY" = "true" ]; then
  SC24_OUT="$(node_resolve "" outline 2>/dev/null || echo "null")"
  assert_eq "SC-24. empty sessionId → null" 'null' "$SC24_OUT"
else
  skip "SC-24 (API absent)"
fi

# ==========================================================================
# SC-25: targetStep="" (empty string) → null (not a valid schema key)
# ==========================================================================
echo ""
echo "=== SC-25: empty targetStep → null ==="
if [ "$API_READY" = "true" ]; then
  SID="sc25-$$"
  node_record "$SID" "sonnet" '[]' >/dev/null
  SC25_OUT="$(node_resolve "$SID" "" 2>/dev/null || echo "null")"
  assert_eq "SC-25. empty targetStep → null" 'null' "$SC25_OUT"
else
  skip "SC-25 (API absent)"
fi

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"
