# tests/bin/bin-concern-ledger-reducer/completeness.sh
# Tests: bin/lib/concern-ledger.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/concern-ledger
# Tags: concern-ledger, reducer, bind, merge, completeness, table-driven, scope:common, pwsh-not-required
# Sourced by tests/bin/bin-concern-ledger-reducer.sh.
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
producer-not-staged-blocks  | A-COMPLETE            | resolved
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
        '^open_high=[0-9]+ open_medium=[0-9]+ open_low=[0-9]+ reopened=[0-9]+ resolved=[0-9]+ rejected=[0-9]+$' \
        "$CLEAN_TALLY"
    assert_eq_nz "15: a deviant line does not change the plan-side tally" \
        "$CLEAN_TALLY" "$DEV_TALLY"
    assert_eq "15: a deviant line does not block plan-side resolution" \
        "resolved" "$(entry_field "$W/dev-out.txt" C2 $F_STATE)"
    assert_match "15: the deviant line still produces a stderr diagnostic" \
        '.' "$DEV_ERR"
}

# ===========================================================================
# Group B — per-entry provenance gate (change 2, #2344)
# FP_SCANNER_REQUIRED (env var) controls whether security-scanner must be
# COMPLETE in the round's staging regardless of the entry's PRODUCERS field.
# Tests that are expected RED until /write-code implements change 2 are
# labelled "(RED until change 2)" in their comments.
# ===========================================================================

echo ""
echo "--- reducer Group B: per-entry provenance gate (change 2) ---"

BSID="b-prov"
BFMT="review-security-shared"
BPA="review-code-codex"
BPB="security-scanner"
BP="bin/security-review-ledger"
BA="per_entry_check"
BCAT="security"
BSLOT=$(cl cl_slot "$BP" "$BA" "$BCAT")
BX1="security concern owned by single producer"
BD1=$(cl cl_discrim "$BX1")

bwork() { mktemp -d "$TMPDIR_BASE/bprov-XXXXXX"; }

# b_ledger <file> <producers> — single open entry C1 with the given PRODUCERS column.
b_ledger() {
    mk_ledger "$1" "$BFMT" "$BSID" 1
    add_entry "$1" C1 HIGH open 1 1 "$BSLOT" "$BD1" "$BPA" "$2" - "$BX1"
}

# ---------------------------------------------------------------------------
# B1: codex-only concern (PRODUCERS=codex) + FP_SCANNER_REQUIRED=0 → resolved.
# Current code: all_allowed_complete=0 (scanner not staged) → open.
# Assertion is RED until change 2 implements per-entry check.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    b_ledger "$W/in.txt" "$BPA"
    export FP_SCANNER_REQUIRED=0
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$BFMT" \
        "$BPA@COMPLETE@$NONE_REPORT"
    unset FP_SCANNER_REQUIRED
    assert_eq "B1: codex-only + FP_SCANNER_REQUIRED=0 resolves" \
        "resolved" "$(entry_field "$W/out.txt" C1 $F_STATE)"
}

# ---------------------------------------------------------------------------
# B2: FP_SCANNER_REQUIRED=1 + scanner absent from staging → open+stale.
# Current code: all_allowed_complete=0 (scanner not staged) → same outcome.
# Regression: change 2 must not accidentally resolve when scanner is absent.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    b_ledger "$W/in.txt" "$BPA"
    export FP_SCANNER_REQUIRED=1
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$BFMT" \
        "$BPA@COMPLETE@$NONE_REPORT"
    unset FP_SCANNER_REQUIRED
    assert_eq "B2: FP_SCANNER_REQUIRED=1 scanner absent → open" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "B2: FP_SCANNER_REQUIRED=1 scanner absent → stale flag" \
        "has" "$(flag_state "$W/out.txt" C1 stale)"
}

# ---------------------------------------------------------------------------
# B3: PRODUCERS=scanner-only, FP_SCANNER_REQUIRED=1, scanner COMPLETE in fcomp
# → resolved. Scanner is in PRODUCERS (fail-closed satisfied) and COMPLETE.
# Current code: all_allowed_complete=0 (codex not staged) → blocked.
# Assertion is RED until change 2 implements per-entry check.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    b_ledger "$W/in.txt" "$BPB"
    export FP_SCANNER_REQUIRED=1
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$BFMT" \
        "$BPB@COMPLETE@$NONE_REPORT"
    unset FP_SCANNER_REQUIRED
    assert_eq "B3: scanner-only PRODUCERS + FP_SCANNER_REQUIRED=1 + scanner COMPLETE → resolved" \
        "resolved" "$(entry_field "$W/out.txt" C1 $F_STATE)"
}

# ---------------------------------------------------------------------------
# B4: malformed PRODUCERS → blocked+stale.
# With both allowed producers staging COMPLETE the format-level all_allowed_complete
# gate passes in current code and the entry is resolved; only per-entry parsing
# can catch the malformed value. Each sub-case asserts open+stale.
# All sub-cases are RED until change 2.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    b_ledger "$W/in.txt" ",${BPA}"
    export FP_SCANNER_REQUIRED=0
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$BFMT" \
        "$BPA@COMPLETE@$NONE_REPORT" \
        "$BPB@COMPLETE@$NONE_REPORT"
    unset FP_SCANNER_REQUIRED
    assert_eq "B4: leading-comma PRODUCERS → open" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "B4: leading-comma PRODUCERS → stale" \
        "has" "$(flag_state "$W/out.txt" C1 stale)"
}
{
    W=$(bwork)
    b_ledger "$W/in.txt" "${BPA},"
    export FP_SCANNER_REQUIRED=0
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$BFMT" \
        "$BPA@COMPLETE@$NONE_REPORT" \
        "$BPB@COMPLETE@$NONE_REPORT"
    unset FP_SCANNER_REQUIRED
    assert_eq "B4: trailing-comma PRODUCERS → open" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "B4: trailing-comma PRODUCERS → stale" \
        "has" "$(flag_state "$W/out.txt" C1 stale)"
}
{
    W=$(bwork)
    b_ledger "$W/in.txt" "${BPA},,${BPB}"
    export FP_SCANNER_REQUIRED=0
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$BFMT" \
        "$BPA@COMPLETE@$NONE_REPORT" \
        "$BPB@COMPLETE@$NONE_REPORT"
    unset FP_SCANNER_REQUIRED
    assert_eq "B4: double-comma PRODUCERS → open" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "B4: double-comma PRODUCERS → stale" \
        "has" "$(flag_state "$W/out.txt" C1 stale)"
}
{
    W=$(bwork)
    b_ledger "$W/in.txt" "${BPA} ${BPB}"
    export FP_SCANNER_REQUIRED=0
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$BFMT" \
        "$BPA@COMPLETE@$NONE_REPORT" \
        "$BPB@COMPLETE@$NONE_REPORT"
    unset FP_SCANNER_REQUIRED
    assert_eq "B4: space-separated PRODUCERS → open" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "B4: space-separated PRODUCERS → stale" \
        "has" "$(flag_state "$W/out.txt" C1 stale)"
}
{
    W=$(bwork)
    B4_TAB_PROD="${BPA}"$'\t'"${BPB}"
    b_ledger "$W/in.txt" "$B4_TAB_PROD"
    export FP_SCANNER_REQUIRED=0
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$BFMT" \
        "$BPA@COMPLETE@$NONE_REPORT" \
        "$BPB@COMPLETE@$NONE_REPORT"
    unset FP_SCANNER_REQUIRED
    assert_eq "B4: tab-mixed PRODUCERS → open" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "B4: tab-mixed PRODUCERS → stale" \
        "has" "$(flag_state "$W/out.txt" C1 stale)"
}

# ---------------------------------------------------------------------------
# B5: PRODUCERS="-" (empty/absent) → blocked+stale.
# With both allowed producers staging COMPLETE, current code resolves.
# Per-entry check must reject empty PRODUCERS. RED until change 2.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    b_ledger "$W/in.txt" "-"
    export FP_SCANNER_REQUIRED=0
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$BFMT" \
        "$BPA@COMPLETE@$NONE_REPORT" \
        "$BPB@COMPLETE@$NONE_REPORT"
    unset FP_SCANNER_REQUIRED
    assert_eq "B5: empty PRODUCERS → open" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "B5: empty PRODUCERS → stale" \
        "has" "$(flag_state "$W/out.txt" C1 stale)"
}

# ---------------------------------------------------------------------------
# B6: allowlist-外 PRODUCERS (unknown-tool) → blocked+stale.
# With both allowed producers staging COMPLETE, current code resolves.
# Per-entry check must reject producers not in cl_allowed_producers.
# RED until change 2.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    b_ledger "$W/in.txt" "unknown-tool"
    export FP_SCANNER_REQUIRED=0
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$BFMT" \
        "$BPA@COMPLETE@$NONE_REPORT" \
        "$BPB@COMPLETE@$NONE_REPORT"
    unset FP_SCANNER_REQUIRED
    assert_eq "B6: allowlist-外 PRODUCERS → open" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "B6: allowlist-外 PRODUCERS → stale" \
        "has" "$(flag_state "$W/out.txt" C1 stale)"
}

# ---------------------------------------------------------------------------
# B7: co-owned (codex+scanner) PRODUCERS + codex COMPLETE only + FP_SCANNER_REQUIRED=1
# → open+stale. Scanner is listed in PRODUCERS and required by FP_SCANNER_REQUIRED,
# but not staged. Current code: all_allowed_complete=0 → same outcome.
# Regression test for co-owned entry with missing producer.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    b_ledger "$W/in.txt" "${BPA},${BPB}"
    export FP_SCANNER_REQUIRED=1
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$BFMT" \
        "$BPA@COMPLETE@$NONE_REPORT"
    unset FP_SCANNER_REQUIRED
    assert_eq "B7: co-owned codex-only staged + FP_SCANNER_REQUIRED=1 → open" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "B7: co-owned codex-only staged + FP_SCANNER_REQUIRED=1 → stale" \
        "has" "$(flag_state "$W/out.txt" C1 stale)"
}

# ---------------------------------------------------------------------------
# B8: co-owned (codex+scanner) PRODUCERS + both COMPLETE + FP_SCANNER_REQUIRED=1
# → resolved. Current code: all_allowed_complete=1 → same outcome.
# Verifies co-owned entry resolves when all producers satisfy per-entry check.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    b_ledger "$W/in.txt" "${BPA},${BPB}"
    export FP_SCANNER_REQUIRED=1
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$BFMT" \
        "$BPA@COMPLETE@$NONE_REPORT" \
        "$BPB@COMPLETE@$NONE_REPORT"
    unset FP_SCANNER_REQUIRED
    assert_eq "B8: co-owned both COMPLETE + FP_SCANNER_REQUIRED=1 → resolved" \
        "resolved" "$(entry_field "$W/out.txt" C1 $F_STATE)"
}

# ---------------------------------------------------------------------------
# B9: codex PARTIAL → all absent entries stale (L281 round-completeness regression).
# cl_round_complete_for returns 1 when a staged producer is not COMPLETE, so
# complete=0 → blocked → stale. Both current and change 2 agree.
# ---------------------------------------------------------------------------
{
    W=$(bwork)
    b_ledger "$W/in.txt" "$BPA"
    export FP_SCANNER_REQUIRED=0
    reduce_round "$W/in.txt" "$W/out.txt" 2 "$BFMT" \
        "$BPA@PARTIAL@$NONE_REPORT"
    unset FP_SCANNER_REQUIRED
    assert_eq "B9: codex PARTIAL → open" \
        "open" "$(entry_field "$W/out.txt" C1 $F_STATE)"
    assert_eq "B9: codex PARTIAL → stale" \
        "has" "$(flag_state "$W/out.txt" C1 stale)"
}
