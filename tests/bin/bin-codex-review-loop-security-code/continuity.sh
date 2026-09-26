# tests/bin/bin-codex-review-loop-security-code/continuity.sh
# Tests: bin/run-codex-review-loop, bin/concern-ledger, bin/review-loop-summarize-concerns
# Tags: concern-ledger, review-code, id-continuity, shared-ledger, TL2, scope:common
# Sourced by tests/bin/bin-codex-review-loop-security-code.sh.
# ID continuity across rounds driven end-to-end through the loop, plus re-reading
# the persisted ledger from a session that shares nothing but the file.

echo ""
echo "--- K: ID continuity across rounds, cross-session re-read ---"

KPATH="bin/lib/concern-ledger.sh"
KANCHOR="cl_bind"
KCAT="correctness"
KTEXT1="cl_bind must not inherit an ID from slot position alone"
KTEXT2="binding by bucket position would re-attach C1 to an unrelated finding"
KTEXT3="the round-3 restatement is worded differently again so each ID has one text"

kwork() { mktemp -d "$TMPDIR_BASE/con-XXXXXX"; }

# complete_round <round> — the scanner half of the round as the fallback path
# performs it: the SAME loop re-entered with an explicitly empty report. Without
# it the completeness gate (correctly) refuses to let absence resolve anything.
complete_round() {
    RL_EXTRA=(--prestaged-report "$SCAN_NONE" --prestaged-producer security-scanner
              --prestaged-exec PERFORMED)
    run_loop --round "$1"
    RL_EXTRA=()
}

# k_round <workdir> <round> <ref> <text> — one full round: reviewer then scanner.
k_round() {
    mk_body "$1/b$2.txt" "$(anchored HIGH "$3" "$KPATH" "$KANCHOR" "$KCAT" "$4")"
    RL_CODEX_BODY="$1/b$2.txt"
    run_loop --round "$2"
    complete_round "$2"
}

k_env() {
    new_env
    RL_CAP=5
    RL_MAXEXT=0
    LEDGER="$(ledger_file "$PLANS" "$SID")"
}

# ---------------------------------------------------------------------------
# K7a. A declared reference ID survives a complete rewording of the text.
# ---------------------------------------------------------------------------
{
    KW=$(kwork)
    k_env
    k_round "$KW" 1 - "$KTEXT1"
    ID1="$(id_for_text "$LEDGER" "$KTEXT1")"
    assert_match "K7a: round 1 mints an ID (precondition)" '^C[0-9]+$' "$ID1"

    k_round "$KW" 2 "$ID1" "$KTEXT2"

    assert_eq "K7a: the reworded concern keeps its reference ID" \
        "same" "$(id_is "$LEDGER" "$KTEXT2" "$ID1")"
    assert_eq "K7a: no second entry is minted for the same concern" \
        "1" "$(entry_count "$LEDGER")"
    assert_eq "K7a: the entry stays open across the rounds" \
        "open" "$(entry_field "$LEDGER" "$ID1" $F_STATE)"
    assert_eq "K7a: FIRST_ROUND still points at the first sighting" \
        "1" "$(entry_field "$LEDGER" "$ID1" $F_FIRST)"
    assert_eq "K7a: LAST_ROUND advances to the current round" \
        "2" "$(entry_field "$LEDGER" "$ID1" $F_LAST)"

    # K8. Another session, sharing only the file, can render the ledger.
    SUMMARY="$(cd "$TMPDIR_BASE" && env -u PLANS_DIR -u SESSION_ID -u CLAUDE_SESSION_ID \
        -u CLAUDE_CODE_SESSION_ID -u CONCERN_LEDGER_ROUND HOME="$TMPDIR_BASE" \
        bash "$SUMMARIZE" --ledger "$LEDGER" --budget-remaining 0 2>/dev/null || true)"
    assert_contains "K8: a fresh session renders the persisted ledger" "$ID1" "$SUMMARY"
    assert_contains "K8: the rendered summary carries the concern text" "$KTEXT2" "$SUMMARY"
    assert_not_contains "K8: the ledger is not reported as unavailable" \
        "concern ledger not available" "$SUMMARY"
}

# ---------------------------------------------------------------------------
# K7b. Verbatim-identical text binds with no reference ID at all.
# ---------------------------------------------------------------------------
{
    KW=$(kwork)
    k_env
    k_round "$KW" 1 - "$KTEXT1"
    ID1="$(id_for_text "$LEDGER" "$KTEXT1")"
    assert_match "K7b: round 1 mints an ID (precondition)" '^C[0-9]+$' "$ID1"

    k_round "$KW" 2 - "$KTEXT1"

    assert_eq "K7b: a verbatim restatement binds to the same ID without a ref" \
        "same" "$(id_is "$LEDGER" "$KTEXT1" "$ID1")"
    assert_eq "K7b: no duplicate entry is created" "1" "$(entry_count "$LEDGER")"
    assert_eq "K7b: the entry is not marked ambiguous when it bound cleanly" \
        "absent" "$(flag_state "$LEDGER" "$ID1" ambiguous)"
}

# ---------------------------------------------------------------------------
# K7c/K7d. No reference ID and reworded text: the same anchor triple must NOT
# hand the old ID over (the positional-inheritance ban), and the next round's
# reference ID must repair the split.
# ---------------------------------------------------------------------------
{
    KW=$(kwork)
    k_env
    k_round "$KW" 1 - "$KTEXT1"
    ID1="$(id_for_text "$LEDGER" "$KTEXT1")"
    assert_match "K7c: round 1 mints an ID (precondition)" '^C[0-9]+$' "$ID1"

    k_round "$KW" 2 - "$KTEXT2"

    ID2="$(id_for_text "$LEDGER" "$KTEXT2")"
    assert_eq "K7c: a same-slot line with no ref and new text gets a NEW ID" \
        "new" "$(id_class "$ID2" "$ID1")"
    assert_eq "K7c: the old entry is not resolved by the unbound line" \
        "open" "$(entry_field "$LEDGER" "$ID1" $F_STATE)"
    assert_eq "K7c: the old entry is flagged ambiguous instead" \
        "has" "$(flag_state "$LEDGER" "$ID1" ambiguous)"
    assert_eq "K7c: both entries are present after the split" "2" "$(entry_count "$LEDGER")"

    # (d) Round 3 declares the reference ID: the binding is repaired. A third
    # wording keeps one text per entry, so the lookup below is unambiguous.
    k_round "$KW" 3 "$ID1" "$KTEXT3"

    assert_eq "K7d: the declared reference ID binds the reworded concern back" \
        "same" "$(id_is "$LEDGER" "$KTEXT3" "$ID1")"
    assert_eq "K7d: the ambiguity flag is cleared once the binding is declared" \
        "absent" "$(flag_state "$LEDGER" "$ID1" ambiguous)"
    assert_eq "K7d: the duplicate minted in round 2 resolves" \
        "resolved" "$(entry_field "$LEDGER" "$ID2" $F_STATE)"
    assert_eq "K7d: no ID is reused or dropped from the ledger" \
        "2" "$(entry_count "$LEDGER")"
}

# ---------------------------------------------------------------------------
# K9. The counter and the ledger are two artifacts of one continuity: the round
#     numbers the ledger recorded must be the ones the loop counted.
# ---------------------------------------------------------------------------
{
    KW=$(kwork)
    k_env
    k_round "$KW" 1 - "$KTEXT1"
    ID1="$(id_for_text "$LEDGER" "$KTEXT1")"
    k_round "$KW" 2 "$ID1" "$KTEXT2"

    assert_eq "K9: the round counter agrees with the last round the ledger saw" \
        "counter=2 last=2" \
        "counter=$(trim "$(cat "$(round_file "$PLANS" "$SID")" 2>/dev/null || true)") last=$(entry_field "$LEDGER" "$ID1" $F_LAST)"
    assert_eq "K9: each round left one codex delta behind" \
        "r1=present r2=present" \
        "r1=$(file_state "$(delta_file "$PLANS" "$SID" 1 review-code-codex)") r2=$(file_state "$(delta_file "$PLANS" "$SID" 2 review-code-codex)")"
    assert_eq "K9: and one scanner delta per round beside it" \
        "r1=present r2=present" \
        "r1=$(file_state "$(delta_file "$PLANS" "$SID" 1 security-scanner)") r2=$(file_state "$(delta_file "$PLANS" "$SID" 2 security-scanner)")"
    assert_eq "K9: no round 3 artifact was created by a two-round review" \
        "missing" "$(file_state "$(delta_file "$PLANS" "$SID" 3 review-code-codex)")"
}
