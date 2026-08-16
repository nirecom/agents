# tests/bin-concern-ledger-shared-code-review/continuity.sh
# Tests: bin/review-code-ledger, bin/concern-ledger
# Tags: concern-ledger, review-code, id-continuity, shared-ledger, TL2, scope:common

# Sourced by tests/bin-concern-ledger-shared-code-review.sh.
# Detail-plan Test plan (shared TL2) cases 7, 8 — ID continuity across rounds
# driven end-to-end through bin/review-code-ledger, and re-reading the persisted
# ledger from a session that shares nothing but the file.

echo ""
echo "--- shared 7/8: ID continuity across rounds, cross-session re-read ---"

KPATH="bin/lib/concern-ledger.sh"
KANCHOR="cl_bind"
KCAT="correctness"
KTEXT1="cl_bind must not inherit an ID from slot position alone"
KTEXT2="binding by bucket position would re-attach C1 to an unrelated finding"
KTEXT3="the round-3 restatement is worded differently again so each ID has one text"

kwork() { mktemp -d "$TMPDIR_BASE/con-XXXXXX"; }

# The scanner half of a round, exactly as the Completion close-out performs it:
# an explicitly empty report plus the second reduce. Without it the
# completeness gate (correctly) refuses to let absence resolve anything.
SCAN_NONE="$TMPDIR_BASE/scan-none.txt"
mk_report "$SCAN_NONE"
complete_round() { # <plans> <sid> <round>
    run_cli stage --plans-dir "$1" --session-id "$2" --format "$FORMAT" \
        --round "$3" --producer security-scanner --from-report "$SCAN_NONE" >/dev/null 2>&1
    run_cli reduce --plans-dir "$1" --session-id "$2" --format "$FORMAT" \
        --round "$3" >/dev/null 2>&1
}

# round1_id — runs round 1 through the wrapper and echoes the minted ID.
round1_id() { # <workdir>
    mk_body "$1/b1.txt" "$(anchored HIGH - "$KPATH" "$KANCHOR" "$KCAT" "$KTEXT1")"
    RL_CODEX_BODY="$1/b1.txt"
    RL_ROUND=1
    run_ledger
    complete_round "$PLANS" "$SID" 1
    id_for_text "$(ledger_file "$PLANS" "$SID")" "$KTEXT1"
}

# ---------------------------------------------------------------------------
# 7(a). A declared reference ID survives a complete rewording of the text.
# ---------------------------------------------------------------------------
{
    KW=$(kwork)
    new_env
    LEDGER="$(ledger_file "$PLANS" "$SID")"
    ID1="$(round1_id "$KW")"
    assert_match "7a: round 1 mints an ID (precondition)" '^C[0-9]+$' "$ID1"

    mk_body "$KW/b2.txt" "$(anchored HIGH "$ID1" "$KPATH" "$KANCHOR" "$KCAT" "$KTEXT2")"
    RL_CODEX_BODY="$KW/b2.txt"
    RL_ROUND=2
    run_ledger
    complete_round "$PLANS" "$SID" 2

    assert_eq "7a: the reworded concern keeps its reference ID" \
        "same" "$(id_is "$LEDGER" "$KTEXT2" "$ID1")"
    assert_eq "7a: no second entry is minted for the same concern" \
        "1" "$(entry_count "$LEDGER")"
    assert_eq "7a: the entry stays open across the rounds" \
        "open" "$(entry_field "$LEDGER" "$ID1" $F_STATE)"
    assert_eq "7a: FIRST_ROUND still points at the first sighting" \
        "1" "$(entry_field "$LEDGER" "$ID1" $F_FIRST)"
    assert_eq "7a: LAST_ROUND advances to the current round" \
        "2" "$(entry_field "$LEDGER" "$ID1" $F_LAST)"

    # 8. Another session, sharing only the file, can render the ledger.
    SUMMARY="$(cd "$TMPDIR_BASE" && env -u PLANS_DIR -u SESSION_ID -u CLAUDE_SESSION_ID \
        -u CLAUDE_CODE_SESSION_ID -u CONCERN_LEDGER_ROUND HOME="$TMPDIR_BASE" \
        bash "$SUMMARIZE" --ledger "$LEDGER" --budget-remaining 0 2>/dev/null || true)"
    assert_contains "8: a fresh session renders the persisted ledger" "$ID1" "$SUMMARY"
    assert_contains "8: the rendered summary carries the concern text" "$KTEXT2" "$SUMMARY"
    assert_not_contains "8: the ledger is not reported as unavailable" \
        "concern ledger not available" "$SUMMARY"
}

# ---------------------------------------------------------------------------
# 7(b). Verbatim-identical text binds through B2 with no reference ID at all.
# ---------------------------------------------------------------------------
{
    KW=$(kwork)
    new_env
    LEDGER="$(ledger_file "$PLANS" "$SID")"
    ID1="$(round1_id "$KW")"
    assert_match "7b: round 1 mints an ID (precondition)" '^C[0-9]+$' "$ID1"

    mk_body "$KW/b2.txt" "$(anchored HIGH - "$KPATH" "$KANCHOR" "$KCAT" "$KTEXT1")"
    RL_CODEX_BODY="$KW/b2.txt"
    RL_ROUND=2
    run_ledger
    complete_round "$PLANS" "$SID" 2

    assert_eq "7b: a verbatim restatement binds to the same ID without a ref" \
        "same" "$(id_is "$LEDGER" "$KTEXT1" "$ID1")"
    assert_eq "7b: no duplicate entry is created" "1" "$(entry_count "$LEDGER")"
    assert_eq "7b: the entry is not marked ambiguous when it bound cleanly" \
        "absent" "$(flag_state "$LEDGER" "$ID1" ambiguous)"
}

# ---------------------------------------------------------------------------
# 7(c)/(d). No reference ID and reworded text: the same anchor triple must NOT
# hand the old ID over (this is the positional-inheritance ban), and the next
# round's reference ID must repair the split.
# ---------------------------------------------------------------------------
{
    KW=$(kwork)
    new_env
    LEDGER="$(ledger_file "$PLANS" "$SID")"
    ID1="$(round1_id "$KW")"
    assert_match "7c: round 1 mints an ID (precondition)" '^C[0-9]+$' "$ID1"

    mk_body "$KW/b2.txt" "$(anchored HIGH - "$KPATH" "$KANCHOR" "$KCAT" "$KTEXT2")"
    RL_CODEX_BODY="$KW/b2.txt"
    RL_ROUND=2
    run_ledger
    complete_round "$PLANS" "$SID" 2

    ID2="$(id_for_text "$LEDGER" "$KTEXT2")"
    assert_eq "7c: a same-slot line with no ref and new text gets a NEW ID" \
        "new" "$(id_class "$ID2" "$ID1")"
    assert_eq "7c: the old entry is not resolved by the unbound line" \
        "open" "$(entry_field "$LEDGER" "$ID1" $F_STATE)"
    assert_eq "7c: the old entry is flagged ambiguous instead" \
        "has" "$(flag_state "$LEDGER" "$ID1" ambiguous)"
    assert_eq "7c: both entries are present after the split" "2" "$(entry_count "$LEDGER")"

    # (d) Round 3 declares the reference ID: B1 binds, the duplicate goes away.
    # A third wording keeps one text per entry, so the lookup below is unambiguous.
    mk_body "$KW/b3.txt" "$(anchored HIGH "$ID1" "$KPATH" "$KANCHOR" "$KCAT" "$KTEXT3")"
    RL_CODEX_BODY="$KW/b3.txt"
    RL_ROUND=3
    run_ledger
    complete_round "$PLANS" "$SID" 3

    assert_eq "7d: the declared reference ID binds the reworded concern back" \
        "same" "$(id_is "$LEDGER" "$KTEXT3" "$ID1")"
    assert_eq "7d: the ambiguity flag is cleared once the binding is declared" \
        "absent" "$(flag_state "$LEDGER" "$ID1" ambiguous)"
    assert_eq "7d: the duplicate minted in round 2 resolves" \
        "resolved" "$(entry_field "$LEDGER" "$ID2" $F_STATE)"
    assert_eq "7d: no ID is reused or dropped from the ledger" \
        "2" "$(entry_count "$LEDGER")"
}
