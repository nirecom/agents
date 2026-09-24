# ===========================================================================
# GROUP E: Agent file existence (cases 26-27)
# ===========================================================================
echo ""
echo "=== Group E: Agent files ==="

# Case 26: agents/plan-security-reviewer.md exists and is non-empty
{
  if [[ -s "$PLAN_SEC_AGENT" ]]; then
    pass "26: agents/plan-security-reviewer.md exists and is non-empty"
  elif [[ -f "$PLAN_SEC_AGENT" ]]; then
    fail "26: agents/plan-security-reviewer.md exists but is empty"
  else
    fail "26: agents/plan-security-reviewer.md not found (pre-implementation)"
  fi
}

# Case 27: agents/test-reviewer.md exists and is non-empty
{
  if [[ -s "$TEST_REVIEWER_AGENT" ]]; then
    pass "27: agents/test-reviewer.md exists and is non-empty"
  elif [[ -f "$TEST_REVIEWER_AGENT" ]]; then
    fail "27: agents/test-reviewer.md exists but is empty"
  else
    fail "27: agents/test-reviewer.md not found (pre-implementation)"
  fi
}
