# tests/feature-complexity-evaluation-resolver/shim-cases.sh
# Tests: hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/state-io.js
# Tags: L2, workflow, complexity-evaluation, legacy-shim, scope:issue-specific
# Sourced by feature-complexity-evaluation-resolver.sh after cli-cases.sh; cases run at
# source time, ungated — a missing required member FAILS at CE-REQ-1 in lib.sh, it never
# skips these. Owns the legacy verdict→level blob shim (SHIM-1..SHIM-5) and
# CE-LEVEL-INVALID-1..4; every helper comes from lib.sh.

# ==========================================================================
# SHIM-1: legacy sonnet blob → readComplexityEvaluation returns level="low"
# ==========================================================================
echo ""
echo "=== SHIM-1: legacy verdict=sonnet blob → level=low ==="
SID="shim1-$$"
write_raw_state "$SID" '{"session_id":"shim1","complexity_evaluation":{"verdict":"sonnet","signals":[],"recorded_at":"2026-01-01T00:00:00Z"}}'
SHIM1_LEVEL="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
  const r = require('$RESOLVER_N');
  const v = r.readComplexityEvaluation('$SID');
  console.log(v === null ? 'null' : (v.level || '__NO_LEVEL__'));
" 2>/dev/null)"
assert_eq "SHIM-1. legacy sonnet blob → level=low" 'low' "$SHIM1_LEVEL"

# ==========================================================================
# SHIM-2: legacy opus blob → readComplexityEvaluation returns level="high"
# ==========================================================================
echo ""
echo "=== SHIM-2: legacy verdict=opus blob → level=high ==="
SID="shim2-$$"
write_raw_state "$SID" '{"session_id":"shim2","complexity_evaluation":{"verdict":"opus","signals":["S1"],"recorded_at":"2026-01-01T00:00:00Z"}}'
SHIM2_LEVEL="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
  const r = require('$RESOLVER_N');
  const v = r.readComplexityEvaluation('$SID');
  console.log(v === null ? 'null' : (v.level || '__NO_LEVEL__'));
" 2>/dev/null)"
assert_eq "SHIM-2. legacy opus blob → level=high" 'high' "$SHIM2_LEVEL"

# ==========================================================================
# SHIM-3: returned object must NOT have a 'verdict' key (non-destructive shim)
# ==========================================================================
echo ""
echo "=== SHIM-3: returned object has no 'verdict' key (shim non-destructive) ==="
SID="shim3-$$"
write_raw_state "$SID" '{"session_id":"shim3","complexity_evaluation":{"verdict":"sonnet","signals":[],"recorded_at":"2026-01-01T00:00:00Z"}}'
SHIM3_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
  const r = require('$RESOLVER_N');
  const v = r.readComplexityEvaluation('$SID');
  if (v === null) { console.log('null'); }
  else { console.log(Object.prototype.hasOwnProperty.call(v, 'verdict') ? 'HAS_VERDICT' : 'NO_VERDICT'); }
" 2>/dev/null)"
assert_eq "SHIM-3. normalized object has no 'verdict' key" 'NO_VERDICT' "$SHIM3_OUT"

# ==========================================================================
# SHIM-4: legacy unknown verdict → null (fail-open)
# ==========================================================================
echo ""
echo "=== SHIM-4: legacy unknown verdict=gpt blob → null (fail-open) ==="
SID="shim4-$$"
write_raw_state "$SID" '{"session_id":"shim4","complexity_evaluation":{"verdict":"gpt","signals":[],"recorded_at":"2026-01-01T00:00:00Z"}}'
SHIM4_OUT="$(node_read_json "$SID")"
assert_eq "SHIM-4. unknown legacy verdict → null" 'null' "$SHIM4_OUT"

# ==========================================================================
# SHIM-5: legacy sonnet+[] → resolveSkipConditionsFromComplexity returns populated
# (end-to-end shim: skip resolver reads through the shim and returns conditions)
# ==========================================================================
echo ""
echo "=== SHIM-5: legacy sonnet+[] → resolveSkipConditionsFromComplexity populated ==="
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

# ==========================================================================
# CE-LEVEL-INVALID: invalid level values → hasComplexityEvaluation false / null
# ==========================================================================
echo ""
echo "=== CE-LEVEL-INVALID: invalid level values in stored blobs ==="
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
