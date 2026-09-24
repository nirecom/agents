# tests/bin-concern-ledger-reducer/bind.sh
# Tests: bin/lib/concern-ledger.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/concern-ledger
# Tags: concern-ledger, reducer, bind, merge, completeness, table-driven, scope:common, pwsh-not-required
# Sourced by tests/bin-concern-ledger-reducer.sh.
# Detail-plan Test plan cases 4, 5, 8, 9 — cross-round binding (cl_bind).
# Core contract: only B1 (declared reference ID) and B2 (frozen DISCRIM) may bind an
# existing ID. No positional / cardinality path exists, so a lone delta line sitting in
# an occupied slot must NOT inherit that slot's ID.

echo ""
echo "--- reducer 4/5/8/9: cross-round binding tiers ---"

SID="bindsess"
FMT="review-security-shared"
PROD="review-code-codex"

BP="bin/run-codex-review-loop"
BA1="cl_finalize"
BA2="cl_begin_cycle"
BCAT="contract"
BSLOT1=$(cl cl_slot "$BP" "$BA1" "$BCAT")
BSLOT2=$(cl cl_slot "$BP" "$BA2" "$BCAT")

BT1="finalize must not delete the live ledger in terminal mode"
BT2="begin-cycle must not drop new concerns at round 1"
BD1=$(cl cl_discrim "$BT1")
BD2=$(cl cl_discrim "$BT2")

# bind_ledger <file> — one open C1 (slot 1, text BT1) at round 1.
bind_ledger() {
    mk_ledger "$1" "$FMT" "$SID" 1
    add_entry "$1" C1 HIGH open 1 1 "$BSLOT1" "$BD1" "$PROD" "$PROD" - "$BT1"
}

bwork() { mktemp -d "$TMPDIR_BASE/bind-XXXXXX"; }

# ---------------------------------------------------------------------------
# 4. Tier priority: B1 beats B2, and a confirmed pair leaves the candidate pool.
#    A delta line declaring C2 while its text matches C1's frozen DISCRIM must
#    bind C2 (not C1); C1 then has no delta line left and resolves.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    mk_ledger "$W/in.txt" "$FMT" "$SID" 1
    add_entry "$W/in.txt" C1 HIGH open 1 1 "$BSLOT1" "$BD1" "$PROD" "$PROD" - "$BT1"
    add_entry "$W/in.txt" C2 MEDIUM open 1 1 "$BSLOT2" "$BD2" "$PROD" "$PROD" - "$BT2"
    mk_delta_report "$W/raw.txt" "$(anchored HIGH C2 "$BP" "$BA1" "$BCAT" "$BT1")"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$FMT" \
        "$PROD@COMPLETE@$W/raw.txt" "security-scanner@COMPLETE@$NONE_REPORT"

    assert_eq "4: B1 wins over B2 — declared C2 stays open" \
        "open" "$(entry_field "$W/out.txt" C2 $F_STATE)"
    assert_eq "4: B1 pair removed from pool — C1 not re-bound by B2" \
        "resolved" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "4: B1 binding advances LAST_ROUND of the declared ID" \
        "2" "$(entry_field "$W/out.txt" C2 $F_LAST)"
    assert_eq "4: no new ID is minted when B1 binds" \
        "2" "$(entry_count "$W/out.txt")"
}

# ---------------------------------------------------------------------------
# 4b. A clean 1:1 slot alignment must NOT bind (no positional path exists).
#     Under the rejected positional design C1<-BT3 and C2<-BT4 would have bound.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    BT3="finalize retries must be bounded"
    BT4="cycle archive path must stay stable"
    mk_ledger "$W/in.txt" "$FMT" "$SID" 1
    add_entry "$W/in.txt" C1 HIGH open 1 1 "$BSLOT1" "$BD1" "$PROD" "$PROD" - "$BT1"
    add_entry "$W/in.txt" C2 MEDIUM open 1 1 "$BSLOT2" "$BD2" "$PROD" "$PROD" - "$BT2"
    mk_delta_report "$W/raw.txt" \
        "$(anchored HIGH - "$BP" "$BA1" "$BCAT" "$BT3")" \
        "$(anchored MEDIUM - "$BP" "$BA2" "$BCAT" "$BT4")"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$FMT" "$PROD@COMPLETE@$W/raw.txt"

    assert_eq "4b: 1:1 slot alignment does not bind C1" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "4b: 1:1 slot alignment does not bind C2" \
        "open" "$(entry_field "$W/out.txt" C2 $F_STATE)"
    assert_eq "4b: C1 keeps its own TEXT (no positional inheritance)" \
        "$BT1" "$(entry_text "$W/out.txt" C1)"
    assert_eq "4b: C2 keeps its own TEXT (no positional inheritance)" \
        "$BT2" "$(entry_text "$W/out.txt" C2)"
    assert_eq "4b: the unbound line gets a brand-new ID, never C1/C2" \
        "new" "$(id_class "$(id_for_text "$W/out.txt" "$BT3")" C1 C2)"
    assert_eq "4b: four entries after two unbound lines land" \
        "4" "$(entry_count "$W/out.txt")"
    assert_contains "4b: the stranded prior entry is flagged ambiguous" \
        "ambiguous" "$(entry_field "$W/out.txt" C1 $F_FLAGS)"
}

# ---------------------------------------------------------------------------
# 5a. Reference to a non-existent ID is rejected, then demoted to B2.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    bind_ledger "$W/in.txt"
    mk_delta_report "$W/raw.txt" "$(anchored HIGH C99 "$BP" "$BA1" "$BCAT" "$BT1")"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$FMT" "$PROD@COMPLETE@$W/raw.txt"

    assert_eq "5a: unknown ref falls back to B2 and re-binds C1" \
        "2" "$(entry_field "$W/out.txt" C1 $F_LAST)"
    assert_eq "5a: no C99 is minted from a rejected reference" \
        "1" "$(entry_count "$W/out.txt")"
    assert_contains "5a: rejection is recorded as ref-rejected" \
        "ref-rejected" "$(cat "$W/out.txt" 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# 5b. Two lines in the same round claiming the same ID: reference rejected for
#     both; only the frozen-DISCRIM match keeps C1, the other gets a new ID.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    BT5="finalize must reject a tmp file without the terminator"
    bind_ledger "$W/in.txt"
    mk_delta_report "$W/raw.txt" \
        "$(anchored HIGH C1 "$BP" "$BA1" "$BCAT" "$BT1")" \
        "$(anchored MEDIUM C1 "$BP" "$BA1" "$BCAT" "$BT5")"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$FMT" "$PROD@COMPLETE@$W/raw.txt"

    assert_eq "5b: contested ref — DISCRIM match keeps C1" \
        "C1" "$(id_for_text "$W/out.txt" "$BT1")"
    assert_eq "5b: contested ref — the other claimant gets a new ID, not C1" \
        "new" "$(id_class "$(id_for_text "$W/out.txt" "$BT5")" C1)"
    assert_contains "5b: contested ref is recorded as ref-rejected" \
        "ref-rejected" "$(cat "$W/out.txt" 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# 5c. Category mismatch rejects the reference (no mis-inheritance).
#     v2 rows carry no CATEGORY column, so the outcome is pinned, not storage.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    BT6="the ledger lock must be released on failure"
    bind_ledger "$W/in.txt"
    mk_delta_report "$W/raw.txt" "$(anchored HIGH C1 "$BP" "$BA1" "security" "$BT6")"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$FMT" "$PROD@COMPLETE@$W/raw.txt"

    assert_eq "5c: category mismatch leaves C1's TEXT untouched" \
        "$BT1" "$(entry_text "$W/out.txt" C1)"
    assert_eq "5c: category-mismatched line gets a new ID, not C1" \
        "new" "$(id_class "$(id_for_text "$W/out.txt" "$BT6")" C1)"
    assert_contains "5c: rejection is recorded as ref-rejected" \
        "ref-rejected" "$(cat "$W/out.txt" 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# 5d. Valid reference with a changed slot binds and is flagged 'moved'.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    BT7="terminal finalize must keep the live ledger on disk"
    bind_ledger "$W/in.txt"
    mk_delta_report "$W/raw.txt" "$(anchored HIGH C1 "$BP" "$BA2" "$BCAT" "$BT7")"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$FMT" "$PROD@COMPLETE@$W/raw.txt"

    assert_eq "5d: valid ref binds across a slot change" \
        "1" "$(entry_count "$W/out.txt")"
    assert_eq "5d: bound entry carries the round" \
        "2" "$(entry_field "$W/out.txt" C1 $F_LAST)"
    assert_contains "5d: slot change is flagged moved" \
        "moved" "$(entry_field "$W/out.txt" C1 $F_FLAGS)"
    assert_eq_nz "5d: SLOT is updated to the new anchor's slot" \
        "$BSLOT2" "$(entry_field "$W/out.txt" C1 $F_SLOT)"
}

# ---------------------------------------------------------------------------
# 4c. Direct probe of cl_bind's return contract: 'ledger-id<TAB>delta-index<TAB>tier'.
#     Asserted index-agnostically — only the ID and the tier are contractual here.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    bind_ledger "$W/in.txt"
    mk_delta_report "$W/raw.txt" "$(anchored HIGH C1 "$BP" "$BA1" "$BCAT" "$BT1")"
    cl cl_parse_anchored "$W/raw.txt" "$PROD" "$W/delta.txt" >/dev/null 2>&1
    BIND_OUT="$(cl cl_bind "$W/in.txt" "$W/delta.txt" 2>/dev/null | head -n1)"
    assert_match "4c: a declared reference is reported as tier B1" \
        '^C1'$'\t''[0-9]+'$'\t''B1$' "$BIND_OUT"

    mk_delta_report "$W/raw2.txt" "$(anchored HIGH - "$BP" "$BA1" "$BCAT" "$BT1")"
    cl cl_parse_anchored "$W/raw2.txt" "$PROD" "$W/delta2.txt" >/dev/null 2>&1
    BIND_OUT2="$(cl cl_bind "$W/in.txt" "$W/delta2.txt" 2>/dev/null | head -n1)"
    assert_match "4c: a verbatim match without a reference is reported as tier B2" \
        '^C1'$'\t''[0-9]+'$'\t''B2$' "$BIND_OUT2"
}

# ---------------------------------------------------------------------------
# 8. Narrowing pin — exactly one unbound line in an occupied slot.
#    The old positional design would have handed C1 to it. Expected: C1 stays
#    open + ambiguous, the line gets a new ID, and round 3 recovers via B1.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    BT8="ledger writes must take the mkdir lock"
    bind_ledger "$W/in.txt"
    mk_delta_report "$W/raw2.txt" "$(anchored HIGH - "$BP" "$BA1" "$BCAT" "$BT8")"
    reduce_round "$W/in.txt" "$W/r2.txt" 2 "$FMT" "$PROD@COMPLETE@$W/raw2.txt"

    NEW_ID="$(id_for_text "$W/r2.txt" "$BT8")"
    assert_eq "8: the single unbound line gets a new ID instead of taking C1" \
        "new" "$(id_class "$NEW_ID" C1)"
    assert_eq "8: C1 stays open (no positional hand-over)" \
        "open" "$(entry_field "$W/r2.txt" C1 $F_STATE)"
    assert_contains "8: C1 is flagged ambiguous" \
        "ambiguous" "$(entry_field "$W/r2.txt" C1 $F_FLAGS)"
    assert_eq "8: C1's TEXT is unchanged" "$BT1" "$(entry_text "$W/r2.txt" C1)"

    # Round 3: the new entry declares its own ID (B1) and C1 is declared resolved
    # by absence — the slot no longer holds an unbound line, so C1 may transition.
    mk_delta_report "$W/raw3.txt" "$(anchored HIGH "$NEW_ID" "$BP" "$BA1" "$BCAT" "$BT8")"
    reduce_round "$W/r2.txt" "$W/r3.txt" 3 "$FMT" \
        "$PROD@COMPLETE@$W/raw3.txt" "security-scanner@COMPLETE@$NONE_REPORT"

    assert_eq "8: round 3 — B1 keeps the new entry on its own ID" \
        "$BT8" "$(entry_text "$W/r3.txt" "$NEW_ID")"
    assert_eq "8: round 3 — new entry stays open" \
        "open" "$(entry_field "$W/r3.txt" "$NEW_ID" $F_STATE)"
    assert_eq "8: round 3 — ambiguity lifted, absent C1 resolves" \
        "resolved" "$(entry_field "$W/r3.txt" C1 $F_STATE)"
    assert_eq "8: round 3 — still exactly two entries" "2" "$(entry_count "$W/r3.txt")"
}

# ---------------------------------------------------------------------------
# 9. B3 fail-CLOSED — an unbound line in a slot blocks that slot's open entry
#    from resolving, while an unrelated slot resolves normally. The flag drops
#    once the next round supplies a reference (self-healing).
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    BT9="cl_write_json must escape control characters"
    mk_ledger "$W/in.txt" "$FMT" "$SID" 1
    add_entry "$W/in.txt" C1 HIGH open 1 1 "$BSLOT1" "$BD1" "$PROD" "$PROD" - "$BT1"
    add_entry "$W/in.txt" C2 MEDIUM open 1 1 "$BSLOT2" "$BD2" "$PROD" "$PROD" - "$BT2"
    mk_delta_report "$W/raw2.txt" "$(anchored HIGH - "$BP" "$BA1" "$BCAT" "$BT9")"
    reduce_round "$W/in.txt" "$W/r2.txt" 2 "$FMT" \
        "$PROD@COMPLETE@$W/raw2.txt" "security-scanner@COMPLETE@$NONE_REPORT"

    assert_eq "9: unbound line in the slot keeps C1 open" \
        "open" "$(entry_field "$W/r2.txt" C1 $F_STATE)"
    assert_contains "9: C1 gains the ambiguous flag" \
        "ambiguous" "$(entry_field "$W/r2.txt" C1 $F_FLAGS)"
    assert_eq "9: an unrelated absent entry still resolves (gate is per-slot)" \
        "resolved" "$(entry_field "$W/r2.txt" C2 $F_STATE)"

    NEW9="$(id_for_text "$W/r2.txt" "$BT9")"
    mk_delta_report "$W/raw3.txt" \
        "$(anchored HIGH C1 "$BP" "$BA1" "$BCAT" "$BT1")" \
        "$(anchored HIGH "$NEW9" "$BP" "$BA1" "$BCAT" "$BT9")"
    reduce_round "$W/r2.txt" "$W/r3.txt" 3 "$FMT" "$PROD@COMPLETE@$W/raw3.txt"

    assert_eq "9: round 3 — B1 re-binds C1" \
        "3" "$(entry_field "$W/r3.txt" C1 $F_LAST)"
    assert_eq "9: round 3 — ambiguous flag is dropped once refs arrive" \
        "absent" "$(flag_state "$W/r3.txt" C1 ambiguous)"
    assert_eq "9: round 3 — no extra ID is minted" "3" "$(entry_count "$W/r3.txt")"
}
