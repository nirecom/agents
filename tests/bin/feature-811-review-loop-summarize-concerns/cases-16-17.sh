# tests/feature-811-review-loop-summarize-concerns/cases-16-17.sh
# Tests: bin/review-loop-summarize-concerns
# Tags: feature, cap-menu, summarize-concerns, scope:issue-specific, pwsh-not-required
# Sourced by tests/feature-811-review-loop-summarize-concerns.sh.
# Cases 16-17 moved here verbatim (no content change) to keep the parent file
# under the file-split HARD limit of 500 lines once the v2 cases were appended.

# ---------------------------------------------------------------------------
# 16. Same-severity stable ordering — same-severity concerns retain ledger
#     source order.
# ---------------------------------------------------------------------------
LEDGER16="$TMPDIR_BASE/ledger-16.txt"
printf 'C1|HIGH|first high\nC2|HIGH|second high\nC3|MEDIUM|the medium\n' > "$LEDGER16"
RES=$(run_helper --ledger "$LEDGER16" --budget-remaining 1)
RC=$(extract_rc "$RES"); OUT=$(extract_out "$RES")
[[ "$RC" == "0" ]] && pass "same-severity ordering: exit 0" || fail "same-severity ordering: expected exit 0, got $RC. Output: $OUT"
POS_C1=$(echo "$OUT" | grep -n -- "C1" | head -n 1 | cut -d: -f1)
POS_C2=$(echo "$OUT" | grep -n -- "C2" | head -n 1 | cut -d: -f1)
POS_C3=$(echo "$OUT" | grep -n -- "C3" | head -n 1 | cut -d: -f1)
if [[ -n "$POS_C1" && -n "$POS_C2" && -n "$POS_C3" && "$POS_C1" -lt "$POS_C2" && "$POS_C2" -lt "$POS_C3" ]]; then
    pass "same-severity ordering: C1 < C2 (HIGH stable) and C2 < C3 (MEDIUM after HIGH)"
else
    fail "same-severity ordering: expected C1 < C2 < C3, got C1=$POS_C1 C2=$POS_C2 C3=$POS_C3. Output: $OUT"
fi

# Case 17 — Idempotency: pure read-only renderer must produce identical output on repeated calls
# ---------------------------------------------------------------------------
RES1=$(run_helper --ledger "$LEDGER" --raw "$RAW" --budget-remaining 1); RC1=$(extract_rc "$RES1"); OUT1=$(extract_out "$RES1")
RES2=$(run_helper --ledger "$LEDGER" --raw "$RAW" --budget-remaining 1); RC2=$(extract_rc "$RES2"); OUT2=$(extract_out "$RES2")
[[ "$RC1" == "0" && "$RC2" == "0" ]] && pass "idempotency: both runs exit 0" || fail "idempotency: expected both exit 0, got RC1=$RC1 RC2=$RC2"
[[ "$OUT1" == "$OUT2" ]] && pass "idempotency: output identical across two runs" || fail "idempotency: output differs between runs"
