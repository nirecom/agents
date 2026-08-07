# tests/feature-complexity-evaluation-resolver/shim-cases.sh
# Tests: hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/state-io.js
# Tags: L2, workflow, complexity-evaluation, legacy-shim, scope:issue-specific
#
# Sourced by feature-complexity-evaluation-resolver.sh after cli-cases.sh — no
# shebang, no runner; cases run at source time. Owns the legacy-blob shim:
# SHIM-1..SHIM-5 (verdict=sonnet/opus mapped to level=low/high, no residual
# 'verdict' key, unknown verdict fails open, end-to-end through
# resolveSkipConditionsFromComplexity) and CE-LEVEL-INVALID-1..4.
#
# Depends on lib.sh for: API_READY, WORKFLOW_DIR_N, RESOLVER_N, run_with_timeout,
# write_raw_state, node_has, node_read_json, assert_eq, skip.

# ==========================================================================
# SHIM-1: legacy sonnet blob → readComplexityEvaluation returns level="low"
# ==========================================================================
echo ""
echo "=== SHIM-1: legacy verdict=sonnet blob → level=low ==="
if [ "$API_READY" = "true" ]; then
  SID="shim1-$$"
  write_raw_state "$SID" '{"session_id":"shim1","complexity_evaluation":{"verdict":"sonnet","signals":[],"recorded_at":"2026-01-01T00:00:00Z"}}'
  SHIM1_LEVEL="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.readComplexityEvaluation('$SID');
    console.log(v === null ? 'null' : (v.level || '__NO_LEVEL__'));
  " 2>/dev/null)"
  assert_eq "SHIM-1. legacy sonnet blob → level=low" 'low' "$SHIM1_LEVEL"
else
  skip "SHIM-1 (API absent)"
fi

# ==========================================================================
# SHIM-2: legacy opus blob → readComplexityEvaluation returns level="high"
# ==========================================================================
echo ""
echo "=== SHIM-2: legacy verdict=opus blob → level=high ==="
if [ "$API_READY" = "true" ]; then
  SID="shim2-$$"
  write_raw_state "$SID" '{"session_id":"shim2","complexity_evaluation":{"verdict":"opus","signals":["S1"],"recorded_at":"2026-01-01T00:00:00Z"}}'
  SHIM2_LEVEL="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.readComplexityEvaluation('$SID');
    console.log(v === null ? 'null' : (v.level || '__NO_LEVEL__'));
  " 2>/dev/null)"
  assert_eq "SHIM-2. legacy opus blob → level=high" 'high' "$SHIM2_LEVEL"
else
  skip "SHIM-2 (API absent)"
fi

# ==========================================================================
# SHIM-3: returned object must NOT have a 'verdict' key (non-destructive shim)
# ==========================================================================
echo ""
echo "=== SHIM-3: returned object has no 'verdict' key (shim non-destructive) ==="
if [ "$API_READY" = "true" ]; then
  SID="shim3-$$"
  write_raw_state "$SID" '{"session_id":"shim3","complexity_evaluation":{"verdict":"sonnet","signals":[],"recorded_at":"2026-01-01T00:00:00Z"}}'
  SHIM3_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.readComplexityEvaluation('$SID');
    if (v === null) { console.log('null'); }
    else { console.log(Object.prototype.hasOwnProperty.call(v, 'verdict') ? 'HAS_VERDICT' : 'NO_VERDICT'); }
  " 2>/dev/null)"
  assert_eq "SHIM-3. normalized object has no 'verdict' key" 'NO_VERDICT' "$SHIM3_OUT"
else
  skip "SHIM-3 (API absent)"
fi

# ==========================================================================
# SHIM-4: legacy unknown verdict → null (fail-open)
# ==========================================================================
echo ""
echo "=== SHIM-4: legacy unknown verdict=gpt blob → null (fail-open) ==="
if [ "$API_READY" = "true" ]; then
  SID="shim4-$$"
  write_raw_state "$SID" '{"session_id":"shim4","complexity_evaluation":{"verdict":"gpt","signals":[],"recorded_at":"2026-01-01T00:00:00Z"}}'
  SHIM4_OUT="$(node_read_json "$SID")"
  assert_eq "SHIM-4. unknown legacy verdict → null" 'null' "$SHIM4_OUT"
else
  skip "SHIM-4 (API absent)"
fi

# ==========================================================================
# SHIM-5: legacy sonnet+[] → resolveSkipConditionsFromComplexity returns populated
# (end-to-end shim: skip resolver reads through the shim and returns conditions)
# ==========================================================================
echo ""
echo "=== SHIM-5: legacy sonnet+[] → resolveSkipConditionsFromComplexity populated ==="
if [ "$API_READY" = "true" ]; then
  SID="shim5-$$"
  write_raw_state "$SID" '{"session_id":"shim5","complexity_evaluation":{"verdict":"sonnet","signals":[],"recorded_at":"2026-01-01T00:00:00Z"}}'
  SHIM5_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.resolveSkipConditionsFromComplexity('$SID', 'outline');
    if (v === null || v === undefined) { console.log('null'); }
    else {
      const allTrue = Object.values(v).every(x => x === true);
      console.log(allTrue ? 'POPULATED' : 'WRONG:' + JSON.stringify(v));
    }
  " 2>/dev/null)"
  assert_eq "SHIM-5. legacy sonnet+[] → skip conditions populated (end-to-end)" 'POPULATED' "$SHIM5_OUT"
else
  skip "SHIM-5 (API absent)"
fi

# ==========================================================================
# CE-LEVEL-INVALID: invalid level values → hasComplexityEvaluation false / null
# ==========================================================================
echo ""
echo "=== CE-LEVEL-INVALID: invalid level values in stored blobs ==="
if [ "$API_READY" = "true" ]; then
  SID="ceinvalid1-$$"
  write_raw_state "$SID" '{"session_id":"ceinvalid1","complexity_evaluation":{"level":"medium","signals":[],"recorded_at":"2026-07-11T00:00:00Z"}}'
  assert_eq "CE-LEVEL-INVALID-1. level=medium → hasComplexityEvaluation false" 'false' "$(node_has "$SID")"

  SID="ceinvalid2-$$"
  write_raw_state "$SID" '{"session_id":"ceinvalid2","complexity_evaluation":{"level":"opus","signals":[],"recorded_at":"2026-07-11T00:00:00Z"}}'
  assert_eq "CE-LEVEL-INVALID-2. level=opus → hasComplexityEvaluation false" 'false' "$(node_has "$SID")"

  SID="ceinvalid3-$$"
  write_raw_state "$SID" '{"session_id":"ceinvalid3","complexity_evaluation":{"level":"sonnet","signals":[],"recorded_at":"2026-07-11T00:00:00Z"}}'
  assert_eq "CE-LEVEL-INVALID-3. level=sonnet → hasComplexityEvaluation false" 'false' "$(node_has "$SID")"

  SID="ceinvalid4-$$"
  write_raw_state "$SID" '{"session_id":"ceinvalid4","complexity_evaluation":{"level":null,"signals":[],"recorded_at":"2026-07-11T00:00:00Z"}}'
  assert_eq "CE-LEVEL-INVALID-4. level=null → readComplexityEvaluation null" 'null' "$(node_read_json "$SID")"
else
  skip "CE-LEVEL-INVALID-1..4 (API absent)"
fi
