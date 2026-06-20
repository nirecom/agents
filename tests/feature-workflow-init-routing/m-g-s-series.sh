#!/bin/bash
# tests/feature-workflow-init-routing/m-g-s-series.sh
# Tests: hooks/lib/workflow-state.js, hooks/workflow-gate.js, hooks/workflow-mark.js
# Tags: workflow, gate, hook, init, routing, scope:common
#
# M-series: state migration of workflow_init key (M1-M4)
# G-series: early gate behavior (G5-G8)
# S-series: workflow-mark sentinel (S9)

set -uo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ============================================================
echo "=== M: Migration tests ==="
echo ""

# M1: ci absent → workflow_init backfilled as complete (no ci key = very old session)
SID="mig-ci-absent"
write_state "$SID" "$(state_ci_absent "$SID")"
actual=$(read_wi_status "$SID")
[ "$actual" = "complete" ] && pass "M1: ci_absent → workflow_init:complete" \
    || fail "M1: ci_absent → workflow_init:complete (got: $actual)"

# M2: ci complete → workflow_init backfilled as complete
SID="mig-ci-complete"
write_state "$SID" "$(state_ci_complete "$SID")"
actual=$(read_wi_status "$SID")
[ "$actual" = "complete" ] && pass "M2: ci_complete → workflow_init:complete" \
    || fail "M2: ci_complete → workflow_init:complete (got: $actual)"

# M3: ci skipped → workflow_init backfilled as complete
SID="mig-ci-skipped"
write_state "$SID" "$(state_ci_skipped "$SID")"
actual=$(read_wi_status "$SID")
[ "$actual" = "complete" ] && pass "M3: ci_skipped → workflow_init:complete" \
    || fail "M3: ci_skipped → workflow_init:complete (got: $actual)"

# M4: ci pending (in-flight session at upgrade time) → workflow_init backfilled as pending
SID="mig-ci-pending"
write_state "$SID" "$(state_ci_pending "$SID")"
actual=$(read_wi_status "$SID")
[ "$actual" = "pending" ] && pass "M4: ci_pending → workflow_init:pending" \
    || fail "M4: ci_pending → workflow_init:pending (got: $actual)"

# ============================================================
echo ""
echo "=== G: Early gate tests ==="
echo ""

# G5: Tier 1 — workflow_init:pending → Edit blocked; message references workflow-init
SID="gate-tier1"
write_state "$SID" "$(state_wi_ci "$SID" "pending" "pending")"
assert_decision   "G5a: workflow_init:pending → Edit blocked"             "$(input_edit "$SID" "/c/git/proj/src/foo.js")" "block"
assert_message_contains "G5b: Tier 1 block message references workflow-init" "$(input_edit "$SID" "/c/git/proj/src/foo.js")" "workflow-init"

# G6: Tier 2 — workflow_init:complete + clarify_intent:pending → Edit blocked; message references clarify-intent
#     AND does NOT reference workflow-init (Tier 1 already cleared)
SID="gate-tier2"
write_state "$SID" "$(state_wi_ci "$SID" "complete" "pending")"
assert_decision   "G6a: clarify_intent:pending → Edit still blocked"      "$(input_edit "$SID" "/c/git/proj/src/foo.js")" "block"
assert_message_contains "G6b: Tier 2 block message references clarify-intent" "$(input_edit "$SID" "/c/git/proj/src/foo.js")" "clarify-intent"
assert_message_absent   "G6c: Tier 2 block does NOT mention workflow_init gate" "$(input_edit "$SID" "/c/git/proj/src/foo.js")" "workflow_init has not been completed"

# G7: Both complete → Edit approved (gate dormant)
SID="gate-dormant"
write_state "$SID" "$(state_wi_ci "$SID" "complete" "complete")"
assert_decision "G7: workflow_init:complete + clarify_intent:complete → Edit approved" \
    "$(input_edit "$SID" "/c/git/proj/src/foo.js")" "approve"

# G8: workflow_init:pending + Write to ~/.workflow-plans/ → approved (plans-path allowlist)
SID="gate-plans-allowlist"
write_state "$SID" "$(state_wi_ci "$SID" "pending" "pending")"
assert_decision "G8: workflow_init:pending + Write to plans dir → approved (allowlist)" \
    "$(input_write "$SID" "$PLANS_DIR_NATIVE/${SID}-intent.md")" "approve"

# ============================================================
echo ""
echo "=== S: Sentinel test ==="
echo ""

# S9: <<WORKFLOW_MARK_STEP_workflow_init_complete>> accepted by workflow-mark.js
SID="mark-wi-complete"
write_state "$SID" "$(state_wi_ci "$SID" "pending" "pending")"
MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"' "$SID")
MARK_OUTPUT=$(echo "$MARK_JSON" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)

actual_after=$( (cd "$AGENTS_DIR" && node -e "
const { readState } = require('./hooks/lib/workflow-state.js');
const s = readState('$SID');
const wi = s && s.steps && s.steps.workflow_init;
process.stdout.write(wi ? wi.status : 'MISSING');
" 2>/dev/null) || echo "ERROR")

if [ "$actual_after" = "complete" ]; then
    pass "S9: MARK_STEP_workflow_init_complete accepted and recorded"
elif printf '%s' "$MARK_OUTPUT" | grep -q "NOT recorded"; then
    fail "S9: MARK_STEP_workflow_init_complete rejected by workflow-mark.js (output: $MARK_OUTPUT)"
else
    fail "S9: MARK_STEP_workflow_init_complete — state not updated (got: $actual_after)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
