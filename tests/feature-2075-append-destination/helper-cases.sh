#!/usr/bin/env bash
# Tests: bin/find-tests-for-source.sh, bin/lib/test-route-destination.sh, bin/lib/test-dup-group.sh
# Tags: scope:issue-specific
# Part of tests/feature-2075-append-destination.sh (rules/coding/file-split.md).
# Cases H1-H18b (TL2): every assertion drives bin/find-tests-for-source.sh as a
# real subprocess against a throwaway fixture corpus handed over with --root, so
# the live tests/ corpus never takes part in a verdict.

# ── H1 exact match ──────────────────────────────────────────────────────────
R="$(make_repo)"
add_test_file "$R" "a.sh" "src/x.js,src/y.js" "scope:common" 20
run_helper --root "$R" --sources "src/x.js,src/y.js"
ROW="$(row_n "$OUT" 1)"
case_ran H1
assert_eq "H1 exit code" "0" "$RC"
assert_eq "H1 emits exactly one row" "1" "$(nrows "$OUT")"
assert_eq "H1 query column is the canonical set" "src/x.js,src/y.js" "$(col "$ROW" 1)"
assert_row "H1" "$ROW" "append" "exact" "tests/a.sh" "tests/a.sh"
assert_eq "H1 target_lines" "20" "$(col "$ROW" 5)"

# ── H2 superset candidate ───────────────────────────────────────────────────
R="$(make_repo)"
add_test_file "$R" "a.sh" "src/x.js,src/y.js,src/z.js" "scope:common" 20
run_helper --root "$R" --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
case_ran H2
assert_row "H2" "$ROW" "append" "superset" "tests/a.sh" "tests/a.sh"
assert_eq "H2 candidate carries extra_count 2" "2" "$(list_entry_field "$(col "$ROW" 6)" 1 3)"

# ── H3 partial overlap is NOT a candidate (no union of `# Tests:` sets) ─────
R="$(make_repo)"
add_test_file "$R" "a.sh" "src/x.js,src/z.js" "scope:common" 20
run_helper --root "$R" --sources "src/x.js,src/y.js"
ROW="$(row_n "$OUT" 1)"
case_ran H3
assert_row "H3" "$ROW" "new" "no-candidate" "-" "-"
assert_eq "H3 candidates stays empty" "-" "$(list_files "$(col "$ROW" 6)")"
assert_eq "H3 excluded stays empty" "-" "$(list_files "$(col "$ROW" 8)")"

# ── H4 the only candidate is at/over the HARD limit ────────────────────────
R="$(make_repo)"
add_test_file "$R" "big.sh" "src/x.js" "scope:common" 60
run_helper --root "$R" --hard-max 50 --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
case_ran H4
assert_row "H4" "$ROW" "new" "size-hard-limit" "-" "-"
assert_eq "H4 excluded holds the oversized candidate" "tests/big.sh" "$(list_files "$(col "$ROW" 8)")"
assert_eq "H4 excluded entry carries its line count" "60" "$(list_entry_field "$(col "$ROW" 8)" 1 2)"

# ── H5 oversized and surviving candidates side by side ─────────────────────
R="$(make_repo)"
add_test_file "$R" "big.sh" "src/x.js" "scope:common" 60
add_test_file "$R" "small.sh" "src/x.js" "scope:common" 20
run_helper --root "$R" --hard-max 50 --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
case_ran H5
assert_row "H5" "$ROW" "append" "exact" "tests/small.sh" "tests/small.sh"
assert_eq "H5 candidates keep both, ranked by lines" "tests/small.sh,tests/big.sh" "$(list_files "$(col "$ROW" 6)")"
assert_eq "H5 excluded holds only the oversized one" "tests/big.sh" "$(list_files "$(col "$ROW" 8)")"

# ── H6 ranking: exact > fewer extras > fewer lines > path ascending ────────
R="$(make_repo)"
add_test_file "$R" "exact.sh" "a.js" "scope:common" 40
add_test_file "$R" "e1a.sh" "a.js,b.js" "scope:common" 30
add_test_file "$R" "e1b.sh" "a.js,c.js" "scope:common" 20
add_test_file "$R" "e1c.sh" "a.js,d.js" "scope:common" 20
add_test_file "$R" "e2.sh" "a.js,b.js,c.js" "scope:common" 12
run_helper --root "$R" --sources "a.js"
ROW="$(row_n "$OUT" 1)"
case_ran H6
assert_eq "H6 candidate rank order" \
    "tests/exact.sh,tests/e1b.sh,tests/e1c.sh,tests/e1a.sh,tests/e2.sh" \
    "$(list_files "$(col "$ROW" 6)")"
assert_row "H6" "$ROW" "append" "exact" "tests/exact.sh" \
    "tests/exact.sh,tests/e1b.sh,tests/e1c.sh,tests/e1a.sh,tests/e2.sh"

# ── H7 test-file mode excludes the query file itself ───────────────────────
R="$(make_repo)"
add_test_file "$R" "self.sh" "src/x.js" "scope:common" 20
run_helper --root "$R" --test-file "tests/self.sh"
ROW="$(row_n "$OUT" 1)"
case_ran H7
assert_eq "H7 exit code" "0" "$RC"
assert_row "H7" "$ROW" "new" "no-candidate" "-" "-"
assert_eq "H7 the query file never lists itself" "-" "$(list_files "$(col "$ROW" 6)")"

# ── H8 test-file mode finds a different exact match (RT-1a's gap shape) ────
R="$(make_repo)"
add_test_file "$R" "self.sh" "src/x.js" "scope:common" 20
add_test_file "$R" "other.sh" "src/x.js" "scope:common" 30
run_helper --root "$R" --test-file "tests/self.sh"
ROW="$(row_n "$OUT" 1)"
case_ran H8
assert_row "H8" "$ROW" "append" "exact" "tests/other.sh" "tests/other.sh"

# ── H9 three queries, one corpus scan, rows in argument order ──────────────
R="$(make_repo)"
add_test_file "$R" "a.sh" "p.js" "scope:common" 20
add_test_file "$R" "b.sh" "q.js" "scope:common" 20
run_helper --root "$R" --sources "p.js" --sources "q.js" --sources "r.js"
case_ran H9
assert_eq "H9 one row per --sources" "3" "$(nrows "$OUT")"
assert_row "H9 row1" "$(row_n "$OUT" 1)" "append" "exact" "tests/a.sh" "tests/a.sh"
assert_row "H9 row2" "$(row_n "$OUT" 2)" "append" "exact" "tests/b.sh" "tests/b.sh"
assert_row "H9 row3" "$(row_n "$OUT" 3)" "new" "no-candidate" "-" "-"

# ── H10 TSV escaping round-trip: a comma inside a file name ────────────────
R="$(make_repo)"
add_test_file "$R" "we,ird.sh" "src/x.js" "scope:common" 20
run_helper --root "$R" --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
case_ran H10
assert_row "H10" "$ROW" "append" "exact" "tests/we,ird.sh" "tests/we,ird.sh"
assert_eq "H10 candidates decode through the double escape" "tests/we,ird.sh" \
    "$(list_files "$(col "$ROW" 6)")"
assert_eq "H10 inner element survives the double escape" "20" \
    "$(list_entry_field "$(col "$ROW" 6)" 1 2)"

# ── H11 canonicalization, query side ───────────────────────────────────────
R="$(make_repo)"
add_test_file "$R" "a.sh" "src/x.js" "scope:common" 20
run_helper --root "$R" --sources "./src/x.js"
ROW="$(row_n "$OUT" 1)"
case_ran H11
assert_row "H11" "$ROW" "append" "exact" "tests/a.sh" "tests/a.sh"
assert_eq "H11 query column drops the ./ prefix" "src/x.js" "$(col "$ROW" 1)"

# ── H11b canonicalization, CORPUS side (one-sided normalization fails here) ─
R="$(make_repo)"
add_test_file "$R" "a.sh" "./src/x.js" "scope:common" 20
run_helper --root "$R" --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
case_ran H11b
assert_row "H11b" "$ROW" "append" "exact" "tests/a.sh" "tests/a.sh"

# ── H11c order independence on the corpus side ─────────────────────────────
R="$(make_repo)"
add_test_file "$R" "a.sh" "b.js,a.js" "scope:common" 20
run_helper --root "$R" --sources "a.js,b.js"
ROW="$(row_n "$OUT" 1)"
case_ran H11c
assert_row "H11c" "$ROW" "append" "exact" "tests/a.sh" "tests/a.sh"

# ── H11d duplicate token inside the corpus header must not inflate extras ──
R="$(make_repo)"
add_test_file "$R" "a.sh" "a.js,a.js,b.js" "scope:common" 20
run_helper --root "$R" --sources "a.js,b.js"
ROW="$(row_n "$OUT" 1)"
case_ran H11d
assert_row "H11d" "$ROW" "append" "exact" "tests/a.sh" "tests/a.sh"
assert_eq "H11d extra_count is not inflated by the duplicate" "0" \
    "$(list_entry_field "$(col "$ROW" 6)" 1 3)"

# ── H11e query-side duplicates mixed with ./ ───────────────────────────────
R="$(make_repo)"
add_test_file "$R" "a.sh" "a.js,b.js" "scope:common" 20
run_helper --root "$R" --sources "./a.js,a.js,b.js"
ROW="$(row_n "$OUT" 1)"
case_ran H11e
assert_eq "H11e query column is deduplicated and sorted" "a.js,b.js" "$(col "$ROW" 1)"
assert_row "H11e" "$ROW" "append" "exact" "tests/a.sh" "tests/a.sh"

# ── H12 the built-in HARD default (500) is live without --hard-max ─────────
R="$(make_repo)"
add_test_file "$R" "big.sh" "src/x.js" "scope:common" 501
run_helper --root "$R" --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
case_ran H12
assert_row "H12" "$ROW" "new" "size-hard-limit" "-" "-"
assert_eq "H12 excluded holds the 501-line candidate" "tests/big.sh" \
    "$(list_files "$(col "$ROW" 8)")"

# ── H13 nested part files are outside the scan-range contract ──────────────
R="$(make_repo)"
add_nested_test_file "$R" "part" "bar.sh" "src/x.js"
run_helper --root "$R" --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
case_ran H13
assert_row "H13" "$ROW" "new" "no-candidate" "-" "-"

# ── H13b a nested part file handed in as --test-file is skipped, not failed ─
run_helper --root "$R" --test-file "tests/part/bar.sh"
ROW="$(row_n "$OUT" 1)"
case_ran H13b
assert_eq "H13b exit code stays 0" "0" "$RC"
assert_row "H13b" "$ROW" "skipped" "not-top-level" "-" "-"

# ── H13c the positive side of the same predicate ───────────────────────────
R="$(make_repo)"
add_test_file "$R" "foo.sh" "src/x.js" "scope:common" 20
run_helper --root "$R" --test-file "tests/foo.sh"
ROW="$(row_n "$OUT" 1)"
case_ran H13c
assert_eq "H13c exit code" "0" "$RC"
assert_row "H13c" "$ROW" "new" "no-candidate" "-" "-"

# ── H14a-d structural validation runs through tdg_classify, not the parser ──
for _pair in "H14a:no_tests_header" "H14b:duplicate_header" "H14c:late_header" "H14d:malformed_header"; do
    _id="${_pair%%:*}"
    _kind="${_pair#*:}"
    R="$(make_repo)"
    add_broken_test_file "$R" "broken.sh" "$_kind"
    run_helper --root "$R" --test-file "tests/broken.sh"
    ROW="$(row_n "$OUT" 1)"
    case_ran "$_id"
    assert_eq "$_id exit code stays 0" "0" "$RC"
    assert_row "$_id" "$ROW" "new" "query-unparsable:$_kind" "-" "-"
done

# ── H15 usage errors: exit 2 and not a single row on stdout ────────────────
R="$(make_repo)"
case_ran H15
run_helper --root "$R"
assert_eq "H15 no mode exits 2" "2" "$RC"
assert_eq "H15 no mode prints no row" "" "$OUT"
run_helper --root "$R" --sources "src/x.js" --test-file "tests/a.sh"
assert_eq "H15 both modes exit 2" "2" "$RC"
assert_eq "H15 both modes print no row" "" "$OUT"
run_helper --root "$R" --bogus
assert_eq "H15 unknown flag exits 2" "2" "$RC"
run_helper --root "$R" --sources ""
assert_eq "H15 empty query exits 2" "2" "$RC"
run_helper --root "$R" --sources "/abs/x.js"
assert_eq "H15 absolute source token exits 2" "2" "$RC"
run_helper --root "$R" --sources "src/x.js" --hard-max "abc"
assert_eq "H15 non-numeric --hard-max exits 2" "2" "$RC"

# ── H16 environment error is fail-closed, never a CWD fallback ─────────────
case_ran H16
run_helper --root "$NEUTRAL_DIR" --sources "src/x.js"
assert_eq "H16 non-repo --root exits 3" "3" "$RC"
assert_eq "H16 non-repo --root prints no row" "" "$OUT"

# ── H17 the viable column is a predicate independent of the verdict ────────
R="$(make_repo)"
add_test_file "$R" "a.sh" "src/x.js" "scope:common" 20
run_helper --root "$R" --hard-max 100 --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
V="$(list_files "$(col "$ROW" 7)")"
case_ran H17
assert_eq "H17 loose limit yields a viable candidate" "tests/a.sh" "$V"
if [[ "$V" != "-" ]]; then
    assert_eq "H17 a non-empty viable column implies verdict append" "append" "$(col "$ROW" 2)"
else
    fail "H17 fixture produced no viable candidate — the implication was never exercised"
fi
run_helper --root "$R" --hard-max 10 --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
V="$(list_files "$(col "$ROW" 7)")"
assert_eq "H17 tight limit empties the viable column" "-" "$V"
if [[ "$V" == "-" ]]; then
    assert_eq "H17 an empty viable column is the only way to reach verdict new" "new" "$(col "$ROW" 2)"
else
    fail "H17 fixture kept a viable candidate under the tight limit — the implication was never exercised"
fi

# ── H18a a size-hard-limit tag with nothing to back it up ──────────────────
R="$(make_repo)"
add_test_file "$R" "newfile.sh" "src/x.js" "scope:common, dup-group-keep:size-hard-limit" 20
add_test_file "$R" "unrelated.sh" "src/z.js" "scope:common" 20
run_helper --root "$R" --test-file "tests/newfile.sh"
ROW="$(row_n "$OUT" 1)"
case_ran H18a
assert_row "H18a" "$ROW" "new" "no-candidate" "-" "-"
assert_eq "H18a excluded is empty, so the tag's claim has no evidence" "-" \
    "$(list_files "$(col "$ROW" 8)")"

# ── H18b the same tag, corroborated by the row ─────────────────────────────
R="$(make_repo)"
add_test_file "$R" "newfile.sh" "src/x.js" "scope:common, dup-group-keep:size-hard-limit" 20
add_test_file "$R" "big.sh" "src/x.js" "scope:common" 60
run_helper --root "$R" --hard-max 50 --test-file "tests/newfile.sh"
ROW="$(row_n "$OUT" 1)"
case_ran H18b
assert_row "H18b" "$ROW" "new" "size-hard-limit" "-" "-"
assert_eq "H18b excluded names the oversized candidate that backs the tag" "tests/big.sh" \
    "$(list_files "$(col "$ROW" 8)")"

grp_done "helper-cases.sh"
