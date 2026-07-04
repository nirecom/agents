# ===========================================================================
# GROUP F: Security — input injection (case 28)
# test-design.md §Security Cases — Input Injection / CWE-78 OS Command Injection.
# A malicious --format value embeds a shell command. The FORMAT allowlist is a
# bash `case` statement, which does NOT eval its subject, so the injected
# command must never run: the value falls through to the `*)` die branch (exit 4).
# Expected to PASS pre-implementation — this guards the allowlist safety property.
# ===========================================================================
echo ""
echo "=== Group F: Security — input injection ==="

# Case 28: shell metacharacters in --format → exit 4 AND injected command NOT executed
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  CANARY="$TMP/injected-canary"   # deliberately NOT created
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
APPROVED
<!-- end-codex-output -->
OUT
)"
  invoke_wrapper "$MOCK" --format "security-plan; touch $CANARY" --session-id sid28 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 1 --max-extensions 0 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 > /dev/null 2>&1
  rc=$?
  if [[ $rc -eq 4 && ! -e "$CANARY" ]]; then
    pass "28: injected --format rejected → exit 4 and canary not created (CWE-78 safe)"
  else
    canary_state="absent"; [[ -e "$CANARY" ]] && canary_state="PRESENT (command executed!)"
    fail "28: injection guard failed → expected exit 4 + no canary, got exit $rc, canary $canary_state"
  fi
}
