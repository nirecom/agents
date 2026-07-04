# ===========================================================================
# GROUP D: Wrapper script structural checks (cases 21-25)
# ===========================================================================
echo ""
echo "=== Group D: Wrapper scripts ==="

# Case 21: wrapper for review-plan-security exists and is executable
{
  if [[ -x "$RPS_WRAPPER" ]]; then
    pass "21: skills/review-plan-security/scripts/run-codex-review-loop.sh exists and is executable"
  elif [[ -f "$RPS_WRAPPER" ]]; then
    fail "21: skills/review-plan-security/scripts/run-codex-review-loop.sh exists but not executable"
  else
    fail "21: skills/review-plan-security/scripts/run-codex-review-loop.sh not found (pre-implementation)"
  fi
}

# Case 22: wrapper for review-tests exists and is executable
{
  if [[ -x "$RT_WRAPPER" ]]; then
    pass "22: skills/review-tests/scripts/run-codex-review-loop.sh exists and is executable"
  elif [[ -f "$RT_WRAPPER" ]]; then
    fail "22: skills/review-tests/scripts/run-codex-review-loop.sh exists but not executable"
  else
    fail "22: skills/review-tests/scripts/run-codex-review-loop.sh not found (pre-implementation)"
  fi
}

# Case 23: review-plan-security wrapper passes --format security-plan
{
  if [[ ! -f "$RPS_WRAPPER" ]]; then
    fail "23: review-plan-security wrapper not found — cannot check --format security-plan (pre-implementation)"
  elif grep -q '\-\-format security-plan' "$RPS_WRAPPER"; then
    pass "23: review-plan-security wrapper passes --format security-plan"
  else
    fail "23: review-plan-security wrapper missing '--format security-plan'"
  fi
}

# Case 24: review-tests wrapper passes --format test-review
{
  if [[ ! -f "$RT_WRAPPER" ]]; then
    fail "24: review-tests wrapper not found — cannot check --format test-review (pre-implementation)"
  elif grep -q '\-\-format test-review' "$RT_WRAPPER"; then
    pass "24: review-tests wrapper passes --format test-review"
  else
    fail "24: review-tests wrapper missing '--format test-review'"
  fi
}

# Case 25: review-tests wrapper passes --context with path containing test-design.md
{
  if [[ ! -f "$RT_WRAPPER" ]]; then
    fail "25: review-tests wrapper not found — cannot check --context test-design.md (pre-implementation)"
  elif grep -q 'test-design.md' "$RT_WRAPPER"; then
    pass "25: review-tests wrapper passes --context referencing test-design.md"
  else
    fail "25: review-tests wrapper missing --context referencing test-design.md"
  fi
}

# Case D1: review-plan-security wrapper cleanup_counter clears on exit 1 (0|1|2|4 pattern)
{
  if [[ ! -f "$RPS_WRAPPER" ]]; then
    fail "D1: review-plan-security wrapper not found — cannot check cleanup_counter exit-1 handling"
  elif grep -q '0|1|2|4)' "$RPS_WRAPPER"; then
    pass "D1: review-plan-security wrapper cleanup_counter includes exit 1 in clear-arm (0|1|2|4)"
  else
    fail "D1: review-plan-security wrapper cleanup_counter missing exit 1 in clear-arm (expected 0|1|2|4, got old 0|2|4 or missing)"
  fi
}

# Case D2: review-tests wrapper cleanup_counter clears on exit 1 (0|1|2|4 pattern)
{
  if [[ ! -f "$RT_WRAPPER" ]]; then
    fail "D2: review-tests wrapper not found — cannot check cleanup_counter exit-1 handling"
  elif grep -q '0|1|2|4)' "$RT_WRAPPER"; then
    pass "D2: review-tests wrapper cleanup_counter includes exit 1 in clear-arm (0|1|2|4)"
  else
    fail "D2: review-tests wrapper cleanup_counter missing exit 1 in clear-arm (expected 0|1|2|4, got old 0|2|4 or missing)"
  fi
}
