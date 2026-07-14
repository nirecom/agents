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
# This is a dispatcher (file-split rule: >500 lines). Static cases live here;
# behavioral suite lives in feature-1351-skip-conditions-from-complexity/behavioral.sh.
#
# Pre-implementation model: the function may not exist yet. Static cases (SC-0,
# SC-W1..SC-W6) are NON-SKIPPABLE and FAIL until the impl + SKILL.md wiring land.
# Behavioral cases (SC-1..SC-25) guard on API_READY and SKIP (not FAIL) when the
# function is absent, so pre-impl the suite reports 7 FAIL + SKIPs (expected).

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not available"
    exit 77
fi

# shellcheck source=feature-1351-skip-conditions-from-complexity/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-1351-skip-conditions-from-complexity/_lib.sh"

# Clear inherited Claude Code session vars so resolveSessionId does not leak the
# outer session into --session-less probes.
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset CLAUDE_SESSION_ID 2>/dev/null || true

echo "=== skip-conditions-from-complexity: API_READY=$API_READY ==="

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
# SC-W1: clarify-intent SKILL.md calls record-complexity-and-skip (NON-SKIPPABLE)
# After the #1427 refactor, the resolver call moves into the shared wrapper;
# SKILL.md now invokes record-complexity-and-skip instead of the resolver directly.
# ==========================================================================
echo ""
echo "=== SC-W1: clarify-intent SKILL.md calls record-complexity-and-skip (static) ==="
if [ -f "$CI_SKILL" ] && grep -q 'record-complexity-and-skip' "$CI_SKILL"; then
    pass "SC-W1. clarify-intent SKILL.md references record-complexity-and-skip"
else
    fail "SC-W1. clarify-intent SKILL.md does NOT reference record-complexity-and-skip"
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
# SC-W3: clarify-intent SKILL.md passes --target outline to record-complexity-and-skip
# ==========================================================================
echo ""
echo "=== SC-W3: clarify-intent SKILL.md passes --target outline to record-complexity-and-skip (static) ==="
if [ -f "$CI_SKILL" ] && grep -qE '(--target outline|record-complexity-and-skip.*outline|outline.*record-complexity-and-skip)' "$CI_SKILL"; then
    pass "SC-W3. clarify-intent SKILL.md passes --target outline to record-complexity-and-skip"
else
    fail "SC-W3. clarify-intent SKILL.md does NOT pass --target outline"
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
# SC-W6: clarify-intent SKILL.md contains SKIP_MODE branching logic (NON-SKIPPABLE)
# After refactor, SKILL.md branches on SKIP_MODE=auto (wrapper stdout), not the
# old inline 'auto' node-e literal.
# ==========================================================================
echo ""
echo "=== SC-W6: clarify-intent SKILL.md contains SKIP_MODE branching logic (static) ==="
if [ -f "$CI_SKILL" ] && grep -qE 'SKIP_MODE|=auto\b' "$CI_SKILL"; then
    pass "SC-W6. clarify-intent SKILL.md contains SKIP_MODE/auto branch logic"
else
    fail "SC-W6. clarify-intent SKILL.md does NOT contain SKIP_MODE or auto branch logic"
fi

# ==========================================================================
# Behavioral suite (SC-1..SC-25, guarded on API_READY)
# ==========================================================================
# shellcheck source=feature-1351-skip-conditions-from-complexity/behavioral.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-1351-skip-conditions-from-complexity/behavioral.sh"

# ==========================================================================
echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"
