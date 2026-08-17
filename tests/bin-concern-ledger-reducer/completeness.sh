# tests/bin-concern-ledger-reducer/completeness.sh
# Tests: bin/lib/concern-ledger.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/concern-ledger
# Tags: concern-ledger, reducer, bind, merge, completeness, table-driven, scope:common, pwsh-not-required
# Sourced by tests/bin-concern-ledger-reducer.sh.
# Detail-plan Test plan cases 13, 14, 15 — the 3-valued completeness signal
# (COMPLETE > PARTIAL > ABSENT), the anchored parse label, and the fact that the
# parse label never demotes the plan-side Cn-reference path.

echo ""
echo "--- reducer 13/14/15: completeness gate and parse labels ---"

CSID="compsess"
CFMT="review-security-shared"
CPA="review-code-codex"
CPB="security-scanner"

CP="bin/review-code-ledger"
CA="render_prior"
CCAT="correctness"
CSLOT=$(cl cl_slot "$CP" "$CA" "$CCAT")
CX1="render-prior must emit the C<N> of every open entry"
CD1=$(cl cl_discrim "$CX1")
CX2="render-prior must not print resolved entries"

cwork() { mktemp -d "$TMPDIR_BASE/comp-XXXXXX"; }

# comp_ledger <file> — one open entry, round 1, in slot CSLOT.
comp_ledger() {
    mk_ledger "$1" "$CFMT" "$CSID" 1
    add_entry "$1" C1 HIGH open 1 1 "$CSLOT" "$CD1" "$CPA" "$CPA" - "$CX1"
}

OK_LINE="$(anchored MEDIUM - "$CP" "cl_stage" "$CCAT" "$CX2")"
BAD_LINE="[HIGH] render-prior drops the severity column"

# ---------------------------------------------------------------------------
# 13. The completeness gate: absence may only resolve when every producer of the
#     round reported completely. Each row perturbs one producer's signal.
#     want = the STATE of the absent open entry C1.
# ---------------------------------------------------------------------------
while IFS='|' read -r name specs want; do
    [[ -z "${name// }" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; want="$(trim "$want")"; specs="$(trim "$specs")"
    W=$(cwork)
    comp_ledger "$W/in.txt"
    mk_delta_report "$W/other.txt" "$OK_LINE"
    SPEC_ARR=()
    for tok in $specs; do
        case "$tok" in
            A-COMPLETE) SPEC_ARR+=("$CPA@COMPLETE@$W/other.txt") ;;
            A-PARTIAL)  SPEC_ARR+=("$CPA@PARTIAL@$W/other.txt") ;;
            A-ABSENT)   SPEC_ARR+=("$CPA@ABSENT@$W/other.txt") ;;
            B-COMPLETE) SPEC_ARR+=("$CPB@COMPLETE@$NONE_REPORT") ;;
            B-PARTIAL)  SPEC_ARR+=("$CPB@PARTIAL@$NONE_REPORT") ;;
            B-ABSENT)   SPEC_ARR+=("$CPB@ABSENT@$NONE_REPORT") ;;
            *) fail "13: unknown spec token '$tok' in row $name" ;;
        esac
    done
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$CFMT" "${SPEC_ARR[@]}"
    assert_eq "13: $name" "$want" "$(entry_field "$W/out.txt" C1 $F_STATE)"
done <<'TABLE'
both-complete-resolves      | A-COMPLETE B-COMPLETE | resolved
one-partial-blocks          | A-PARTIAL  B-COMPLETE | open
other-partial-blocks        | A-COMPLETE B-PARTIAL  | open
one-absent-blocks           | A-ABSENT   B-COMPLETE | open
other-absent-blocks         | A-COMPLETE B-ABSENT   | open
producer-not-staged-blocks  | A-COMPLETE            | open
TABLE

# The blocked carry-over must be visible as 'stale', not silently open.
{
    W=$(cwork)
    comp_ledger "$W/in.txt"
    mk_delta_report "$W/other.txt" "$OK_LINE"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$CFMT" \
        "$CPA@PARTIAL@$W/other.txt" "$CPB@COMPLETE@$NONE_REPORT"
    assert_contains "13: incomplete round marks the carried entry stale" \
        "stale" "$(entry_field "$W/out.txt" C1 $F_FLAGS)"
}

# The two gates are ANDed: completeness alone is not sufficient when the slot
# still holds an unbound delta line, and an unambiguous slot is not sufficient
# when a producer was incomplete.
{
    W=$(cwork)
    comp_ledger "$W/in.txt"
    mk_delta_report "$W/amb.txt" "$(anchored HIGH - "$CP" "$CA" "$CCAT" "unrelated concern in the same slot")"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$CFMT" \
        "$CPA@COMPLETE@$W/amb.txt" "$CPB@COMPLETE@$NONE_REPORT"
    assert_eq "13: COMPLETE round is still blocked by an ambiguous slot" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_contains "13: the ambiguity is recorded on the blocked entry" \
        "ambiguous" "$(entry_field "$W/out.txt" C1 $F_FLAGS)"
}

# ---------------------------------------------------------------------------
# 14. Parse label produced by cl_parse_anchored (a-d).
#     Tokens: OK = well-formed delta line, BAD = concern-like but malformed,
#     NONE = explicit '(none)', EMPTY = no body lines at all.
# ---------------------------------------------------------------------------
while IFS='|' read -r name tokens want; do
    [[ -z "${name// }" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; want="$(trim "$want")"; tokens="$(trim "$tokens")"
    W=$(cwork)
    LINES=()
    for tok in $tokens; do
        case "$tok" in
            OK)    LINES+=("$OK_LINE") ;;
            BAD)   LINES+=("$BAD_LINE") ;;
            NONE)  LINES+=("(none)") ;;
            EMPTY) ;;
            *) fail "14: unknown token '$tok' in row $name" ;;
        esac
    done
    if [[ ${#LINES[@]} -eq 0 ]]; then
        mk_delta_report "$W/raw.txt"
    else
        mk_delta_report "$W/raw.txt" "${LINES[@]}"
    fi
    got=$(cl cl_parse_anchored "$W/raw.txt" "$CPA" "$W/norm.txt" 2>/dev/null | head -n1)
    assert_eq "14: $name" "$want" "$(trim "${got:-}")"
done <<'TABLE'
well-formed-is-complete       | OK OK    | COMPLETE
explicit-none-is-complete     | NONE     | COMPLETE
one-malformed-line-is-partial | OK BAD   | PARTIAL
only-malformed-is-partial     | BAD      | PARTIAL
silent-empty-is-partial       | EMPTY    | PARTIAL
TABLE

# 14a. The malformed line survives verbatim as an #unparsed record, and the
# round's effective label is the min of exec (PERFORMED -> COMPLETE) and parse.
{
    W=$(cwork)
    comp_ledger "$W/in.txt"
    mk_delta_report "$W/raw.txt" "$OK_LINE" "$BAD_LINE"
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$CFMT" \
        "$CPA@COMPLETE@$W/raw.txt" "$CPB@COMPLETE@$NONE_REPORT"

    assert_contains "14a: the malformed line is kept as an #unparsed record" \
        "#unparsed|" "$(cat "$W/out.txt" 2>/dev/null || true)"
    assert_contains "14a: the malformed line is kept verbatim" \
        "$BAD_LINE" "$(grep -F '#unparsed|' "$W/out.txt" 2>/dev/null || true)"
    assert_contains "14d: min(exec, parse) demotion is recorded" \
        "delta-parse-incomplete" "$(cat "$W/out.txt" "$LAST_REDUCE_ERR" 2>/dev/null || true)"
    assert_eq "14e: any PARTIAL keeps absent open entries unresolved" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
}

# ---------------------------------------------------------------------------
# 15. Scope of the parse label — the plan-side Cn-reference adapter never
#     demotes the tally, no matter how deviant the reviewer output is.
# ---------------------------------------------------------------------------
{
    W=$(cwork)
    PFMT="detail-plan"
    mk_ledger "$W/in.txt" "$PFMT" "$CSID" 1
    add_entry "$W/in.txt" C1 HIGH open 1 1 "$CSLOT" "$CD1" codex codex - "$CX1"
    add_entry "$W/in.txt" C2 MEDIUM open 1 1 "$(cl cl_slot_body "$CX2")" \
        "$(cl cl_discrim "$CX2")" codex codex - "$CX2"

    {
        printf '<!-- begin-codex-output -->\n'
        printf 'C1: unresolved — still missing the C<N> prefix\n'
        printf '<!-- end-codex-output -->\n'
    } > "$W/clean.txt"
    {
        printf '<!-- begin-codex-output -->\n'
        printf 'C1: unresolved — still missing the C<N> prefix\n'
        printf '%s\n' "$BAD_LINE"
        printf '<!-- end-codex-output -->\n'
    } > "$W/deviant.txt"

    reduce_round "$W/in.txt" "$W/clean-out.txt" 2 "$PFMT" "codex@COMPLETE@$W/clean.txt@cnref"
    CLEAN_TALLY="$LAST_TALLY"
    reduce_round "$W/in.txt" "$W/dev-out.txt" 2 "$PFMT" "codex@COMPLETE@$W/deviant.txt@cnref"
    DEV_TALLY="$LAST_TALLY"
    DEV_ERR="$(cat "$LAST_REDUCE_ERR" 2>/dev/null || true)"

    assert_match "15: the plan-side tally has the documented shape (baseline is meaningful)" \
        '^open_high=[0-9]+ open_medium=[0-9]+ open_low=[0-9]+ reopened=[0-9]+ resolved=[0-9]+$' \
        "$CLEAN_TALLY"
    assert_eq_nz "15: a deviant line does not change the plan-side tally" \
        "$CLEAN_TALLY" "$DEV_TALLY"
    assert_eq "15: a deviant line does not block plan-side resolution" \
        "resolved" "$(entry_field "$W/dev-out.txt" C2 $F_STATE)"
    assert_match "15: the deviant line still produces a stderr diagnostic" \
        '.' "$DEV_ERR"
}
