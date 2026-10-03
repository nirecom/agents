case_begin "verdict-round1-by-severity" "bin/review-loop-verdict"
# ---------------------------------------------------------------------------
# 1. Round 1, all LOW concerns → APPROVED (end-to-end happy path)
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
  invoke "$MOCK" --format detail-plan --session-id i1 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "1: round 1 all LOW → APPROVED (exit 0)"
  else
    fail "1: round 1 all LOW → expected exit 0, got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 2. Round 1, HIGH concern present → CONTINUE, ledger written
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
1. [HIGH] big issue
2. [LOW] minor"
  rc=0
  invoke "$MOCK" --format detail-plan --session-id i2 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 1 ]] && [[ -f "$LEDGER" ]] && grep -q "^C1|HIGH|" "$LEDGER"; then
    pass "2: round 1 HIGH → CONTINUE (exit 1) + ledger written"
  else
    fail "2: round 1 HIGH → expected exit 1 + ledger, got exit $rc, ledger: $(cat "$LEDGER" 2>/dev/null)"
  fi
}
case_end

case_begin "verdict-budget-and-risk-signal" "bin/review-loop-verdict"
# ---------------------------------------------------------------------------
# 3. Round 2, HIGH persists with budget=2 remaining → AUTO_EXTEND (exit 5)
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
  invoke "$MOCK" --format detail-plan --session-id i3 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --force-round 2 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 5 ]]; then
    pass "3: round 2 HIGH with budget=2 remaining → AUTO_EXTEND (exit 5)"
  else
    fail "3: round 2 HIGH with budget=2 → expected AUTO_EXTEND (exit 5), got $rc"
  fi
}

# ---------------------------------------------------------------------------
# 3b. Round 2, HIGH persists, budget=0, no --risk-signal → HIGH_UNRESOLVED
#     (exit 6). Used to be exit 0, reporting an unresolved HIGH as approved
#     (#2068). Ledger and artifact must outlive the refusal for the caller.
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
  invoke "$MOCK" --format detail-plan --session-id i3b --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 1 --extensions-used 1 \
    --accepted-tradeoffs "$PLANS/outline.md" --force-round 2 --ledger "$LEDGER" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 6 ]]; then
    pass "3b: round 2 HIGH budget=0 no risk → HIGH_UNRESOLVED (exit 6)"
  else
    fail "3b: round 2 HIGH budget=0 no risk → expected HIGH_UNRESOLVED (exit 6), got $rc"
  fi
  if [[ -f "$LEDGER" ]]; then
    pass "3b: the ledger survives the refusal, so the concern keeps its identity"
  else
    fail "3b: the ledger was dropped, losing the HIGH the exit is about"
  fi
  if [[ -f "$PLANS/i3b-detail-plan-unresolved-concerns.json" ]]; then
    pass "3b: and the unresolved concern is written out for the caller to read"
  else
    fail "3b: no unresolved-concerns artifact was written for the refused round"
  fi
}

# ---------------------------------------------------------------------------
# 3c. Round 2, HIGH persists, budget=0, WITH --risk-signal → ESCALATE (exit 2)
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
  invoke "$MOCK" --format detail-plan --session-id i3c --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 1 --extensions-used 1 \
    --accepted-tradeoffs "$PLANS/outline.md" --force-round 2 --ledger "$LEDGER" \
    --risk-signal "intent-unachievable" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 2 ]]; then
    pass "3c: round 2 HIGH budget=0 risk-signal → ESCALATE (exit 2)"
  else
    fail "3c: round 2 HIGH budget=0 risk-signal → expected ESCALATE (exit 2), got $rc"
  fi
}
case_end
