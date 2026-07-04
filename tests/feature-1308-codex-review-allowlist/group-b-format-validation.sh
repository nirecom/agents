# ===========================================================================
# GROUP B: review-plan-codex FORMAT validation (cases 10-12)
# Invokes the REAL review-plan-codex to check its format guard.
# Cases 10-11 will fail pre-implementation (new formats not accepted yet).
# Case 12 is a regression: bad-format must still be rejected.
# ===========================================================================
echo ""
echo "=== Group B: review-plan-codex format validation ==="

# Case 10: review-plan-codex security-plan → no "invalid --format" in output
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  PLANS=$(setup_plans_dir "$TMP")
  if [[ ! -f "$REAL_REVIEW_PLAN_CODEX" ]]; then
    fail "10: review-plan-codex not found (pre-implementation skip)"
  else
    OUT=$(invoke_real_review_plan_codex "security-plan" "sid10" "$PLANS" "$PLANS/draft.md")
    if echo "$OUT" | grep -q "invalid --format"; then
      fail "10: review-plan-codex security-plan → got 'invalid --format' (format not yet accepted)"
    else
      pass "10: review-plan-codex security-plan → no 'invalid --format' in output"
    fi
  fi
}

# Case 11: review-plan-codex test-review → no "invalid --format" in output
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  PLANS=$(setup_plans_dir "$TMP")
  if [[ ! -f "$REAL_REVIEW_PLAN_CODEX" ]]; then
    fail "11: review-plan-codex not found (pre-implementation skip)"
  else
    OUT=$(invoke_real_review_plan_codex "test-review" "sid11" "$PLANS" "$PLANS/draft.md")
    if echo "$OUT" | grep -q "invalid --format"; then
      fail "11: review-plan-codex test-review → got 'invalid --format' (format not yet accepted)"
    else
      pass "11: review-plan-codex test-review → no 'invalid --format' in output"
    fi
  fi
}

# Case 12: review-plan-codex bad-format → "invalid --format" present (regression)
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  PLANS=$(setup_plans_dir "$TMP")
  if [[ ! -f "$REAL_REVIEW_PLAN_CODEX" ]]; then
    fail "12: review-plan-codex not found (pre-implementation skip)"
  else
    OUT=$(invoke_real_review_plan_codex "bad-format" "sid12" "$PLANS" "$PLANS/draft.md")
    if echo "$OUT" | grep -q "invalid --format"; then
      pass "12: review-plan-codex bad-format → 'invalid --format' present (regression OK)"
    else
      fail "12: review-plan-codex bad-format → expected 'invalid --format' but not found. Output: $OUT"
    fi
  fi
}
