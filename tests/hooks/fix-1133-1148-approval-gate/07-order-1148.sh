# shellcheck shell=bash
# Tests: hooks/workflow-state/effective-state.js, bin/workflow/next-step, hooks/workflow-state/evidence-resolver.js, bin/workflow/lib/next-step/
# Tags: workflow, next-step, docs, ordering, scope:common
# (Sourced fragment of tests/hooks/fix-1133-1148-approval-gate.sh — not run standalone.)

# G07: #1148 inconsistency-scan ordering. docs=pending while a LATER step is complete and
# staged docs evidence exists: the effective-state snapshot must resolve docs from evidence
# before the inconsistency scan, so no false abort fires.

echo ""
echo "=== G07: #1148 — docs-pending + later-step-complete + evidence must NOT abort ==="

SID="g07-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete","outline":"complete","detail":"complete","branching_complete":"complete","write_tests":"complete","review_tests":"complete","write_code":"complete","run_tests":"complete","review_security":"complete","user_verification":"complete"}')"
# #2277 S13: an unapproved outline/detail complete reads pending, so approve both (G07 is about docs).
run_with_timeout node "$PLAN_APPROVAL_FIXTURE" inject-complete "$(to_node_path "$WORKFLOW_DIR/${SID}.json")" outline detail >/dev/null ||
  echo "FAIL: G07 setup: could not inject outline/detail approvals"

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
mkdir -p "$REPO/docs"
echo "history content" > "$REPO/docs/history.md"
git -C "$REPO" add docs/history.md   # staged docs evidence

OUT=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID")

check_not_contains "G07a. no false abort verdict (#1148)" "abort" "$OUT"
check "G07b. docs resolved to complete via evidence before the scan" "complete" "$(read_state_status "$SID" docs)"
