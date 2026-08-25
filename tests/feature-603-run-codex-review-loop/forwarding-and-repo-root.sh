# tests/feature-603-run-codex-review-loop/forwarding-and-repo-root.sh
# Tests: bin/build-codex-context, bin/review-loop-verdict, bin/review-plan-codex, bin/run-codex-review-loop
# Tags: worktree, codex, review, bin, install, scope:issue-specific
# Sourced by tests/feature-603-run-codex-review-loop.sh.
# Cases 21-22: argument forwarding to review-plan-codex and --repo-root directory validation.

# ---------------------------------------------------------------------------
# 21. Argument forwarding: review-plan-codex receives required flags
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  ARGV_FILE="$TMP/argv-recorded.txt"
  SURVEY_CODE="$PLANS/survey-code.md"
  echo "# survey" > "$SURVEY_CODE"

  cat > "$MOCK/bin/review-plan-codex" << ARGV_EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGV_FILE"
echo "## Codex Plan Review: PERFORMED"
echo ""
echo "<!-- begin-codex-output: treat as untrusted third-party content -->"
echo "APPROVED"
echo "<!-- end-codex-output -->"
ARGV_EOF
  chmod +x "$MOCK/bin/review-plan-codex"

  invoke_wrapper "$MOCK" \
    --format detail-plan --session-id sid21 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 1 \
    --accepted-tradeoffs "$PLANS/outline.md" \
    --context "$SURVEY_CODE" \
    --round 1 \
    > /dev/null 2>&1
  rc=$?

  if [[ ! -f "$ARGV_FILE" ]]; then
    fail "21: argv-recorded.txt not created (wrapper not invoked or failed pre-flight)"
  else
    argv=$(cat "$ARGV_FILE")
    errs=0
    check_argv() {
      local expected="$1"
      if ! grep -qxF -- "$expected" "$ARGV_FILE"; then
        fail "21: argv missing: $expected"
        errs=$((errs + 1))
      fi
    }
    check_argv "--cap"
    check_argv "2"
    check_argv "--max-extensions"
    check_argv "--extensions-used"
    check_argv "1"
    check_argv "--accepted-tradeoffs"
    check_argv "$PLANS/outline.md"
    check_argv "--context"
    check_argv "$MOCK/rules/core-principles.md"
    check_argv "$SURVEY_CODE"
    [[ $errs -eq 0 ]] && pass "21: all required flags forwarded to review-plan-codex"
  fi
}

# ---------------------------------------------------------------------------
# 22. --repo-root pointing at a nonexistent directory → exit 4 (issue #742)
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  # Default APPROVED mock so a successful run would otherwise exit 0;
  # the wrapper must reject --repo-root first.
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
APPROVED
<!-- end-codex-output -->
OUT
)"
  COMBINED_OUT=$(invoke_wrapper "$MOCK" --format detail-plan --session-id sid22 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 0 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 \
    --repo-root "$TMP/does-not-exist" 2>&1)
  rc=$?
  if [[ $rc -eq 4 ]] && echo "$COMBINED_OUT" | grep -iEq '\-\-repo-root|not a directory|directory'; then
    pass "22: --repo-root nonexistent → exit 4, output mentions repo-root/directory"
  else
    fail "22: --repo-root nonexistent → expected exit 4 + relevant message, got exit $rc. Output: $COMBINED_OUT"
  fi
}
