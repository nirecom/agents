# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/
# Tags: workflow, next-step, mark, hint, scope:issue-specific
# ===========================================================================
# === H1-H2: Scoped abort hint for outline=pending + detail=complete ===
# ===========================================================================

echo ""
echo "=== H1: outline=pending + detail=complete + no outline.md → abort + hint has --mark outline complete ==="

SID="h1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
# No outline.md → no evidence → auto-repair does not fire → inconsistency scan fires.

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check "H1. outline=pending + detail=complete (no evidence) → ACTION=abort" \
  "abort" "${ACTION:-}"
# Post-#1133 the recovery for a gated step is a recorded approval, not --mark:
# the hint must steer to the CONFIRM sentinel and must NOT advertise --mark as a
# back-door around the approval gate.
check_contains "H1b. scoped hint steers to the CONFIRM_OUTLINE approval sentinel" \
  "WORKFLOW_CONFIRM_OUTLINE" "${NEXT_HINT:-}"
# The hint no longer emits a trailing `complete` token, so the needle is
# shortened to `--mark outline` — the old full-phrase needle would have become
# structurally unmatchable and let this guard go vacuously green.
check_not_contains "H1c. scoped hint does NOT offer --mark outline as recovery" \
  "--mark outline" "${NEXT_HINT:-}"

echo ""
echo "=== H2: H1 hint does NOT contain /workflow-init ==="

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check_not_contains "H2. outline=pending + detail=complete scoped hint does NOT contain /workflow-init" \
  "/workflow-init" "${NEXT_HINT:-}"

# === B1-B2: hint bifurcation by hasCompletionEvidence (REVIEW_SECURITY_COMPLETE_RUN_TESTS_PENDING fixture) ===
# run_tests is sentinel-only: hasStagedTestChanges applies only to write_tests, so
# staged tests/ must still NOT count as run_tests evidence. B1 keeps a staged test
# file to prove that non-effect; B2 (no staged tests) is the control.
#   B1: staged test file → hasCompletionEvidence("run_tests")=false → /workflow-init hint (NOT --mark)
#   B2: no staged tests  → hasCompletionEvidence("run_tests")=false → /workflow-init hint

echo ""
echo "=== B1: non-scoped pair + staged tests + run_tests evidence=false → hint has /workflow-init not --mark ==="

SID="b1-$$"
write_state "$SID" "$(REVIEW_SECURITY_COMPLETE_RUN_TESTS_PENDING $SID)"
REPO_B1=$(setup_repo)
# Stage a test file. After #1215 fix, hasStagedTestChanges no longer drives
# run_tests evidence; run_tests is sentinel-only. This setup is kept intentionally
# to confirm that staged tests/ do NOT produce run_tests evidence=true.
mkdir -p "$REPO_B1/tests"
echo "# test" > "$REPO_B1/tests/dummy.sh"
git -C "$REPO_B1" add "tests/dummy.sh"
REPO_B1_N=$(to_node_path "$REPO_B1")

OUT=$(CLAUDE_PROJECT_DIR="$REPO_B1_N" run_next_step --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check "B1. review_security=complete + run_tests=pending + staged tests → ACTION=abort" \
  "abort" "${ACTION:-}"
check_contains "B1b. staged tests present BUT run_tests evidence=false → hint contains /workflow-init" \
  "/workflow-init" "${NEXT_HINT:-}"
check_not_contains "B1c. staged tests present BUT run_tests evidence=false → hint does NOT contain --mark" \
  "--mark" "${NEXT_HINT:-}"

echo ""
echo "=== B2: non-scoped pair + hasCompletionEvidence=false → hint has /workflow-init not --mark ==="

SID="b2-$$"
write_state "$SID" "$(REVIEW_SECURITY_COMPLETE_RUN_TESTS_PENDING $SID)"
REPO_B2=$(setup_repo)
# No staged test files → hasStagedTestChanges() = false.
REPO_B2_N=$(to_node_path "$REPO_B2")

OUT=$(CLAUDE_PROJECT_DIR="$REPO_B2_N" run_next_step --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check "B2. review_security=complete + run_tests=pending + no evidence → ACTION=abort" \
  "abort" "${ACTION:-}"
check_contains "B2b. hint without evidence → contains /workflow-init" \
  "/workflow-init" "${NEXT_HINT:-}"
check_not_contains "B2c. hint without evidence → does NOT contain --mark" \
  "--mark" "${NEXT_HINT:-}"
