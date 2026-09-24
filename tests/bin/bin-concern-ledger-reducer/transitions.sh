# tests/bin-concern-ledger-reducer/transitions.sh
# Tests: bin/lib/concern-ledger.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/concern-ledger
# Tags: concern-ledger, reducer, bind, merge, completeness, table-driven, scope:common, pwsh-not-required
# Sourced by tests/bin-concern-ledger-reducer.sh.
# Detail-plan Test plan cases 12, 16, 17, 19 — the cl_reduce state transition table
# (carry / resolve / new / reopen / discard / stale / ambiguous), admission policy,
# severity aggregation, and reduce idempotency.

echo ""
echo "--- reducer 12/16/17/19: state transitions, admission, severity, idempotency ---"

TSID="transsess"
TFMT="review-security-shared"
TPROD="review-code-codex"

TP="bin/concern-ledger"
TA1="cl_stage"
TA2="cl_tally"
TCAT="correctness"
TSLOT1=$(cl cl_slot "$TP" "$TA1" "$TCAT")
TSLOT2=$(cl cl_slot "$TP" "$TA2" "$TCAT")

TX1="stage must refuse an unknown producer name"
TX2="tally must count open entries only"
TX3="stage must create the staging directory when absent"
TD1=$(cl cl_discrim "$TX1")
TD2=$(cl cl_discrim "$TX2")

twork() { mktemp -d "$TMPDIR_BASE/trans-XXXXXX"; }

# mk_codex_output <file> <line>...  → plan-format reviewer output block
mk_codex_output() {
    local f="$1" l
    shift
    {
        printf '<!-- begin-codex-output -->\n'
        for l in "$@"; do printf '%s\n' "$l"; done
        printf '<!-- end-codex-output -->\n'
    } > "$f"
}

# ---------------------------------------------------------------------------
# 12. carry / resolve / new  (one round, COMPLETE producer)
# ---------------------------------------------------------------------------
{
    W=$(twork)
    mk_ledger "$W/in.txt" "$TFMT" "$TSID" 1
    add_entry "$W/in.txt" C1 HIGH open 1 1 "$TSLOT1" "$TD1" "$TPROD" "$TPROD" - "$TX1"
    add_entry "$W/in.txt" C2 MEDIUM open 1 1 "$TSLOT2" "$TD2" "$TPROD" "$TPROD" - "$TX2"
    mk_delta_report "$W/raw.txt" \
        "$(anchored HIGH C1 "$TP" "$TA1" "$TCAT" "$TX1")" \
        "$(anchored LOW - "$TP" "$TA1" "$TCAT" "$TX3")"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$TFMT" \
        "$TPROD@COMPLETE@$W/raw.txt" "security-scanner@COMPLETE@$NONE_REPORT"

    assert_eq "12 carry: re-reported entry stays open" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "12 carry: LAST_ROUND advances" "2" "$(entry_field "$W/out.txt" C1 $F_LAST)"
    assert_eq "12 carry: FIRST_ROUND is preserved" "1" "$(entry_field "$W/out.txt" C1 $F_FIRST)"
    assert_eq "12 resolve: absent entry in a clean slot resolves" \
        "resolved" "$(entry_field "$W/out.txt" C2 $F_STATE)"
    NEWID="$(id_for_text "$W/out.txt" "$TX3")"
    assert_match "12 new: unseen concern gets an ID" '^C[0-9]+$' "$NEWID"
    assert_eq "12 new: new entry is open" "open" "$(entry_field "$W/out.txt" "$NEWID" $F_STATE)"
    assert_eq "12 new: new entry's FIRST_ROUND is the current round" \
        "2" "$(entry_field "$W/out.txt" "$NEWID" $F_FIRST)"

    # 12 reopen: a resolved entry reported again returns to open, keeping FIRST_ROUND.
    mk_delta_report "$W/raw3.txt" "$(anchored MEDIUM C2 "$TP" "$TA2" "$TCAT" "$TX2")"
    reduce_round "$W/out.txt" "$W/r3.txt" 3 "$TFMT" \
        "$TPROD@COMPLETE@$W/raw3.txt" "security-scanner@COMPLETE@$NONE_REPORT"
    assert_eq "12 reopen: resolved entry returns to open" \
        "open" "$(entry_field "$W/r3.txt" C2 $F_STATE)"
    assert_eq "12 reopen: FIRST_ROUND still points at the original round" \
        "1" "$(entry_field "$W/r3.txt" C2 $F_FIRST)"
    assert_eq "12 reopen: LAST_ROUND is the reopening round" \
        "3" "$(entry_field "$W/r3.txt" C2 $F_LAST)"
    assert_contains "12 reopen: the reopen is flagged" \
        "reopen" "$(entry_field "$W/r3.txt" C2 $F_FLAGS)"
}

# ---------------------------------------------------------------------------
# 12 stale: a PARTIAL producer must not let absence resolve anything.
# 12 ambiguous: an unbound line in an occupied slot blocks that slot.
# ---------------------------------------------------------------------------
{
    W=$(twork)
    mk_ledger "$W/in.txt" "$TFMT" "$TSID" 1
    add_entry "$W/in.txt" C1 HIGH open 1 1 "$TSLOT1" "$TD1" "$TPROD" "$TPROD" - "$TX1"
    add_entry "$W/in.txt" C2 MEDIUM open 1 1 "$TSLOT2" "$TD2" "$TPROD" "$TPROD" - "$TX2"
    mk_delta_report "$W/raw.txt" "$(anchored HIGH C1 "$TP" "$TA1" "$TCAT" "$TX1")"
    reduce_round "$W/in.txt" "$W/partial.txt" 2 "$TFMT" "$TPROD@PARTIAL@$W/raw.txt"

    assert_eq "12 stale: absent entry stays open under a PARTIAL producer" \
        "open" "$(entry_field "$W/partial.txt" C2 $F_STATE)"
    assert_contains "12 stale: the carried-over entry is flagged stale" \
        "stale" "$(entry_field "$W/partial.txt" C2 $F_FLAGS)"

    mk_delta_report "$W/rawamb.txt" "$(anchored HIGH - "$TP" "$TA1" "$TCAT" "$TX3")"
    reduce_round "$W/in.txt" "$W/amb.txt" 2 "$TFMT" "$TPROD@COMPLETE@$W/rawamb.txt"
    assert_eq "12 ambiguous: blocked entry stays open" \
        "open" "$(entry_field "$W/amb.txt" C1 $F_STATE)"
    assert_contains "12 ambiguous: blocked entry is flagged ambiguous" \
        "ambiguous" "$(entry_field "$W/amb.txt" C1 $F_FLAGS)"
}

# ---------------------------------------------------------------------------
# 12 discard / 16. admission=closed on plan formats at round >= 2.
#     The stderr wording must stay identical to the current loop's message.
# ---------------------------------------------------------------------------
{
    W=$(twork)
    PFMT="detail-plan"
    mk_ledger "$W/in.txt" "$PFMT" "$TSID" 1
    add_entry "$W/in.txt" C1 HIGH open 1 1 "$TSLOT1" "$TD1" codex codex - "$TX1"
    mk_codex_output "$W/raw.txt" \
        "C1: unresolved — the guard still allows the unknown producer" \
        "C99: brand new concern that was never in the ledger"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$PFMT" "codex@COMPLETE@$W/raw.txt@cnref"

    assert_eq "16: unknown ID is discarded, not minted" "1" "$(entry_count "$W/out.txt")"
    assert_eq "16: known ID survives the round" "C1" "$(id_for_text "$W/out.txt" "$TX1")"
    assert_contains "16: discard warning keeps the current wording" \
        "discarded new concern IDs in round 2: C99" "$(cat "$LAST_REDUCE_ERR" 2>/dev/null || true)"

    # Round 1 admission is always open, even for plan formats.
    mk_ledger "$W/empty.txt" "$PFMT" "$TSID" 1
    mk_codex_output "$W/raw1.txt" "C1. [HIGH] $TX1" "C2. [MEDIUM] $TX2"
    reduce_round "$W/empty.txt" "$W/r1.txt" 1 "$PFMT" "codex@COMPLETE@$W/raw1.txt@numbered"
    assert_eq "16: round 1 admission is open for plan formats" "2" "$(entry_count "$W/r1.txt")"
}

# ---------------------------------------------------------------------------
# 17. Severity is aggregated with max — a softened re-statement never downgrades.
# ---------------------------------------------------------------------------
{
    W=$(twork)
    mk_ledger "$W/in.txt" "$TFMT" "$TSID" 1
    add_entry "$W/in.txt" C1 HIGH open 1 1 "$TSLOT1" "$TD1" "$TPROD" "$TPROD" - "$TX1"
    mk_delta_report "$W/raw.txt" \
        "$(anchored LOW C1 "$TP" "$TA1" "$TCAT" "stage should probably check the producer name")"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$TFMT" "$TPROD@COMPLETE@$W/raw.txt"
    assert_eq "17: a LOW re-statement does not downgrade a HIGH entry" \
        "HIGH" "$(entry_field "$W/out.txt" C1 $F_SEV)"

    # ...and an escalation does raise it.
    mk_ledger "$W/in2.txt" "$TFMT" "$TSID" 1
    add_entry "$W/in2.txt" C1 LOW open 1 1 "$TSLOT1" "$TD1" "$TPROD" "$TPROD" - "$TX1"
    mk_delta_report "$W/raw2.txt" "$(anchored HIGH C1 "$TP" "$TA1" "$TCAT" "$TX1")"
    reduce_round "$W/in2.txt" "$W/out2.txt" 2 "$TFMT" "$TPROD@COMPLETE@$W/raw2.txt"
    assert_eq "17: an escalated re-statement raises severity to the max" \
        "HIGH" "$(entry_field "$W/out2.txt" C1 $F_SEV)"
}

# ---------------------------------------------------------------------------
# 19. Idempotency — the second reduce of the same round (review-code-ledger's
#     reduce followed by the Completion close-out's reduce) must leave the
#     ledger byte-identical.
# ---------------------------------------------------------------------------
{
    W=$(twork)
    mk_ledger "$W/in.txt" "$TFMT" "$TSID" 1
    add_entry "$W/in.txt" C1 HIGH open 1 1 "$TSLOT1" "$TD1" "$TPROD" "$TPROD" - "$TX1"
    add_entry "$W/in.txt" C2 MEDIUM open 1 1 "$TSLOT2" "$TD2" "$TPROD" "$TPROD" - "$TX2"
    mk_delta_report "$W/raw.txt" \
        "$(anchored HIGH C1 "$TP" "$TA1" "$TCAT" "$TX1")" \
        "$(anchored LOW - "$TP" "$TA1" "$TCAT" "$TX3")"
    reduce_round "$W/in.txt" "$W/pass1.txt" 2 "$TFMT" \
        "$TPROD@COMPLETE@$W/raw.txt" "security-scanner@COMPLETE@$NONE_REPORT"
    reduce_round "$W/pass1.txt" "$W/pass2.txt" 2 "$TFMT" \
        "$TPROD@COMPLETE@$W/raw.txt" "security-scanner@COMPLETE@$NONE_REPORT"

    if [[ -s "$W/pass1.txt" ]] && cmp -s "$W/pass1.txt" "$W/pass2.txt"; then
        pass "19: re-reducing the same round leaves the ledger unchanged"
    else
        fail "19: re-reducing the same round changed the ledger (or it was never written)"
    fi
    assert_eq "19: re-reduce does not mint a duplicate ID" "3" "$(entry_count "$W/pass2.txt")"
    assert_eq "19: re-reduce keeps the resolved/open split" \
        "open" "$(entry_field "$W/pass2.txt" C1 $F_STATE)"
}
