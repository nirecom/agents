# tests/bin-concern-ledger-reducer/merge.sh
# Tests: bin/lib/concern-ledger.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/concern-ledger
# Tags: concern-ledger, reducer, bind, merge, completeness, table-driven, scope:common, pwsh-not-required
# Sourced by tests/bin-concern-ledger-reducer.sh.
# Detail-plan Test plan cases 6, 7, 10, 11 — same-round delta x delta merging
# (cl_merge_producers) and the ID-invariance guarantees that depend on it.
# Position (M3) is merge-only: it may fold two delta lines, never bind a prior ID.

echo ""
echo "--- reducer 6/7/10/11: producer merge and ID invariance ---"

MSID="mergesess"
MFMT="review-security-shared"
PA="review-code-codex"
PB="security-scanner"

MP="bin/lib/concern-ledger.sh"
MA="cl_reduce"
MCAT="correctness"
MSLOT=$(cl cl_slot "$MP" "$MA" "$MCAT")

TA="reduce must not resolve entries while a partial producer exists"
TB="reduce must keep staging files after a failed run"
TC="reduce must sort producers by declared order"
DA=$(cl cl_discrim "$TA")
DB=$(cl cl_discrim "$TB")

mwork() { mktemp -d "$TMPDIR_BASE/merge-XXXXXX"; }

# two_open <file> — C1(TA) and C2(TB) sharing one slot, both open at round 1.
two_open() {
    mk_ledger "$1" "$MFMT" "$MSID" 1
    add_entry "$1" C1 HIGH open 1 1 "$MSLOT" "$DA" "$PA" "$PA" - "$TA"
    add_entry "$1" C2 MEDIUM open 1 1 "$MSLOT" "$DB" "$PA" "$PA" - "$TB"
}

# ---------------------------------------------------------------------------
# 6. Two different concerns in one slot both survive with distinct IDs.
# ---------------------------------------------------------------------------
{
    W=$(mwork)
    mk_ledger "$W/in.txt" "$MFMT" "$MSID" 1
    mk_delta_report "$W/raw.txt" \
        "$(anchored HIGH - "$MP" "$MA" "$MCAT" "$TA")" \
        "$(anchored MEDIUM - "$MP" "$MA" "$MCAT" "$TB")"
    reduce_round "$W/in.txt" "$W/out.txt" 1 "$MFMT" "$PA@COMPLETE@$W/raw.txt"

    assert_eq "6: both same-slot concerns are recorded" "2" "$(entry_count "$W/out.txt")"
    ID_A="$(id_for_text "$W/out.txt" "$TA")"
    ID_B="$(id_for_text "$W/out.txt" "$TB")"
    assert_eq "6: first same-slot concern gets an ID" "new" "$(id_class "$ID_A")"
    assert_eq "6: second same-slot concern gets a different ID" "new" "$(id_class "$ID_B" "$ID_A")"
    assert_contains "6: same-producer same-slot residue is flagged dup-suspect" \
        "dup-suspect" "$(cat "$W/out.txt" 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# 7. ID invariance under five perturbations of the same round-2 delta.
#    B2 (verbatim DISCRIM) is the binding tier in every variant.
# ---------------------------------------------------------------------------
L_A="$(anchored HIGH - "$MP" "$MA" "$MCAT" "$TA")"
L_B="$(anchored MEDIUM - "$MP" "$MA" "$MCAT" "$TB")"
L_C="$(anchored LOW - "$MP" "$MA" "$MCAT" "$TC")"
TNEAR="reduce must not resolve entries while a partial producer is present"
L_NEAR="$(anchored HIGH - "$MP" "$MA" "$MCAT" "$TNEAR")"

# 7a. sibling added
{
    W=$(mwork); two_open "$W/in.txt"
    mk_delta_report "$W/raw.txt" "$L_A" "$L_B" "$L_C"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$MFMT" "$PA@COMPLETE@$W/raw.txt"
    assert_eq "7a: sibling added — C1 keeps its concern" "C1" "$(id_for_text "$W/out.txt" "$TA")"
    assert_eq "7a: sibling added — C2 keeps its concern" "C2" "$(id_for_text "$W/out.txt" "$TB")"
    assert_match "7a: the added sibling gets its own ID" '^C[0-9]+$' "$(id_for_text "$W/out.txt" "$TC")"
    assert_eq "7a: exactly one ID is added" "3" "$(entry_count "$W/out.txt")"
}

# 7b. sibling removed
{
    W=$(mwork); two_open "$W/in.txt"
    mk_delta_report "$W/raw.txt" "$L_A"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$MFMT" \
        "$PA@COMPLETE@$W/raw.txt" "$PB@COMPLETE@$NONE_REPORT"
    assert_eq "7b: sibling removed — C1 keeps its concern" "C1" "$(id_for_text "$W/out.txt" "$TA")"
    assert_eq "7b: sibling removed — C1 stays open" "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "7b: the absent sibling resolves, keeping its ID" \
        "resolved" "$(entry_field "$W/out.txt" C2 $F_STATE)"
    assert_eq "7b: no ID is minted or dropped" "2" "$(entry_count "$W/out.txt")"
}

# 7c. delta line order swapped
{
    W=$(mwork); two_open "$W/in.txt"
    mk_delta_report "$W/raw.txt" "$L_B" "$L_A"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$MFMT" "$PA@COMPLETE@$W/raw.txt"
    assert_eq "7c: line order swapped — C1 keeps its concern" "C1" "$(id_for_text "$W/out.txt" "$TA")"
    assert_eq "7c: line order swapped — C2 keeps its concern" "C2" "$(id_for_text "$W/out.txt" "$TB")"
    assert_eq "7c: line order swapped — no new ID" "2" "$(entry_count "$W/out.txt")"
}

# 7d. producer staging order swapped
{
    W=$(mwork); two_open "$W/in.txt"
    mk_delta_report "$W/rawA.txt" "$L_A"
    mk_delta_report "$W/rawB.txt" "$L_B"
    reduce_round "$W/in.txt" "$W/fwd.txt" 2 "$MFMT" \
        "$PA@COMPLETE@$W/rawA.txt" "$PB@COMPLETE@$W/rawB.txt"
    reduce_round "$W/in.txt" "$W/rev.txt" 2 "$MFMT" \
        "$PB@COMPLETE@$W/rawB.txt" "$PA@COMPLETE@$W/rawA.txt"
    assert_eq "7d: staging order swapped — C1 keeps its concern" "C1" "$(id_for_text "$W/rev.txt" "$TA")"
    assert_eq "7d: staging order swapped — C2 keeps its concern" "C2" "$(id_for_text "$W/rev.txt" "$TB")"
    if [[ -s "$W/fwd.txt" ]] && cmp -s "$W/fwd.txt" "$W/rev.txt"; then
        pass "7d: reduce output is byte-identical under staging order swap"
    else
        fail "7d: reduce output differs under staging order swap (or was never written)"
    fi
}

# 7e. sibling reworded to sit very close to an existing entry
{
    W=$(mwork); two_open "$W/in.txt"
    mk_delta_report "$W/raw.txt" "$L_A" "$L_B" "$L_NEAR"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$MFMT" "$PA@COMPLETE@$W/raw.txt"
    assert_eq "7e: near-duplicate does not steal C1" "C1" "$(id_for_text "$W/out.txt" "$TA")"
    assert_eq "7e: C2 is unaffected by the near-duplicate" "C2" "$(id_for_text "$W/out.txt" "$TB")"
    NEAR_ID="$(id_for_text "$W/out.txt" "$TNEAR")"
    assert_eq "7e: the near-duplicate gets a brand-new ID, neither C1 nor C2" \
        "new" "$(id_class "$NEAR_ID" C1 C2)"
}

# ---------------------------------------------------------------------------
# 10a. Cross-producer fold on a declared reference ID (M1). Both producers
#      report the same concern verbatim with the same ref, so the fold is
#      unambiguous and PRODUCERS becomes the declared-order union.
# ---------------------------------------------------------------------------
{
    W=$(mwork)
    mk_ledger "$W/in.txt" "$MFMT" "$MSID" 1
    add_entry "$W/in.txt" C1 HIGH open 1 1 "$MSLOT" "$DA" "$PA" "$PA" - "$TA"
    mk_delta_report "$W/rawA.txt" "$(anchored HIGH C1 "$MP" "$MA" "$MCAT" "$TA")"
    mk_delta_report "$W/rawB.txt" "$(anchored MEDIUM C1 "$MP" "$MA" "$MCAT" "$TA")"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$MFMT" \
        "$PA@COMPLETE@$W/rawA.txt" "$PB@COMPLETE@$W/rawB.txt"

    assert_eq "10a: same-ref lines from 2 producers fold into one entry" \
        "1" "$(entry_count "$W/out.txt")"
    assert_contains "10a: PRODUCERS lists the codex producer" \
        "$PA" "$(entry_field "$W/out.txt" C1 $F_PRODUCERS)"
    assert_contains "10a: PRODUCERS lists the scanner producer" \
        "$PB" "$(entry_field "$W/out.txt" C1 $F_PRODUCERS)"
}

# ---------------------------------------------------------------------------
# 10b. Verbatim fold without any reference ID (M2), round 1.
# ---------------------------------------------------------------------------
{
    W=$(mwork)
    mk_ledger "$W/in.txt" "$MFMT" "$MSID" 1
    mk_delta_report "$W/rawA.txt" "$(anchored MEDIUM - "$MP" "$MA" "$MCAT" "$TA")"
    mk_delta_report "$W/rawB.txt" "$(anchored HIGH - "$MP" "$MA" "$MCAT" "$TA")"
    reduce_round "$W/in.txt" "$W/out.txt" 1 "$MFMT" \
        "$PA@COMPLETE@$W/rawA.txt" "$PB@COMPLETE@$W/rawB.txt"

    assert_eq "10b: verbatim duplicates fold into one entry" "1" "$(entry_count "$W/out.txt")"
    assert_eq "10b: folded severity is the max of both producers" \
        "HIGH" "$(entry_field "$W/out.txt" C1 $F_SEV)"
    assert_contains "10b: PRODUCERS lists both producers" "$PB" \
        "$(entry_field "$W/out.txt" C1 $F_PRODUCERS)"
}

# ---------------------------------------------------------------------------
# 10c. Positional fold (M3): round 1, one line per producer in one slot, no
#      reference and no DISCRIM match. Folds with merged-slot; the non-adopted
#      body survives verbatim as a #merged-alt record.
# ---------------------------------------------------------------------------
{
    W=$(mwork)
    mk_ledger "$W/in.txt" "$MFMT" "$MSID" 1
    mk_delta_report "$W/rawA.txt" "$(anchored MEDIUM - "$MP" "$MA" "$MCAT" "$TA")"
    mk_delta_report "$W/rawB.txt" "$(anchored HIGH - "$MP" "$MA" "$MCAT" "$TB")"
    reduce_round "$W/in.txt" "$W/m3.txt" 1 "$MFMT" \
        "$PA@COMPLETE@$W/rawA.txt" "$PB@COMPLETE@$W/rawB.txt"

    assert_eq "10c: one line per producer in one slot folds to one entry" \
        "1" "$(entry_count "$W/m3.txt")"
    assert_contains "10c: the positional fold is flagged merged-slot" \
        "merged-slot" "$(entry_field "$W/m3.txt" C1 $F_FLAGS)"
    assert_eq "10c: folded severity is the max" "HIGH" "$(entry_field "$W/m3.txt" C1 $F_SEV)"
    assert_eq "10c: TEXT comes from the declared-order first producer" \
        "$TA" "$(entry_text "$W/m3.txt" C1)"
    assert_contains "10c: the non-adopted body is kept as #merged-alt" \
        "#merged-alt|" "$(cat "$W/m3.txt" 2>/dev/null || true)"
    assert_contains "10c: the non-adopted body is kept verbatim" \
        "$TB" "$(grep -F '#merged-alt|' "$W/m3.txt" 2>/dev/null || true)"

    # 10e. The fold must not depend on staging order.
    reduce_round "$W/in.txt" "$W/m3rev.txt" 1 "$MFMT" \
        "$PB@COMPLETE@$W/rawB.txt" "$PA@COMPLETE@$W/rawA.txt"
    if [[ -s "$W/m3.txt" ]] && cmp -s "$W/m3.txt" "$W/m3rev.txt"; then
        pass "10e: fold result is byte-identical under staging order swap"
    else
        fail "10e: fold result differs under staging order swap (or was never written)"
    fi

    # -----------------------------------------------------------------------
    # 11. Next-round split of an M3 mis-merge: both producers now claim the same
    #     C<N>; the contested reference is rejected and only the frozen-DISCRIM
    #     side keeps the ID. Severity must not fall back below the folded max.
    # -----------------------------------------------------------------------
    mk_delta_report "$W/r2A.txt" "$(anchored MEDIUM C1 "$MP" "$MA" "$MCAT" "$TA")"
    mk_delta_report "$W/r2B.txt" "$(anchored HIGH C1 "$MP" "$MA" "$MCAT" "$TB")"
    reduce_round "$W/m3.txt" "$W/r2.txt" 2 "$MFMT" \
        "$PA@COMPLETE@$W/r2A.txt" "$PB@COMPLETE@$W/r2B.txt"

    assert_eq "11: contested ref splits the mis-merged entry into two" \
        "2" "$(entry_count "$W/r2.txt")"
    assert_eq "11: the frozen-DISCRIM side keeps C1" "C1" "$(id_for_text "$W/r2.txt" "$TA")"
    SPLIT_ID="$(id_for_text "$W/r2.txt" "$TB")"
    assert_eq "11: the other side gets a new ID, not C1" "new" "$(id_class "$SPLIT_ID" C1)"
    assert_eq "11: severity does not fall after the split" \
        "HIGH" "$(entry_field "$W/r2.txt" C1 $F_SEV)"
}

# ---------------------------------------------------------------------------
# 10d. M4 residue: one producer reporting two unrelated concerns in one slot.
#      Both entries survive and are flagged dup-suspect.
# ---------------------------------------------------------------------------
{
    W=$(mwork)
    mk_ledger "$W/in.txt" "$MFMT" "$MSID" 1
    mk_delta_report "$W/rawA.txt" \
        "$(anchored MEDIUM - "$MP" "$MA" "$MCAT" "$TA")" \
        "$(anchored HIGH - "$MP" "$MA" "$MCAT" "$TB")"
    reduce_round "$W/in.txt" "$W/out.txt" 1 "$MFMT" "$PA@COMPLETE@$W/rawA.txt"

    assert_eq "10d: M4 residue keeps both concerns" "2" "$(entry_count "$W/out.txt")"
    assert_contains "10d: M4 residue is flagged dup-suspect" \
        "dup-suspect" "$(cat "$W/out.txt" 2>/dev/null || true)"
    assert_eq "10d: M4 residue keeps each severity distinct" \
        "HIGH" "$(entry_field "$W/out.txt" "$(id_for_text "$W/out.txt" "$TB")" $F_SEV)"
}
