# ===========================================================================
# GROUP G: Prompt body content assertions (cases 29-32)
# Verifies that the security-plan and test-review case blocks in
# bin/review-plan-codex contain the expected security axes and checklist
# references. Asserts against actual grep results on the source file —
# not against hardcoded duplicates.
# ===========================================================================
echo ""
echo "=== Group G: Prompt body content (static source assertions) ==="

# Case 29: security-plan prompt references OWASP ASVS V8 Data Protection
{
  if grep -q 'OWASP ASVS V8 Data Protection' "$CODEX_SRC" 2>/dev/null; then
    pass "29: bin/review-plan-codex security-plan prompt references 'OWASP ASVS V8 Data Protection'"
  else
    fail "29: bin/review-plan-codex missing 'OWASP ASVS V8 Data Protection' in security-plan prompt"
  fi
}

# Case 30: security-plan prompt references CWE-78 OS command injection
{
  if grep -q 'CWE-78 OS command injection' "$CODEX_SRC" 2>/dev/null; then
    pass "30: bin/review-plan-codex security-plan prompt references 'CWE-78 OS command injection'"
  else
    fail "30: bin/review-plan-codex missing 'CWE-78 OS command injection' in security-plan prompt"
  fi
}

# Case 31: test-review prompt references Test Case Categories checklist
{
  if grep -q 'Test Case Categories checklist' "$CODEX_SRC" 2>/dev/null; then
    pass "31: bin/review-plan-codex test-review prompt references 'Test Case Categories checklist'"
  else
    fail "31: bin/review-plan-codex missing 'Test Case Categories checklist' in test-review prompt"
  fi
}

# Case 32: test-review prompt references test-design.md
{
  if grep -q 'test-design.md' "$CODEX_SRC" 2>/dev/null; then
    pass "32: bin/review-plan-codex test-review prompt references 'test-design.md'"
  else
    fail "32: bin/review-plan-codex missing 'test-design.md' in test-review prompt"
  fi
}
