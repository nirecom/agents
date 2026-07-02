# ===========================================================================
# === H1-H2: Scoped abort hint for outline=pending + detail=complete ===
# ===========================================================================

echo ""
echo "=== H1: outline=pending + detail=complete + no outline.md → abort + hint has --mark outline complete ==="

SID="h1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
# No outline.md → no evidence → auto-repair does not fire → inconsistency scan fires.

OUT=$(run_oracle --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check "H1. outline=pending + detail=complete (no evidence) → ACTION=abort" \
  "abort" "${ACTION:-}"
check_contains "H1b. scoped hint contains --mark outline complete" \
  "--mark outline complete" "${NEXT_HINT:-}"

echo ""
echo "=== H2: H1 hint does NOT contain /workflow-init ==="

OUT=$(run_oracle --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check_not_contains "H2. outline=pending + detail=complete scoped hint does NOT contain /workflow-init" \
  "/workflow-init" "${NEXT_HINT:-}"

# ===========================================================================
# === B1-B2: Generic hint bifurcation by hasCompletionEvidence ===
# ===========================================================================
# Uses REVIEW_SECURITY_COMPLETE_RUN_TESTS_PENDING fixture (non-outline/detail pair)
# to test hint bifurcation for run_tests.
#
# After #1215 fix: run_tests is sentinel-only; hasStagedTestChanges applies ONLY to
# write_tests. B1 verifies that staged tests/ present STILL yields run_tests
# evidence=false (the core #1215 regression). The staged-test setup is KEPT so B1
# records: "staged tests/ exist, yet run_tests evidence is false" — removing setup
# would reduce B1 to a no-repo state identical to B2, losing the regression value.
#   B1: staged test file → hasCompletionEvidence("run_tests")=false → /workflow-init hint (NOT --mark)
#   B2: no staged tests → hasCompletionEvidence("run_tests")=false → /workflow-init hint

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

OUT=$(CLAUDE_PROJECT_DIR="$REPO_B1_N" run_oracle --session "$SID")
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

OUT=$(CLAUDE_PROJECT_DIR="$REPO_B2_N" run_oracle --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check "B2. review_security=complete + run_tests=pending + no evidence → ACTION=abort" \
  "abort" "${ACTION:-}"
check_contains "B2b. hint without evidence → contains /workflow-init" \
  "/workflow-init" "${NEXT_HINT:-}"
check_not_contains "B2c. hint without evidence → does NOT contain --mark" \
  "--mark" "${NEXT_HINT:-}"
