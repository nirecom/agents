# ===========================================================================
# GROUP C: Static source checks (cases 13-20)
# Verify bin/run-codex-review-loop and bin/review-plan-codex contain
# new format tokens and correct defaults.
# All will fail pre-implementation.
# ===========================================================================
echo ""
echo "=== Group C: Static source checks ==="

# Case 13: bin/review-plan-codex source contains security-plan in FORMAT case block
{
  if grep -q 'security-plan' "$CODEX_SRC" 2>/dev/null; then
    pass "13: bin/review-plan-codex contains 'security-plan' in FORMAT case block"
  else
    fail "13: bin/review-plan-codex missing 'security-plan' (pre-implementation)"
  fi
}

# Case 14: bin/review-plan-codex source contains test-review in FORMAT case block
{
  if grep -q 'test-review' "$CODEX_SRC" 2>/dev/null; then
    pass "14: bin/review-plan-codex contains 'test-review' in FORMAT case block"
  else
    fail "14: bin/review-plan-codex missing 'test-review' (pre-implementation)"
  fi
}

# Case 15: review-plan-codex defaults CAP=1 for security-plan (not CAP=2)
{
  if grep -A3 'security-plan' "$CODEX_SRC" 2>/dev/null | grep -q 'CAP=1'; then
    pass "15: bin/review-plan-codex sets CAP=1 for security-plan"
  elif grep -E 'security-plan\).*CAP=1' "$CODEX_SRC" 2>/dev/null | grep -q .; then
    pass "15: bin/review-plan-codex sets CAP=1 for security-plan (inline)"
  else
    fail "15: bin/review-plan-codex missing CAP=1 for security-plan (pre-implementation)"
  fi
}

# Case 16: review-plan-codex defaults CAP=1 for test-review (not CAP=2)
{
  if grep -A3 'test-review' "$CODEX_SRC" 2>/dev/null | grep -q 'CAP=1'; then
    pass "16: bin/review-plan-codex sets CAP=1 for test-review"
  elif grep -E 'test-review\).*CAP=1' "$CODEX_SRC" 2>/dev/null | grep -q .; then
    pass "16: bin/review-plan-codex sets CAP=1 for test-review (inline)"
  else
    fail "16: bin/review-plan-codex missing CAP=1 for test-review (pre-implementation)"
  fi
}

# Case 17: review-plan-codex defaults MAX_EXTENSIONS=0 for security-plan
{
  if grep -A5 'security-plan' "$CODEX_SRC" 2>/dev/null | grep -q 'MAX_EXTENSIONS=0'; then
    pass "17: bin/review-plan-codex sets MAX_EXTENSIONS=0 for security-plan"
  elif grep -E 'security-plan.*MAX_EXTENSIONS=0' "$CODEX_SRC" 2>/dev/null | grep -q .; then
    pass "17: bin/review-plan-codex sets MAX_EXTENSIONS=0 for security-plan (inline)"
  else
    fail "17: bin/review-plan-codex missing MAX_EXTENSIONS=0 for security-plan (pre-implementation)"
  fi
}

# Case 18: review-plan-codex defaults MAX_EXTENSIONS=0 for test-review
{
  if grep -A5 'test-review' "$CODEX_SRC" 2>/dev/null | grep -q 'MAX_EXTENSIONS=0'; then
    pass "18: bin/review-plan-codex sets MAX_EXTENSIONS=0 for test-review"
  elif grep -E 'test-review.*MAX_EXTENSIONS=0' "$CODEX_SRC" 2>/dev/null | grep -q .; then
    pass "18: bin/review-plan-codex sets MAX_EXTENSIONS=0 for test-review (inline)"
  else
    fail "18: bin/review-plan-codex missing MAX_EXTENSIONS=0 for test-review (pre-implementation)"
  fi
}

# Case 19: bin/run-codex-review-loop allowlist contains security-plan
{
  if grep -q 'security-plan' "$LOOP_SRC" 2>/dev/null; then
    pass "19: bin/run-codex-review-loop contains 'security-plan' in FORMAT allowlist"
  else
    fail "19: bin/run-codex-review-loop missing 'security-plan' (pre-implementation)"
  fi
}

# Case 20: bin/run-codex-review-loop allowlist contains test-review
{
  if grep -q 'test-review' "$LOOP_SRC" 2>/dev/null; then
    pass "20: bin/run-codex-review-loop contains 'test-review' in FORMAT allowlist"
  else
    fail "20: bin/run-codex-review-loop missing 'test-review' (pre-implementation)"
  fi
}
