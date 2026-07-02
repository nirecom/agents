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
check_contains "H1b. scoped hint contains --mark outline complete" \
  "--mark outline complete" "${NEXT_HINT:-}"

echo ""
echo "=== H2: H1 hint does NOT contain /workflow-init ==="

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check_not_contains "H2. outline=pending + detail=complete scoped hint does NOT contain /workflow-init" \
  "/workflow-init" "${NEXT_HINT:-}"

# ===========================================================================
# === B1-B2: Generic hint bifurcation by hasCompletionEvidence ===
# ===========================================================================
# Uses REVIEW_SECURITY_COMPLETE_RUN_TESTS_PENDING fixture (non-outline/detail pair)
# to test hint bifurcation via hasStagedTestChanges:
#   B1: staged test file → hasCompletionEvidence("run_tests")=true → --mark hint
#   B2: no staged tests → hasCompletionEvidence("run_tests")=false → /workflow-init hint

echo ""
echo "=== B1: non-scoped pair + hasCompletionEvidence=true → hint has --mark ==="

SID="b1-$$"
write_state "$SID" "$(REVIEW_SECURITY_COMPLETE_RUN_TESTS_PENDING $SID)"
REPO_B1=$(setup_repo)
# Stage a test file so hasStagedTestChanges() returns true for run_tests evidence.
mkdir -p "$REPO_B1/tests"
echo "# test" > "$REPO_B1/tests/dummy.sh"
git -C "$REPO_B1" add "tests/dummy.sh"
REPO_B1_N=$(to_node_path "$REPO_B1")

OUT=$(CLAUDE_PROJECT_DIR="$REPO_B1_N" run_next_step --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check "B1. review_security=complete + run_tests=pending + staged tests → ACTION=abort" \
  "abort" "${ACTION:-}"
check_contains "B1b. hint with evidence → contains --mark" \
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
