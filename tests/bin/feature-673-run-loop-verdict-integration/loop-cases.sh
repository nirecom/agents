case_begin "risk-signal-flag-arg-parse" "bin/run-codex-review-loop"
# ---------------------------------------------------------------------------
# 3d. --risk-signal accepted by run-codex-review-loop arg parser (no exit 4)
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
1. [LOW] nit one
2. [LOW] nit two"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i3d --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" \
    --risk-signal "x" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 0 ]] && [[ $rc -ne 4 ]]; then
    pass "3d: --risk-signal accepted by arg parser (no exit 4)"
  else
    fail "3d: --risk-signal accepted by arg parser → expected exit 0, got $rc (exit 4 means flag not yet supported)"
  fi
}
case_end

case_begin "verdict-round3-auto-extend" "bin/review-loop-verdict"
# ---------------------------------------------------------------------------
# 4. Round 3, HIGH persists with budget=2 remaining → AUTO_EXTEND (exit 5)
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  printf 'C1|HIGH|big issue\n' > "$LEDGER"
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
C1: unresolved — still big"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i4 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --force-round 3 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 5 ]]; then
    pass "4: round 3 HIGH with budget=2 remaining → AUTO_EXTEND (exit 5)"
  else
    fail "4: round 3 HIGH with budget=2 → expected AUTO_EXTEND (exit 5), got $rc"
  fi
}
case_end

case_begin "ledger-strips-unknown-ids" "bin/run-codex-review-loop"
# ---------------------------------------------------------------------------
# 5. Round 2, new concern C99 injected → stripped; remaining resolved → APPROVED
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  printf 'C1|HIGH|big issue\n' > "$LEDGER"
  # Codex returns only a new (not in ledger) concern — after stripping, nothing remains
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
C99: unresolved — injected new"
  rc=0
  STDERR_OUT=$(invoke "$MOCK" --format detail-plan --session-id i5 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --force-round 2 --ledger "$LEDGER" 2>&1 >/dev/null) || rc=$?
  if [[ $rc -eq 0 ]] && echo "$STDERR_OUT" | grep -q "C99"; then
    pass "5: round 2 injected C99 stripped → APPROVED + warning in stderr"
  else
    fail "5: expected exit 0 + C99 warning. Got exit $rc, stderr: $STDERR_OUT"
  fi
}
case_end

case_begin "verdict-medium-only-converges" "bin/review-loop-verdict"
# ---------------------------------------------------------------------------
# 6. Round 1 MEDIUM only → CONTINUE; Round 2 MEDIUM persists → APPROVED
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"

  # Round 1: MEDIUM only → CONTINUE
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
1. [MEDIUM] medium one"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i6 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 1 ]]; then
    pass "6a: round 1 MEDIUM only → CONTINUE"
  else
    fail "6a: round 1 MEDIUM only → expected exit 1, got $rc"
  fi

  # Round 2: same MEDIUM concern persists → APPROVED (MEDIUM-only round>=2)
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
C1: unresolved — medium one still"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i6 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 2 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "6b: round 2 MEDIUM persists → APPROVED"
  else
    fail "6b: round 2 MEDIUM persists → expected exit 0, got $rc"
  fi
}
case_end

case_begin "ledger-missing-on-round2" "bin/run-codex-review-loop"
# ---------------------------------------------------------------------------
# 7. Round 2 missing ledger file → exit 4
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/no-such-ledger.txt"
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
C1. [HIGH] foo"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i7 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --force-round 2 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 4 ]]; then
    pass "7: round 2 missing ledger → exit 4"
  else
    fail "7: expected exit 4, got $rc"
  fi
}
case_end

case_begin "auto-round-numbering" "bin/run-codex-review-loop"
# ---------------------------------------------------------------------------
# 8. --round flag absent → the wrapper numbers the round itself (#2068). The
#    counter is the wrapper's own, so a caller that names no round is not a
#    caller error any more: round 1 runs and the verdict is the reviewer's.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_codex_mock "$MOCK" "APPROVED"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i8 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --ledger "$TMP/ledger.txt" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "8: --round flag absent → round 1 is allocated and the round is judged"
  else
    fail "8: --round absent → expected the auto-numbered round to run (exit 0), got $rc"
  fi
  if [[ ! -f "$CLAUDE_WORKFLOW_DIR/i8.control/detail-plan-round-number.txt" && ! -f "$PLANS/i8-detail-plan-round-number.txt" ]]; then
    pass "8: and the terminal retires the counter it allocated"
  else
    fail "8: the counter outlived the terminal round"
  fi
}
case_end

case_begin "outline-format-ledger" "bin/run-codex-review-loop"
# ---------------------------------------------------------------------------
# 9. outline-plan format: Round-1 MISSING_ALTERNATIVE: body parsed for severity
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  make_review_codex_mock "$MOCK" "MISSING_ALTERNATIVE: 1. [HIGH] need async option
2. [MEDIUM] consider sync fallback"
  rc=0
  invoke "$MOCK" --format outline-plan --session-id i9 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 1 ]]; then
    pass "9: outline-plan MISSING_ALTERNATIVE round 1 → CONTINUE (exit 1)"
  else
    fail "9: outline-plan MISSING_ALTERNATIVE → expected exit 1, got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 10. outline-plan format: concern IDs assigned in ledger
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  make_review_codex_mock "$MOCK" "MISSING_ALTERNATIVE:
1. [HIGH] need async option"
  invoke "$MOCK" --format outline-plan --session-id i10 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" >/dev/null 2>&1 || true
  if [[ -f "$LEDGER" ]] && grep -q "^C1|HIGH|" "$LEDGER"; then
    pass "10: outline-plan assigns C1 in ledger"
  else
    fail "10: outline-plan ledger missing C1. Contents: $(cat "$LEDGER" 2>/dev/null)"
  fi
}
case_end

case_begin "ledger-full-text-roundtrip" "bin/run-codex-review-loop"
# ---------------------------------------------------------------------------
# 11. Full concern text recovered exactly from ledger in round 2
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  EXACT="this exact text must round-trip through pipes | and survive"
  # Round 1: write ledger
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
1. [HIGH] $EXACT"
  invoke "$MOCK" --format detail-plan --session-id i11 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" >/dev/null 2>&1 || true

  if [[ -f "$LEDGER" ]] && grep -q "$EXACT" "$LEDGER"; then
    pass "11: full concern text (with pipes) preserved in ledger"
  else
    fail "11: text not preserved exactly. Ledger: $(cat "$LEDGER" 2>/dev/null)"
  fi
}
case_end
