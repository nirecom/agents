# tests/feature-603-run-codex-review-loop/cap-and-extension-branches.sh
# Tests: bin/build-codex-context, bin/review-loop-verdict, bin/review-plan-codex, bin/run-codex-review-loop
# Tags: worktree, codex, review, bin, install, scope:issue-specific
# Sourced by tests/feature-603-run-codex-review-loop.sh.
# Cases 23-25: CONTINUE-branch cap reach, the extension budget ceiling, and the under-limit path.

# ---------------------------------------------------------------------------
# 23. CONTINUE branch cap-reach with extension available → exit 2. See #2068 for why --force-round replaces audit-log seeding.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  printf 'C1|HIGH|OPEN|1|needs async approach\n' > "$PLANS/sid23-outline-plan-concern-ledger.txt"
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
MISSING_ALTERNATIVE: needs async approach
C1: still open — needs async approach
<!-- end-codex-output -->
OUT
)"
  invoke_wrapper "$MOCK" --format outline-plan --session-id sid23 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 1 --max-extensions 1 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --force-round 2 > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 5 ]] && pass "23: HIGH at cap with budget remaining → AUTO_EXTEND (exit 5)" || fail "23: CONTINUE+cap-reach → expected exit 5, got $rc"
}

# ---------------------------------------------------------------------------
# 24. CONTINUE branch cap-reach at absolute ceiling → exit 2
#     outline-plan, CAP=1, EXT_USED=1, MAX_EXT=1 → limit=3, and the round is 3.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  printf 'C1|HIGH|OPEN|1|still need async approach\n' > "$PLANS/sid24-outline-plan-concern-ledger.txt"
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
MISSING_ALTERNATIVE: still need async approach
C1: still open — still need async approach
<!-- end-codex-output -->
OUT
)"
  invoke_wrapper "$MOCK" --format outline-plan --session-id sid24 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 1 --max-extensions 1 --extensions-used 1 \
    --accepted-tradeoffs "$PLANS/outline.md" --force-round 3 > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 6 ]] && pass "24: HIGH at ceiling with no budget → HIGH_UNRESOLVED (exit 6)" || fail "24: CONTINUE+cap-reach ceiling → expected exit 6, got $rc"
}

# ---------------------------------------------------------------------------
# 25. CONTINUE under limit → exit 1
#     detail-plan, CAP=2, EXT_USED=0, MAX_EXT=2 → NEW limit=3.
#     No pre-existing rows. Mock appends row 1 → count=1 < 3.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
NEEDS_REVISION
1. [HIGH] something to fix
<!-- end-codex-output -->
OUT
)"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid25 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 1 ]] && pass "25: CONTINUE under limit → exit 1" || fail "25: CONTINUE under limit → expected exit 1, got $rc"
}
