# Tests: bin/review-plan-codex
# Tags: codex, review, prompt-body, scope:issue-specific
# GROUP G: Prompt body content assertions (cases 29-32, G1).
# Asserts security axes, checklist references and the #2154 deferred/N-A
# wording against grep results on bin/review-plan-codex and its prompt modules — never against
# hardcoded duplicates. Sourced by tests/bin/feature-1308-codex-review-allowlist.sh.
echo ""
echo "=== Group G: Prompt body content (static source assertions) ==="

# #2814: the security-plan / test-review builders moved into this module, sourced by the entrypoint.
REVIEW_ONLY_SRC="$AGENTS_WORKTREE/bin/lib/review-plan-codex/prompts-review-only.sh"
PROMPT_LIB_DIR="$AGENTS_WORKTREE/bin/lib/review-plan-codex"

# Case 29-pre: the entrypoint really sources the module the prompt assertions read
{
  if grep -qF 'source "$SCRIPT_DIR/lib/review-plan-codex/prompts-review-only.sh"' "$CODEX_SRC" 2>/dev/null; then
    pass "29-pre: bin/review-plan-codex sources bin/lib/review-plan-codex/prompts-review-only.sh"
  else
    fail "29-pre: bin/review-plan-codex does not source bin/lib/review-plan-codex/prompts-review-only.sh"
  fi
}

# Case 29: security-plan prompt references OWASP ASVS V8 Data Protection
{
  if sed -n '/^rpc_prompt_security_plan()/,/^}/p' "$REVIEW_ONLY_SRC" 2>/dev/null | grep -q 'OWASP ASVS V8 Data Protection'; then
    pass "29: security-plan prompt (prompts-review-only.sh) references 'OWASP ASVS V8 Data Protection'"
  else
    fail "29: security-plan prompt (prompts-review-only.sh) missing 'OWASP ASVS V8 Data Protection'"
  fi
}

# Case 30: security-plan prompt references CWE-78 OS command injection
{
  if sed -n '/^rpc_prompt_security_plan()/,/^}/p' "$REVIEW_ONLY_SRC" 2>/dev/null | grep -q 'CWE-78 OS command injection'; then
    pass "30: security-plan prompt (prompts-review-only.sh) references 'CWE-78 OS command injection'"
  else
    fail "30: security-plan prompt (prompts-review-only.sh) missing 'CWE-78 OS command injection'"
  fi
}

# Case 31: test-review prompt references Test Case Categories checklist
{
  if sed -n '/^rpc_prompt_test_review()/,/^}/p' "$REVIEW_ONLY_SRC" 2>/dev/null | grep -q 'Test Case Categories checklist'; then
    pass "31: test-review prompt (prompts-review-only.sh) references 'Test Case Categories checklist'"
  else
    fail "31: test-review prompt (prompts-review-only.sh) missing 'Test Case Categories checklist'"
  fi
}

# Case 32: test-review prompt references test-design.md
{
  if sed -n '/^rpc_prompt_test_review()/,/^}/p' "$REVIEW_ONLY_SRC" 2>/dev/null | grep -q 'test-design.md'; then
    pass "32: test-review prompt (prompts-review-only.sh) references 'test-design.md'"
  else
    fail "32: test-review prompt (prompts-review-only.sh) missing 'test-design.md'"
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
# tests/bin/feature-2154-accepted-tradeoffs-fallback/layer-b-prompt.sh cases 8-9,
# which assert against the stdin bytes the mocked codex actually received.
{
  if grep -rqF -- "prioritize the plan's committed test scope over exhaustive checklist enumeration" "$CODEX_SRC" "$PROMPT_LIB_DIR" 2>/dev/null; then
    fail "G1: bin/review-plan-codex or bin/lib/review-plan-codex/ contains the WITHDRAWN broad wording 'prioritize the plan's committed test scope over exhaustive checklist enumeration'"
  else
    pass "G1: bin/review-plan-codex and bin/lib/review-plan-codex/ are free of the withdrawn broad suppression wording"
  fi
}
