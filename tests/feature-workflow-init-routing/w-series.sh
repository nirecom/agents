#!/bin/bash
# tests/feature-workflow-init-routing/w-series.sh
# Tests: skills/workflow-init/SKILL.md
# Tags: workflow, init, routing, multi-n, scope:common
#
# W-series: Issue #444 (multi-N closes_issues) and Issue #797 (all-N routing)
# content assertions (W5-W14).

set -uo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

echo "=== Issue #444: workflow-init multi-N ==="
echo ""

# W5: SKILL.md no longer contains 'Move the selected entry to index 0'; ISSUES= still present (insertion order).
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W5: workflow-init insertion-order semantics check (file not found)"
elif grep -qE "ISSUES=" "$WORKFLOW_INIT_MD" && ! grep -qF "Move the selected entry to index 0" "$WORKFLOW_INIT_MD"; then
    pass "W5: SKILL.md retains ISSUES= and no longer contains 'Move the selected entry to index 0' (insertion order)"
else
    fail "W5: SKILL.md must retain ISSUES= AND must NOT contain 'Move the selected entry to index 0'"
fi

# W6a: >=2 issues handled by driver detect-issues phase (no AskUserQuestion for primary selection).
# Driver detect-issues.js processes all tokens without interactive narrowing.
DETECT_ISSUES_JS="$AGENTS_DIR/bin/workflow/lib/workflow-init/phases/detect-issues.js"
if [ ! -f "$DETECT_ISSUES_JS" ]; then
    fail "W6a: driver detect-issues.js not found (>=2 branch check failed)"
elif grep -qiE "(AskUserQuestion|pick.one|primary.issue)" "$DETECT_ISSUES_JS"; then
    fail "W6a: detect-issues.js must not invoke AskUserQuestion or reference 'primary issue'"
else
    pass "W6a: detect-issues.js handles >=2 tokens without AskUserQuestion or primary-issue narrowing"
fi
assert_absent_local "$WORKFLOW_INIT_MD" "pick one" \
    "W6b: 'pick one' (old narrowing behavior) is absent from SKILL.md"
assert_absent_local "$WORKFLOW_INIT_MD" "confirm-primary.sh" \
    "W6c: confirm-primary.sh is absent from workflow-init SKILL.md"

# W7: Path A section documents all-N symmetric handling (ISSUES[@] present).
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W7: Path A all-N documentation (file not found)"
else
    PATH_A_W7=$(awk '/^#### Path A/{in_a=1;next} in_a{if(/^#### /){exit}print}' "$WORKFLOW_INIT_MD")
    if printf '%s' "$PATH_A_W7" | grep -qF 'ISSUES[@]'; then
        pass "W7: Path A documents all-N handling via ISSUES[@]"
    else
        fail "W7: Path A missing all-N documentation (ISSUES[@] not found)"
    fi
fi

# W8: SKILL.md Step 1 mentions ISSUES[0], closes_issues[0], and 'becomes closes_issues[0]'.
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W8: index-zero mappings (file not found)"
elif grep -qE "ISSUES\[0\]" "$WORKFLOW_INIT_MD" \
  && grep -qE "closes_issues\[0\]" "$WORKFLOW_INIT_MD" \
  && grep -qF "becomes closes_issues[0]" "$WORKFLOW_INIT_MD"; then
    pass "W8: SKILL.md mentions ISSUES[0], closes_issues[0], and 'becomes closes_issues[0]'"
else
    fail "W8: SKILL.md must contain 'ISSUES[0]', 'closes_issues[0]', and 'becomes closes_issues[0]'"
fi

# W9: literal 'AskUserQuestion to pick one' must be absent (regression prevention).
assert_absent_local "$WORKFLOW_INIT_MD" "AskUserQuestion to pick one" \
    "W9: 'AskUserQuestion to pick one' old narrowing prompt is absent"

# W10: Path A section fail-closed regression prevention.
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W10: Path A fail-closed regression prevention (file not found)"
else
    PATH_A_SLICE=$(awk '
        /^#### Path A/ { in_a = 1 }
        in_a {
            if (/^#### Path [BC]/) { exit }
            print
        }
    ' "$WORKFLOW_INIT_MD")
    if printf '%s' "$PATH_A_SLICE" | grep -qF "ABORT" \
       && printf '%s' "$PATH_A_SLICE" | grep -qF -- '--add-label "intent:clarified"' \
       && printf '%s' "$PATH_A_SLICE" | grep -qF "aborted-pathA-multiN-label-failure"; then
        pass "W10a: Path A section contains ABORT, --add-label \"intent:clarified\", and aborted-pathA-multiN-label-failure"
    else
        fail "W10a: Path A section missing one of: ABORT / --add-label \"intent:clarified\" / aborted-pathA-multiN-label-failure"
    fi
    if printf '%s' "$PATH_A_SLICE" | grep -qF "continuing]"; then
        fail "W10b: Path A fail-open pattern 'continuing]' unexpectedly present"
    else
        pass "W10b: Path A fail-open pattern 'continuing]' is absent"
    fi
fi

# W12: WI-4 (driver fetch-issues phase) covers all-N fetch.
echo ""
echo "--- Issue #797: all-N routing assertions ---"

FETCH_ISSUES_JS="$AGENTS_DIR/bin/workflow/lib/workflow-init/phases/fetch-issues.js"
if [ ! -f "$FETCH_ISSUES_JS" ]; then
    fail "W12a: driver fetch-issues.js not found (all-N fetch check failed)"
elif grep -qE "(for|forEach|map|issues\.)" "$FETCH_ISSUES_JS" && grep -qE "issue.*view|gh.*issue" "$FETCH_ISSUES_JS"; then
    pass "W12a: driver fetch-issues.js contains all-N loop fetching via gh issue view"
else
    fail "W12a: driver fetch-issues.js must contain a loop for gh issue view per N"
fi
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W12b: SKILL.md not found"
else
    assert_absent_local "$WORKFLOW_INIT_MD" "from the primary's \`gh issue view\`" \
        "W12b: WI-4 no longer has primary-only fetch reference in label-extract context"
fi

# W13: WI-7 label extraction is per-N (not from primary's JSON).
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W13: WI-7 per-N label extract (file not found)"
else
    assert_absent_local "$WORKFLOW_INIT_MD" "from the primary's \`gh issue view\` JSON" \
        "W13: WI-7 no longer extracts labels from the primary's gh issue view JSON only"
fi

# W14: WI-8 (driver route-decision phase) routing predicate covers all N.
ROUTE_DECISION_JS="$AGENTS_DIR/bin/workflow/lib/workflow-init/phases/route-decision.js"
if [ ! -f "$ROUTE_DECISION_JS" ]; then
    fail "W14a: driver route-decision.js not found (all-N predicate check failed)"
elif grep -qE "(every|all|forEach|issues\.)" "$ROUTE_DECISION_JS" && grep -qE "intent.clarified" "$ROUTE_DECISION_JS"; then
    pass "W14a: driver route-decision.js contains all-N routing predicate with intent:clarified"
else
    fail "W14a: driver route-decision.js must contain all-N routing predicate (every N intent:clarified check)"
fi
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W14b: SKILL.md not found"
else
    assert_absent_local "$WORKFLOW_INIT_MD" "labels of primary" \
        "W14b: WI-8 no longer routes on 'labels of primary'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
