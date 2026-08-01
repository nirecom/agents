# shellcheck shell=bash
# Tests: hooks/workflow-state/effective-state.js, bin/workflow/next-step, hooks/workflow-state/evidence-resolver.js, bin/workflow/lib/next-step/
# Tags: workflow, next-step, docs, ordering, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G07: #1148 inconsistency-scan ordering. State has docs=pending while a LATER
# step (user_verification) is complete, and staged docs evidence exists. Pre-fix
# the inconsistency scan runs BEFORE docs evidence auto-complete, so it false-
# aborts ("later step complete but docs pending"). Post-fix a read-only effective
# -state snapshot resolves docs from evidence first, so no abort fires and docs
# is completed.
# fail-before-fix: pre-fix emits ACTION=abort and leaves docs pending.
# ===========================================================================

echo ""
echo "=== G07: #1148 — docs-pending + later-step-complete + evidence must NOT abort ==="

SID="g07-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete","outline":"complete","detail":"complete","branching_complete":"complete","write_tests":"complete","review_tests":"complete","run_tests":"complete","review_security":"complete","user_verification":"complete"}')"

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
mkdir -p "$REPO/docs"
echo "history content" > "$REPO/docs/history.md"
git -C "$REPO" add docs/history.md   # staged docs evidence

OUT=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID")

check_not_contains "G07a. no false abort verdict (#1148)" "abort" "$OUT"
check "G07b. docs resolved to complete via evidence before the scan" "complete" "$(read_state_status "$SID" docs)"
