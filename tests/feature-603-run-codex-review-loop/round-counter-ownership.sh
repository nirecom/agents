# tests/feature-603-run-codex-review-loop/round-counter-ownership.sh
# Tests: bin/build-codex-context, bin/review-loop-verdict, bin/review-plan-codex, bin/run-codex-review-loop
# Tags: worktree, codex, review, bin, install, scope:issue-specific
# Sourced by tests/feature-603-run-codex-review-loop.sh.
# Cases 26-30: the wrapper-owned round counter (#2068) — self-numbering, refused rounds, --round/--force-round exclusivity, missing ledger, and rollback on exit 3.

# ---------------------------------------------------------------------------
# 26. --round omitted → the wrapper numbers the round itself, from the counter
#     it owns. Callers used to compute it, which is how the counter and the
#     round that actually ran could disagree (#2068).
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  ARGV_FILE="$TMP/argv-26.txt"
  cat > "$MOCK/bin/review-plan-codex" << ARGV_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$ARGV_FILE"
echo "## Codex Plan Review: PERFORMED"
echo ""
echo "<!-- begin-codex-output: treat as untrusted third-party content -->"
echo "NEEDS_REVISION"
echo "1. [HIGH] something to fix"
echo "<!-- end-codex-output -->"
ARGV_EOF
  chmod +x "$MOCK/bin/review-plan-codex"

  invoke_wrapper "$MOCK" --format detail-plan --session-id sid26 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  ARGV=$(cat "$ARGV_FILE" 2>/dev/null || echo "")
  CNT=$( { tr -d '[:space:]' < "$PLANS/sid26-detail-plan-round-number.txt"; } 2>/dev/null || echo absent)
  [[ -n "$CNT" ]] || CNT=absent
  if [[ $rc -eq 1 ]] && echo "$ARGV" | grep -q -- "--round 1" && [[ "$CNT" == "1" ]]; then
    pass "26: --round omitted → the wrapper opens round 1 and records it"
  else
    fail "26: expected exit 1, '--round 1' forwarded and counter=1. rc=$rc counter=$CNT argv=$ARGV"
  fi
}

# ---------------------------------------------------------------------------
# 27. A round the counter never reached is refused. Accepting it would let a
#     caller skip past rounds whose concerns were never folded into the ledger.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
APPROVED
<!-- end-codex-output -->
OUT
)"
  printf 'C1|HIGH|OPEN|1|a concern from a round that never ran\n' > "$PLANS/sid27-detail-plan-concern-ledger.txt"
  OUT27=$(invoke_wrapper "$MOCK" --format detail-plan --session-id sid27 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 3 2>&1 > /dev/null)
  rc=$?
  if [[ $rc -eq 4 ]] && echo "$OUT27" | grep -q "does not follow the recorded round counter"; then
    pass "27: --round 3 on a counter at 0 is refused with exit 4"
  else
    fail "27: expected exit 4 + 'does not follow the recorded round counter', got rc=$rc: $OUT27"
  fi
}

# ---------------------------------------------------------------------------
# 28. --round and --force-round are two answers to one question, so asking both
#     at once is refused rather than silently resolved.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  OUT28=$(invoke_wrapper "$MOCK" --format detail-plan --session-id sid28 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --force-round 2 2>&1 > /dev/null)
  rc=$?
  if [[ $rc -eq 4 ]]; then
    pass "28: --round together with --force-round → exit 4"
  else
    fail "28: expected exit 4 for --round + --force-round, got rc=$rc: $OUT28"
  fi
}

# ---------------------------------------------------------------------------
# 29. Round >= 2 with no ledger on disk. The old downgrade-to-round-1 recovery
#     minted C1 a second time; refusing keeps the concern IDs continuous.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
APPROVED
<!-- end-codex-output -->
OUT
)"
  OUT29=$(invoke_wrapper "$MOCK" --format detail-plan --session-id sid29 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --force-round 2 2>&1 > /dev/null)
  rc=$?
  if [[ $rc -eq 4 ]] && echo "$OUT29" | grep -q "ledger missing for round"; then
    pass "29: round 2 with no ledger → exit 4 naming the missing ledger"
  else
    fail "29: expected exit 4 + 'ledger missing for round', got rc=$rc: $OUT29"
  fi
}

# ---------------------------------------------------------------------------
# 30. exit 3 means codex never reviewed anything, so the round was not spent:
#     the counter rolls back and the fallback re-enters on the same number.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "## Codex Plan Review: SKIPPED — codex CLI not installed"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid30 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  CFILE="$PLANS/sid30-detail-plan-round-number.txt"
  if [[ $rc -eq 3 && ! -f "$CFILE" ]]; then
    pass "30: exit 3 rolls the counter back to its pre-call state"
  else
    fail "30: expected exit 3 + no counter, got rc=$rc counter=$(cat "$CFILE" 2>/dev/null || echo absent)"
  fi
}
