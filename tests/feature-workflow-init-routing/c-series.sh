#!/bin/bash
# tests/feature-workflow-init-routing/c-series.sh
# Tests: skills/workflow-init/SKILL.md, skills/clarify-intent/SKILL.md, CLAUDE.md, .github/labels.yml
# Tags: workflow, init, routing, content-check, scope:common
#
# C-series: Content checks (C10-C13) for workflow-init / clarify-intent docs.

set -uo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

echo "=== C: Content checks ==="
echo ""

echo "--- C10: skills/workflow-init/SKILL.md ---"
assert_contains "$WORKFLOW_INIT_MD" "Path A" \
    "C10a: SKILL.md contains Path A (intent:clarified)"
assert_contains "$WORKFLOW_INIT_MD" "Path B" \
    "C10b: SKILL.md contains Path B (issue, no label)"
assert_contains "$WORKFLOW_INIT_MD" "Path C" \
    "C10c: SKILL.md contains Path C (no issue)"
assert_contains "$WORKFLOW_INIT_MD" "WORKFLOW_MARK_STEP_workflow_init_complete" \
    "C10d: SKILL.md Path A emits WORKFLOW_MARK_STEP_workflow_init_complete"
assert_contains "$WORKFLOW_INIT_MD" "WORKFLOW_CLARIFY_INTENT_NOT_NEEDED" \
    "C10e: SKILL.md Path A emits WORKFLOW_CLARIFY_INTENT_NOT_NEEDED"
assert_contains "$WORKFLOW_INIT_MD" "intent:clarified" \
    "C10f: SKILL.md references intent:clarified label"

echo ""
echo "--- C11: skills/clarify-intent/SKILL.md Completion section ---"
assert_contains "$CLARIFY_INTENT_MD" "gh issue create" \
    "C11a: clarify-intent Completion contains 'gh issue create'"
assert_contains "$CLARIFY_INTENT_MD" "gh issue edit.*--add-label|--add-label" \
    "C11b: clarify-intent Completion contains 'gh issue edit --add-label'"
assert_contains "$CLARIFY_INTENT_MD" "intent:clarified" \
    "C11c: clarify-intent Completion references 'intent:clarified'"
assert_contains "$CLARIFY_INTENT_MD" "workflow_init" \
    "C11d: clarify-intent TodoWrite checklist marks workflow_init as completed"

echo ""
echo "--- C12: CLAUDE.md and .github/labels.yml ---"
assert_contains "$AGENTS_CLAUDE_MD" "/workflow-init" \
    "C12a: CLAUDE.md Step 1 references /workflow-init"
assert_contains "$LABELS_YML" "intent:clarified" \
    "C12b: .github/labels.yml contains intent:clarified"

echo ""
echo "--- C13: workflow-init step 3 OPEN branch wip-state hookpoint (#362) ---"

# C13a: SKILL.md step 3 OPEN branch references wip-state.sh check across all ISSUES (per-N loop).
assert_contains "$WORKFLOW_INIT_MD" "Aggregate WIP check|wip-state\.sh.*check|for each issue N in \`ISSUES\`" \
    "C13a: workflow-init Step 3a references wip-state.sh check across all ISSUES (per-N loop)"

# C13b: failure-handling policy — when wip-state check fails (rc != 0), treat as 'none' and proceed.
assert_contains "$WORKFLOW_INIT_MD" "advisory|proceeding as|wip-state check failed|rc=" \
    "C13b: wip-state check failure-handling policy documented (advisory; proceed as none)"

# C13c: AskUserQuestion text identifies the conflict scenario + Continue/Abort options.
assert_contains "$WORKFLOW_INIT_MD" "in progress in another session|another session" \
    "C13c: AskUserQuestion text identifies the cross-session conflict scenario"
assert_contains "$WORKFLOW_INIT_MD" "Continue \(recommended\)|Continue.*recommended" \
    "C13c2: AskUserQuestion offers a 'Continue (recommended)' option"
assert_contains "$WORKFLOW_INIT_MD" "Abort" \
    "C13c3: AskUserQuestion offers an 'Abort' option"

# C13c4: AskUserQuestion enumerates the conflicted issue list (CONFLICTED variable).
assert_contains "$WORKFLOW_INIT_MD" "CONFLICTED|comma-separated" \
    "C13c4: workflow-init AskUserQuestion enumerates conflicted issue list (CONFLICTED variable)"

# C13d: resume-clarified gap — 'none' + 'intent:clarified' triggers per-N wip-state set.
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "C13d: workflow-init resume-clarified branch (file not found)"
elif grep -q "none" "$WORKFLOW_INIT_MD" \
   && grep -q "intent:clarified" "$WORKFLOW_INIT_MD" \
   && grep -qE "for each N in \`ISSUES\`.*wip-state.*set|wip-state.*set.*<N>|ISSUES.*wip-state.*set" "$WORKFLOW_INIT_MD"; then
    pass "C13d: workflow-init resume-clarified branch — wip-state set loops across all ISSUES"
else
    fail "C13d: resume-clarified branch text missing (need none + intent:clarified + per-N set loop)"
fi

# C13e: abort path emits WORKFLOW_ABORTED_WIP_CONFLICT sentinel.
assert_contains "$WORKFLOW_INIT_MD" "WORKFLOW_ABORTED_WIP_CONFLICT" \
    "C13e: 'abort' branch emits <<WORKFLOW_ABORTED_WIP_CONFLICT>> sentinel"

# C13f: Aggregate WIP classification (same/none/other) documented across ISSUES.
if grep -qE "all.*same|all.*none|Any.*other|any.*other|all.*WIP" "$WORKFLOW_INIT_MD"; then
    pass "C13f: aggregate WIP classification (same/none/other) documented across ISSUES"
else
    fail "C13f: aggregate WIP classification not documented (need same/none/other cases)"
fi

# C13g: Continue branch loops wip-state set across all ISSUES (not just CONFLICTED).
assert_contains "$WORKFLOW_INIT_MD" "for each N in \`ISSUES\`.*wip-state.*set|ISSUES.*Continue.*set|Continue.*ISSUES.*wip-state" \
    "C13g: Continue branch loops wip-state set across all ISSUES (not just CONFLICTED)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
