# tests/bin-concern-ledger-reducer/cycle-migration-static.sh
# Tests: bin/lib/concern-ledger.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/concern-ledger
# Tags: concern-ledger, reducer, bind, merge, completeness, table-driven, scope:common, pwsh-not-required
# Sourced by tests/bin-concern-ledger-reducer.sh.
# Detail-plan Test plan cases 18, 20, 21 — cycle boundary (cl_begin_cycle), the static
# ban on similarity matching and positional binding, and v1 ledger migration.
#
# Assumed signature (documented so /write-code can align or the case can be adjusted):
#   cl_begin_cycle <ledger-path> <format> <round>

echo ""
echo "--- reducer 18/20/21: cycle boundary, static bans, v1 migration ---"

YSID="cyclesess"
YPROD="review-code-codex"
YP="bin/lib/concern-ledger.sh"
YA="cl_begin_cycle"
YCAT="contract"
YSLOT=$(cl cl_slot "$YP" "$YA" "$YCAT")
YX1="begin-cycle must archive the previous cycle before rebuilding"
YX2="begin-cycle must bump the cycle counter in the header"
YD1=$(cl cl_discrim "$YX1")

ywork() { mktemp -d "$TMPDIR_BASE/cycle-XXXXXX"; }

# ---------------------------------------------------------------------------
# 18a. Plan formats archive the live ledger and rebuild an empty ID space.
# ---------------------------------------------------------------------------
{
    W=$(ywork)
    L="$W/$YSID-detail-plan-concern-ledger.txt"
    mk_ledger "$L" "detail-plan" "$YSID" 1
    add_entry "$L" C1 HIGH open 1 2 "$YSLOT" "$YD1" codex codex - "$YX1"
    cl cl_begin_cycle "$L" "detail-plan" 1 >/dev/null 2>&1

    ARCHIVE="$W/$YSID-detail-plan-concern-ledger-cycle1.txt"
    if [[ -f "$ARCHIVE" ]]; then
        pass "18a: plan-format round 1 archives the live ledger to -cycle1.txt"
    else
        fail "18a: expected archive at $ARCHIVE (present: $(ls "$W" 2>/dev/null | tr '\n' ' '))"
    fi
    assert_contains "18a: the archive keeps the previous cycle's entry" \
        "$YX1" "$(cat "$ARCHIVE" 2>/dev/null || true)"
    assert_eq "18a: the rebuilt ledger has no entries" "0" "$(entry_count "$L")"
    assert_eq "18a: the rebuilt ledger is a v2 header at the next cycle" \
        "#concern-ledger-v2|detail-plan|$YSID|cycle=2" "$(head -n1 "$L" 2>/dev/null || true)"

    # 18c: round 1 admission is open — new concerns are minted, not discarded.
    mk_codex_output "$W/raw1.txt" "C1. [MEDIUM] $YX2"
    reduce_round "$L" "$W/out.txt" 1 "detail-plan" "codex@COMPLETE@$W/raw1.txt@numbered"
    assert_eq "18c: plan-format round 1 admits new concerns" \
        "1" "$(entry_count "$W/out.txt")"
    assert_eq "18c: the new concern keeps its text" \
        "$YX2" "$(entry_text "$W/out.txt" C1)"
}

# ---------------------------------------------------------------------------
# 18b. review-security-shared carries the ledger over and bumps the cycle.
# ---------------------------------------------------------------------------
{
    W=$(ywork)
    L="$W/$YSID-review-security-shared-concern-ledger.txt"
    mk_ledger "$L" "review-security-shared" "$YSID" 1
    add_entry "$L" C1 HIGH open 1 2 "$YSLOT" "$YD1" "$YPROD" "$YPROD" - "$YX1"
    cl cl_begin_cycle "$L" "review-security-shared" 1 >/dev/null 2>&1

    # Carry-over is a "nothing changed" outcome, so the three properties are
    # asserted as one composite value — a no-op implementation cannot satisfy it.
    CARRY_SUMMARY="entries=$(entry_count "$L") id=$(id_for_text "$L" "$YX1")"
    CARRY_SUMMARY="$CARRY_SUMMARY header=$(head -n1 "$L" 2>/dev/null || true)"
    if [[ -f "$W/$YSID-review-security-shared-concern-ledger-cycle1.txt" ]]; then
        CARRY_SUMMARY="$CARRY_SUMMARY archive=present"
    else
        CARRY_SUMMARY="$CARRY_SUMMARY archive=absent"
    fi
    assert_eq "18b: shared ledger carries over, bumps the cycle, and is not archived" \
        "entries=1 id=C1 header=#concern-ledger-v2|review-security-shared|$YSID|cycle=2 archive=absent" \
        "$CARRY_SUMMARY"

    # 18c: a new concern at round 1 is numbered next, not discarded.
    mk_delta_report "$W/raw.txt" \
        "$(anchored HIGH C1 "$YP" "$YA" "$YCAT" "$YX1")" \
        "$(anchored MEDIUM - "$YP" "$YA" "$YCAT" "$YX2")"
    reduce_round "$L" "$W/out.txt" 1 "review-security-shared" "$YPROD@COMPLETE@$W/raw.txt"
    assert_eq "18c: the carried ID survives the new cycle's round 1" \
        "C1" "$(id_for_text "$W/out.txt" "$YX1")"
    NEWY="$(id_for_text "$W/out.txt" "$YX2")"
    assert_eq "18c: the new concern is numbered fresh, not discarded or reused" \
        "new" "$(id_class "$NEWY" C1)"
}

# ---------------------------------------------------------------------------
# 20. Static bans. (a) no similarity scoring anywhere in the library;
#     (b) slot-bucket cardinality lives only inside cl_merge_producers.
# ---------------------------------------------------------------------------
# fn_body <file> <name> — the source lines of one shell function.
fn_body() {
    awk -v fn="$2" '
        index($0, fn "()") == 1 { inb = 1 }
        inb { print }
        inb && /^\}/ { exit }
    ' "$1" 2>/dev/null
}

if [[ -f "$LIB" ]]; then
    LIB_SRC="$(cat "$LIB")"
    # Separator is ';' — the patterns themselves contain '|' (regex alternation),
    # so '|' cannot double as the table's field separator.
    while IFS=';' read -r name pattern want; do
        [[ -z "${name// }" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="$(trim "$name")"; pattern="$(trim "$pattern")"; want="$(trim "$want")"
        if printf '%s\n' "$LIB_SRC" | grep -Eiq -- "$pattern"; then
            got="present"
        else
            got="absent"
        fi
        assert_eq "20a: $name" "$want" "$got"
    done <<'TABLE'
no-threshold-constant   ; CL_MATCH_MIN|MATCH_THRESHOLD    ; absent
no-similarity-helper    ; similarity|levenshtein|jaccard  ; absent
no-fuzzy-matching       ; fuzzy|best_match                ; absent
no-match-scoring        ; match_score|score_match|_score= ; absent
TABLE

    BIND_BODY="$(fn_body "$LIB" cl_bind)"
    MERGE_BODY="$(fn_body "$LIB" cl_merge_producers)"
    CARD_RE='(-eq[[:space:]]+1|==[[:space:]]*1|count)'

    if [[ -n "$BIND_BODY" ]]; then
        pass "20b: cl_bind's body was located for inspection"
    else
        fail "20b: could not locate cl_bind's body in $LIB"
    fi
    if [[ -n "$MERGE_BODY" ]]; then
        pass "20b: cl_merge_producers's body was located for inspection"
    else
        fail "20b: could not locate cl_merge_producers's body in $LIB"
    fi

    BIND_CARD="$(printf '%s\n' "$BIND_BODY" | grep -Ei -- 'slot' | grep -Eic -- "$CARD_RE" || true)"
    MERGE_CARD="$(printf '%s\n' "$MERGE_BODY" | grep -Ei -- 'slot' | grep -Eic -- "$CARD_RE" || true)"
    assert_eq "20b: cl_bind has no slot-bucket cardinality test" "0" "${BIND_CARD:-0}"
    if [[ "${MERGE_CARD:-0}" -gt 0 ]]; then
        pass "20b: cl_merge_producers owns the slot-bucket cardinality test"
    else
        fail "20b: no slot-bucket cardinality test found in cl_merge_producers (the 20b probe would be vacuous)"
    fi
else
    fail "20: $LIB is missing — static bans cannot be verified"
fi

# ---------------------------------------------------------------------------
# 21. v1 ledger migration (Migration section, all cases): read both versions,
#     always write v2, promote v1 rows conservatively.
# ---------------------------------------------------------------------------
{
    W=$(ywork)
    V1T="the retry path never releases the lock"
    printf 'C1|HIGH|%s\n' "$V1T" > "$W/v1.txt"
    printf 'C2|LOW|%s\n' "a second v1 concern" >> "$W/v1.txt"

    # Direct read: v1 rows are promoted to 11-field v2 rows in memory.
    V1READ="$(cl cl_read_v1_or_v2 "$W/v1.txt" 2>/dev/null | grep -m1 '^C1|' || true)"
    assert_eq "21: a promoted v1 row has 11 fields" \
        "11" "$(printf '%s' "$V1READ" | awk -F'|' 'NF { print NF } END { if (NR == 0) print 0 }')"
    assert_eq "21: a promoted v1 row keeps its TEXT last" \
        "$V1T" "$(printf '%s' "$V1READ" | cut -d'|' -f11-)"
    assert_eq "21: a promoted v1 row is open" \
        "open" "$(printf '%s' "$V1READ" | cut -d'|' -f3)"
    assert_eq "21: a promoted v1 row has ORIGIN=unknown" \
        "unknown" "$(printf '%s' "$V1READ" | cut -d'|' -f8)"

    # Round 3 over a v1 ledger: write-back is v2 and the promotion is applied.
    mk_delta_report "$W/raw.txt" "$(anchored HIGH C1 "$YP" "$YA" "$YCAT" "$V1T")"
    reduce_round "$W/v1.txt" "$W/out.txt" 3 "review-security-shared" \
        "$YPROD@COMPLETE@$W/raw.txt" "security-scanner@COMPLETE@$NONE_REPORT"

    assert_contains "21: the write-back is always v2" \
        "#concern-ledger-v2|" "$(head -n1 "$W/out.txt" 2>/dev/null || true)"
    assert_eq "21: v1 IDs are preserved across the upgrade" "C1" "$(id_for_text "$W/out.txt" "$V1T")"
    assert_eq "21: promoted FIRST_ROUND is 1" "1" "$(entry_field "$W/out.txt" C1 $F_FIRST)"
    assert_eq_nz "21: promoted SLOT is the body slot of the text" \
        "$(cl cl_slot_body "a second v1 concern")" "$(entry_field "$W/out.txt" C2 $F_SLOT)"
    assert_eq_nz "21: promoted DISCRIM is the text discriminator" \
        "$(cl cl_discrim "a second v1 concern")" "$(entry_field "$W/out.txt" C2 $F_DISCRIM)"
    assert_contains "21: promoted rows are flagged no-anchor" \
        "no-anchor" "$(entry_field "$W/out.txt" C2 $F_FLAGS)"
    assert_eq "21: promoted LAST_ROUND is the previous round" \
        "2" "$(entry_field "$W/out.txt" C2 $F_LAST)"
    assert_eq "21: a no-anchor entry is never resolved by absence" \
        "open" "$(entry_field "$W/out.txt" C2 $F_STATE)"
    assert_contains "21: the absent no-anchor entry is carried as stale" \
        "stale" "$(entry_field "$W/out.txt" C2 $F_FLAGS)"
}
