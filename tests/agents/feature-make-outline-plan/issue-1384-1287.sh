# Tests: agents/outline-planner.md, agents/outline-planner/output-format.md
# Tags: outline, planning, skill, scope:common
# Issue #1384 frontrunner-collapse and Issue #1287 intent-lock cases.
# Sourced by tests/agents/feature-make-outline-plan.sh.

# ---------------------------------------------------------------------------
# Issue #1384: frontrunner-collapse rule
# ---------------------------------------------------------------------------
case_begin "Issue 1384 frontrunner-collapse" "agents/outline-planner.md"

AGENTS_ROOT_1384="$(cd "$(dirname "$0")/../.." && (pwd -W 2>/dev/null || pwd))"
PLANNER_1384="$AGENTS_ROOT_1384/agents/outline-planner.md"
OUTPUT_FORMAT_1384="$AGENTS_ROOT_1384/agents/outline-planner/output-format.md"

# 1384-1: frontrunner-collapse keyword present in outline-planner.md
assert_contains "$PLANNER_1384" "frontrunner-collapse" \
    "1384-1: frontrunner-collapse keyword present in agents/outline-planner.md"

# 1384-2: frontrunner-collapse form present in output-format.md
assert_contains "$OUTPUT_FORMAT_1384" "frontrunner-collapse" \
    "1384-2: frontrunner-collapse form present in agents/outline-planner/output-format.md"

case_end
echo ""
# ---------------------------------------------------------------------------
# Issue #1287: intent-lock collapse rule + straw-alternative prohibition
# ---------------------------------------------------------------------------
case_begin "Issue 1287 intent-lock" "agents/outline-planner.md"

AGENTS_ROOT_1287="$(cd "$(dirname "$0")/../.." && (pwd -W 2>/dev/null || pwd))"
PLANNER_1287="$AGENTS_ROOT_1287/agents/outline-planner.md"

# 1287-1: intent-lock collapse rule keyword present
assert_contains "$PLANNER_1287" "intent.lock" \
    "1287-1: intent-lock collapse rule keyword present in outline-planner.md"

# 1287-2: Accepted Tradeoffs referenced as trigger (unique pattern avoids existing line 113)
assert_contains "$PLANNER_1287" "Accepted Tradeoffs.*has already been decided|already been decided" \
    "1287-2: Accepted Tradeoffs 'has already been decided' language present in outline-planner.md"

# 1287-3: straw-alternative prohibition
assert_contains "$PLANNER_1287" "straw.alternative|straw.mann" \
    "1287-3: straw-alternative prohibition keyword present in outline-planner.md"

# 1287-4: line-101 exception clause
assert_contains "$PLANNER_1287" "Exception.*SINGLE_APPROACH_JUSTIFIED|SINGLE_APPROACH_JUSTIFIED.*Exception" \
    "1287-4: line-101 exception clause referencing SINGLE_APPROACH_JUSTIFIED present in outline-planner.md"

# 1287-5: protocol violation for fabricating alternatives
assert_contains "$PLANNER_1287" "Fabricating alternatives.*protocol violation" \
    "1287-5: protocol violation for fabricating alternatives under intent-lock present in outline-planner.md"

# 1287-6: Procedure pre-check present (verifies Procedure flow, not just Rules)
assert_contains "$PLANNER_1287" "Do not proceed to step 3" \
    "1287-6: Procedure pre-check step present (intent-lock check before step 3)"

case_end
echo ""
