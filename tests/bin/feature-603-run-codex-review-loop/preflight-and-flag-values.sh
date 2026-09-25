# tests/feature-603-run-codex-review-loop/preflight-and-flag-values.sh
# Tests: bin/build-codex-context, bin/review-loop-verdict, bin/review-plan-codex, bin/run-codex-review-loop
# Tags: worktree, codex, review, bin, install, scope:issue-specific
# Sourced by tests/feature-603-run-codex-review-loop.sh.
# Cases 16-20: pre-flight checks (AGENTS_CONFIG_DIR, review-plan-codex, core-principles.md) and flags given without a value.

# ---------------------------------------------------------------------------
# 16. AGENTS_CONFIG_DIR unset → exit 4, stderr mentions AGENTS_CONFIG_DIR
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  WRAPPER="$MOCK/bin/run-codex-review-loop"
  if [[ ! -f "$WRAPPER" ]]; then
    fail "16: run-codex-review-loop not found (pre-implementation skip)"
  else
    STDERR_OUT=$(unset AGENTS_CONFIG_DIR; run_with_timeout "$WRAPPER" \
      --format detail-plan --session-id sid16 --plans-dir "$PLANS" \
      --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
      --accepted-tradeoffs "$PLANS/outline.md" --round 1 2>&1 > /dev/null)
    rc=$?
    if [[ $rc -eq 4 ]] && echo "$STDERR_OUT" | grep -q 'AGENTS_CONFIG_DIR'; then
      pass "16: AGENTS_CONFIG_DIR unset → exit 4, stderr mentions AGENTS_CONFIG_DIR"
    else
      fail "16: AGENTS_CONFIG_DIR unset → expected exit 4 + stderr mention, got exit $rc"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 17. AGENTS_CONFIG_DIR set but review-plan-codex missing → exit 4
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  rm -f "$MOCK/bin/review-plan-codex"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid17 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 4 ]] && pass "17: review-plan-codex missing → exit 4" || fail "17: review-plan-codex missing → expected exit 4, got $rc"
}

# ---------------------------------------------------------------------------
# 18. core-principles.md missing → exit 4, stderr mentions required context
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  rm -f "$MOCK/rules/core-principles.md"
  STDERR_OUT=$(invoke_wrapper "$MOCK" --format detail-plan --session-id sid18 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 2>&1 > /dev/null)
  rc=$?
  if [[ $rc -eq 4 ]] && echo "$STDERR_OUT" | grep -q 'required context missing\|core-principles'; then
    pass "18: core-principles.md missing → exit 4, stderr mentions required context"
  else
    fail "18: core-principles.md missing → expected exit 4 + stderr, got exit $rc"
  fi
}

# ---------------------------------------------------------------------------
# 19. Missing value for --cap (--cap --max-extensions 2) → exit 4
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  STDERR_OUT=$(invoke_wrapper "$MOCK" --format detail-plan --session-id sid19 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" 2>&1 > /dev/null)
  rc=$?
  if [[ $rc -eq 4 ]] && echo "$STDERR_OUT" | grep -q '\-\-cap'; then
    pass "19: --cap missing value → exit 4, stderr mentions --cap"
  else
    fail "19: --cap missing value → expected exit 4 + stderr mention of --cap, got exit $rc"
  fi
}

# ---------------------------------------------------------------------------
# 20. Trailing flag with no value (last arg is --accepted-tradeoffs) → exit 4
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  STDERR_OUT=$(invoke_wrapper "$MOCK" --format detail-plan --session-id sid20 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs 2>&1 > /dev/null)
  rc=$?
  if [[ $rc -eq 4 ]] && echo "$STDERR_OUT" | grep -q '\-\-accepted-tradeoffs\|requires a value'; then
    pass "20: trailing --accepted-tradeoffs with no value → exit 4"
  else
    fail "20: trailing --accepted-tradeoffs no value → expected exit 4 + stderr, got exit $rc"
  fi
}
