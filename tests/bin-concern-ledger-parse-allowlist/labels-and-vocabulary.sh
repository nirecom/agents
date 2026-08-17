# tests/bin-concern-ledger-parse-allowlist/labels-and-vocabulary.sh
# Tests: bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/render.sh, bin/lib/concern-ledger.sh, bin/concern-ledger
# Tags: concern-ledger, parser, allowlist, severity, category, table-driven, mutation-probe, scope:common, pwsh-not-required

# ---------------------------------------------------------------------------
# 4. Section-level labels, through the real CLI and its staging file.
# ---------------------------------------------------------------------------
echo ""
echo "--- parse 4: section-level COMPLETE / PARTIAL / ABSENT ---"

new_env
NONE_R="$TMPDIR_BASE/none.txt"
mk_report "$NONE_R" "(none)"
stage "$NONE_R" 1 pnone
NONE_DF="$(delta_file "$PLANS" "$SID" 1 pnone)"
assert_eq "4: an explicit '(none)' body is COMPLETE with no records" \
    "COMPLETE recs=0" "$(staging_field "$NONE_DF" 5) recs=$(rec_count "$NONE_DF")"

EMPTY_R="$TMPDIR_BASE/emptysec.txt"
mk_report "$EMPTY_R" ""
stage "$EMPTY_R" 1 pempty
EMPTY_DF="$(delta_file "$PLANS" "$SID" 1 pempty)"
assert_eq "4: a Concern Delta section with an empty body is PARTIAL" \
    "PARTIAL recs=0" "$(staging_field "$EMPTY_DF" 5) recs=$(rec_count "$EMPTY_DF")"

# No section at all and no bullets anywhere: ABSENT. Written directly rather
# than through mk_report, which always emits the section header.
NOSEC="$TMPDIR_BASE/nosection.txt"
printf '# Report\n\nnothing structured here at all.\n' > "$NOSEC"
stage "$NOSEC" 1 nosec
NOSEC_DF="$(delta_file "$PLANS" "$SID" 1 nosec)"
assert_eq "4: a report with neither a section nor a bullet is ABSENT" \
    "ABSENT" "$(staging_field "$NOSEC_DF" 5)"
assert_eq "4: an ABSENT parse yields an ABSENT completeness" \
    "ABSENT" "$(staging_field "$NOSEC_DF" 3)"

# One good bullet plus one bad one: the round is PARTIAL and the good one is
# still admitted. A parser that dropped the section on one bad line would lose
# findings silently.
MIXED="$TMPDIR_BASE/mixed.txt"
mk_report "$MIXED" \
    "- [HIGH] - | a/b.sh#fn | correctness | the good one survives the bad one" \
    "- [CRITICAL] - | a/b.sh#fn | correctness | the bad one is quarantined"
stage "$MIXED" 1 mixed
MIXED_DF="$(delta_file "$PLANS" "$SID" 1 mixed)"
assert_eq "4: one bad bullet makes the round PARTIAL without discarding the good one" \
    "PARTIAL recs=1 unparsed=1" \
    "$(staging_field "$MIXED_DF" 5) recs=$(rec_count "$MIXED_DF") unparsed=$(unparsed_count "$MIXED_DF")"

# ---------------------------------------------------------------------------
# 5. The vocabulary constant itself. A category silently dropped from the list
#    stops cl_bind's rename probe from recognising a re-filed concern.
# ---------------------------------------------------------------------------
echo ""
echo "--- parse 5: the declared category vocabulary ---"

MISSING_CAT=""
for CAT in correctness security contract performance style docs test; do
    case " $VOCAB " in *" $CAT "*) ;; *) MISSING_CAT="${MISSING_CAT:+$MISSING_CAT }$CAT" ;; esac
done
assert_eq "5: every category the reviewer prompt names is in CL_CATEGORY_VOCAB" "" "$MISSING_CAT"

PROMPTED="$(grep -c 'one of correctness, security, contract, performance, style, docs, test' \
    "$AGENTS_ROOT/bin/review-code-codex" 2>/dev/null || true)"
assert_eq "5: the reviewer prompt still teaches that category list" "1" "$PROMPTED"

# ---------------------------------------------------------------------------
# 6. The exec label is the other half of the completeness projection, and the
#    lower of the two must win (_cl_label_min). Config-dependent branch: every
#    value is set explicitly, never inherited from the report's own header.
# ---------------------------------------------------------------------------
echo ""
echo "--- parse 6: exec label x parse label -> completeness ---"

new_env
EXECR="$TMPDIR_BASE/execr.txt"
mk_report "$EXECR" "- [HIGH] - | a/b.sh#fn | correctness | an exec-label probe"
while IFS='~' read -r exlabel want; do
    exlabel="$(strip "$exlabel")"
    [ -z "$exlabel" ] && continue
    bash "$CLI" stage --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" \
        --round 1 --producer "ex$exlabel" --exec "$exlabel" --from-report "$EXECR" >/dev/null 2>&1
    EDF="$(delta_file "$PLANS" "$SID" 1 "ex$exlabel")"
    assert_eq "6: exec label $exlabel over a COMPLETE parse yields $(strip "$want")" \
        "$(strip "$want")" "$(staging_field "$EDF" 3)"
done <<'TABLE'
PERFORMED ~ COMPLETE
TRUNCATED ~ PARTIAL
SKIPPED   ~ ABSENT
FAILED    ~ ABSENT
TABLE

