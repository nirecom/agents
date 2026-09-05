# Tests: bin/review-plan-codex
# Tags: codex, review, prompt-body, scope:issue-specific
# GROUP G: Prompt body content assertions (cases 29-32, G1).
# Asserts security axes, checklist references and the #2154 deferred/N-A
# wording against grep results on bin/review-plan-codex — never against
# hardcoded duplicates. Sourced by tests/feature-1308-codex-review-allowlist.sh.
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

# Case G1 (#2154): NEGATIVE only. The withdrawn broad wording — which would
# suppress any category the plan merely fails to mention — must not exist
# anywhere in the source, in any format's prompt. A source-wide grep is the
# right shape for an absence claim.
# The matching POSITIVE claim (the narrow deferred/N-A wording actually reaching
# the test-review prompt, and NOT reaching the other formats) is deliberately
# NOT asserted here: a grep-anywhere match cannot tell the test-review
# CONTEXT_BLOCK from an unrelated branch. It lives at TL2 instead, in
# tests/feature-2154-accepted-tradeoffs-fallback/layer-b-prompt.sh cases 8-9,
# which assert against the stdin bytes the mocked codex actually received.
{
  if grep -qF -- "prioritize the plan's committed test scope over exhaustive checklist enumeration" "$CODEX_SRC" 2>/dev/null; then
    fail "G1: bin/review-plan-codex contains the WITHDRAWN broad wording 'prioritize the plan's committed test scope over exhaustive checklist enumeration'"
  else
    pass "G1: bin/review-plan-codex is free of the withdrawn broad suppression wording"
  fi
}
