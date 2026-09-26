#!/usr/bin/env bash
# Tests: bin/find-tests-for-source.sh, bin/lib/test-route-destination.sh
# Tags: scope:issue-specific
# Part of tests/bin/feature-2075-append-destination.sh (rules/coding/file-split.md).
# Cases B/G/V/E/I (TL2): boundary values (B) and CLI-surface robustness
# (G root-detect, V injection, E malformed input, I idempotency) against the
# same target/harness as helper-cases.sh's H family — split out here only
# because the combined file crosses the HARD line limit; the functional cut is
# "core routing contract" (H) vs. "edge/robustness inputs" (this file).

# run_helper_at <cwd> <args...> — run_helper's sibling for the cases that must
# NOT hand over --root. Same capture contract (OUT / ERR / RC).
run_helper_at() {
    local cwd="$1"; shift
    local outf errf
    outf="$(mktemp)"; errf="$(mktemp)"
    (
        cd "$cwd" || exit 2
        unset GIT_DIR GIT_WORK_TREE
        run_with_timeout bash "$HELPER" "$@"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
    rm -f "$outf" "$errf"
}

case_begin "edge-series" "bin/find-tests-for-source.sh"

# ── B1 one line under the limit still appends ──────────────────────────────
R="$(make_repo)"
add_test_file "$R" "bin/edge.sh" "src/x.js" "scope:common" 499
run_helper --root "$R" --hard-max 500 --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
case_ran B1
assert_eq "B1 exit code" "0" "$RC"
assert_row "B1" "$ROW" "append" "exact" "tests/bin/edge.sh" "tests/bin/edge.sh"
assert_eq "B1 target_lines is the 499-line count" "499" "$(col "$ROW" 5)"
assert_eq "B1 nothing was excluded at 499" "-" "$(list_files "$(col "$ROW" 8)")"

# ── B2 exactly at the limit still appends (the `<=` vs `<` discriminator) ──
# rules/coding/file-split.md: HARD is `>500` lines, so a candidate at exactly
# 500 is still compliant and must remain viable — only a candidate that
# EXCEEDS the limit (see H12 at 501) is excluded.
R="$(make_repo)"
add_test_file "$R" "bin/edge.sh" "src/x.js" "scope:common" 500
run_helper --root "$R" --hard-max 500 --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
case_ran B2
assert_eq "B2 exit code" "0" "$RC"
assert_row "B2" "$ROW" "append" "exact" "tests/bin/edge.sh" "tests/bin/edge.sh"
assert_eq "B2 target_lines is exactly 500" "500" "$(col "$ROW" 5)"
assert_eq "B2 nothing was excluded at exactly 500" "-" "$(list_files "$(col "$ROW" 8)")"

# ── B3 the same pair against the BUILT-IN default, with no --hard-max ──────
# H12 pins 501 (over); this pins 499 (under). Only both together prove 500.
R="$(make_repo)"
add_test_file "$R" "bin/edge.sh" "src/x.js" "scope:common" 499
run_helper --root "$R" --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
case_ran B3
assert_row "B3" "$ROW" "append" "exact" "tests/bin/edge.sh" "tests/bin/edge.sh"
assert_eq "B3 the helper never invents a split verdict for a near-limit target" \
    "append" "$(col "$ROW" 2)"

# ── B4 a broken corpus file alongside a valid candidate ────────────────────
# Every shape below names src/x.js in its (broken) header, so a helper reading
# headers with grep instead of tdg_classify would rank it as a rival candidate.
case_ran B4
for _bkind in duplicate_header late_header malformed_header; do
    R="$(make_repo)"
    add_test_file "$R" "bin/good.sh" "src/x.js" "scope:common" 20
    add_broken_test_file "$R" "broken.sh" "$_bkind"
    run_helper --root "$R" --sources "src/x.js"
    ROW="$(row_n "$OUT" 1)"
    assert_eq "B4[$_bkind] exit code" "0" "$RC"
    assert_row "B4[$_bkind]" "$ROW" "append" "exact" "tests/bin/good.sh" "tests/bin/good.sh"
    assert_eq "B4[$_bkind] the broken file never joins the candidate list" \
        "tests/bin/good.sh" "$(list_files "$(col "$ROW" 6)")"
    assert_eq "B4[$_bkind] and it is not silently parked in excluded either" \
        "-" "$(list_files "$(col "$ROW" 8)")"
done

# ── B5 the broken file is the ONLY file naming the query set ───────────────
case_ran B5
for _bkind in duplicate_header late_header malformed_header; do
    R="$(make_repo)"
    add_broken_test_file "$R" "broken.sh" "$_bkind"
    run_helper --root "$R" --sources "src/x.js"
    ROW="$(row_n "$OUT" 1)"
    assert_eq "B5[$_bkind] exit code" "0" "$RC"
    assert_row "B5[$_bkind]" "$ROW" "new" "no-candidate" "-" "-"
    assert_eq "B5[$_bkind] candidates is empty" "-" "$(list_files "$(col "$ROW" 6)")"
    assert_eq "B5[$_bkind] excluded is empty, so no tag claim could rest on it" \
        "-" "$(list_files "$(col "$ROW" 8)")"
done

# ── B6 --hard-max INT_MAX: a valid candidate is still reachable ────────────
R="$(make_repo)"
add_test_file "$R" "bin/a.sh" "src/x.js" "scope:common" 20
run_helper --root "$R" --hard-max 2147483647 --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
case_ran B6
assert_eq "B6 exit code" "0" "$RC"
assert_row "B6" "$ROW" "append" "exact" "tests/bin/a.sh" "tests/bin/a.sh"

# ── B7 very long source token does not crash the helper ────────────────────
R="$(make_repo)"
add_test_file "$R" "bin/a.sh" "src/x.js" "scope:common" 20
_b7_src="src/"
for _b7i in {1..241}; do _b7_src="${_b7_src}x"; done
_b7_src="${_b7_src}.js"
run_helper --root "$R" --sources "$_b7_src"
case_ran B7
if [[ "$RC" -eq 0 || "$RC" -eq 2 ]]; then
    pass "B7 very long source token exits $RC without crashing"
else
    fail "B7 very long source token exited $RC — expected 0 or 2"
fi

# ── G1 source mode resolves the repo root from the CWD ─────────────────────
R="$(make_repo)"
add_test_file "$R" "bin/a.sh" "src/x.js" "scope:common" 20
run_helper_at "$R" --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
case_ran G1
assert_eq "G1 exit code with --root omitted" "0" "$RC"
assert_row "G1" "$ROW" "append" "exact" "tests/bin/a.sh" "tests/bin/a.sh"

# ── G2 test-file mode, from a SUBDIRECTORY (git root, not the CWD) ─────────
add_test_file "$R" "bin/self.sh" "src/x.js" "scope:common" 30
run_helper_at "$R/tests" --test-file "tests/bin/self.sh"
ROW="$(row_n "$OUT" 1)"
case_ran G2
assert_eq "G2 exit code from a subdirectory" "0" "$RC"
assert_row "G2" "$ROW" "append" "exact" "tests/bin/a.sh" "tests/bin/a.sh"
assert_eq "G2 the path is still reported relative to the git root" "tests/bin/a.sh" \
    "$(dcol "$ROW" 4)"

# ── V1 embedded traversal is rejected, not normalized away ─────────────────
R="$(make_repo)"
add_test_file "$R" "bin/a.sh" "src/x.js" "scope:common" 20
case_ran V1
for _v1 in "src/../x.js" "./../x.js" "src/../../etc/passwd"; do
    run_helper --root "$R" --sources "$_v1"
    assert_eq "V1 [$_v1] exits 2" "2" "$RC"
    assert_eq "V1 [$_v1] prints no row" "" "$OUT"
done

# ── V2 shell metacharacters never reach a shell ────────────────────────────
# The payloads try to create INJECTED inside the fixture repo. A token that
# survives to an unquoted expansion anywhere in the helper would leave the file
# behind even if the row itself looked harmless, so the marker is the assertion.
case_ran V2
V2_MARKER="$R/INJECTED"
for _v2 in 'src/x.js; touch INJECTED' 'src/x.js$(touch INJECTED)' 'src/x.js`touch INJECTED`' '$(touch INJECTED)'; do
    run_helper --root "$R" --sources "$_v2"
    assert_eq "V2 [$_v2] exits 2" "2" "$RC"
    assert_eq "V2 [$_v2] prints no row" "" "$OUT"
done
if [[ -e "$V2_MARKER" ]]; then
    fail "V2 an injection payload created $V2_MARKER — a query token reached a shell"
else
    pass "V2 no injection payload created a marker file"
fi

# ── E1 repeated --test-file: one row each, in order, each self-excluding ───
R="$(make_repo)"
add_test_file "$R" "bin/self.sh" "src/x.js" "scope:common" 20
add_test_file "$R" "bin/other.sh" "src/x.js" "scope:common" 30
run_helper --root "$R" --test-file "tests/bin/self.sh" --test-file "tests/bin/other.sh"
case_ran E1
assert_eq "E1 one row per --test-file" "2" "$(nrows "$OUT")"
assert_row "E1 row1" "$(row_n "$OUT" 1)" "append" "exact" "tests/bin/other.sh" "tests/bin/other.sh"
assert_row "E1 row2" "$(row_n "$OUT" 2)" "append" "exact" "tests/bin/self.sh" "tests/bin/self.sh"

# ── E2 a --test-file that does not exist ───────────────────────────────────
# The plan fixes no verdict name for this input, so the assertion is the
# contract that holds either way: no crash, and never an append target for a
# file whose `# Tests:` set could not be read.
case_ran E2
run_helper --root "$R" --test-file "tests/bin/nope.sh"
if [[ "$RC" == "0" || "$RC" == "2" ]]; then
    pass "E2 a nonexistent --test-file is a handled input (rc $RC)"
else
    fail "E2 a nonexistent --test-file produced rc $RC — neither a row nor a usage error"
fi
assert_no_append() {
    local label="$1" out="$2"
    if [[ -z "$out" ]]; then pass "$label (no row emitted)"; return 0; fi
    if [[ "$(col "$(row_n "$out" 1)" 2)" == "append" ]]; then
        fail "$label — an unreadable query yielded an append target"
    else
        pass "$label"
    fi
}
assert_no_append "E2 an unreadable query never yields append" "$OUT"

# ── E3 a --test-file that exists but cannot be read ────────────────────────
# cycle2-C6 gap: on Windows/NTFS and some Docker volumes chmod 000 is silently
# ignored; E3 auto-skips there and the unreadable-input path is a known gap.
case_ran E3
E3F="$R/tests/bin/locked.sh"
add_test_file "$R" "bin/locked.sh" "src/x.js" "scope:common" 20
chmod 000 "$E3F" 2>/dev/null || true
if [[ -r "$E3F" ]]; then
    skip "E3 this filesystem ignores chmod 000 — unreadable-input path not exercised"
else
    run_helper --root "$R" --test-file "tests/bin/locked.sh"
    if [[ "$RC" == "0" || "$RC" == "2" ]]; then
        pass "E3 an unreadable --test-file is a handled input (rc $RC)"
    else
        fail "E3 an unreadable --test-file produced rc $RC"
    fi
    assert_no_append "E3 an unreadable query never yields append" "$OUT"
fi
chmod u+rw "$E3F" 2>/dev/null || true

# ── E4 empty CSV elements in --sources ─────────────────────────────────────
case_ran E4
for _e4 in "src/x.js,,src/y.js" ",src/x.js" "src/x.js," "," "   "; do
    run_helper --root "$R" --sources "$_e4"
    assert_eq "E4 [$_e4] exits 2" "2" "$RC"
    assert_eq "E4 [$_e4] prints no row" "" "$OUT"
done

# ── E5 --hard-max at zero, negative and far above every candidate ──────────
R="$(make_repo)"
add_test_file "$R" "bin/a.sh" "src/x.js" "scope:common" 20
case_ran E5
run_helper --root "$R" --hard-max 0 --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
assert_eq "E5 --hard-max 0 exit code" "0" "$RC"
assert_row "E5 zero" "$ROW" "new" "size-hard-limit" "-" "-"
assert_eq "E5 --hard-max 0 excludes every candidate" "tests/bin/a.sh" \
    "$(list_files "$(col "$ROW" 8)")"
run_helper --root "$R" --hard-max "-1" --sources "src/x.js"
assert_eq "E5 a negative --hard-max is a usage error" "2" "$RC"
assert_eq "E5 a negative --hard-max prints no row" "" "$OUT"
run_helper --root "$R" --hard-max 999999 --sources "src/x.js"
ROW="$(row_n "$OUT" 1)"
assert_eq "E5 an oversized --hard-max exit code" "0" "$RC"
assert_row "E5 oversized" "$ROW" "append" "exact" "tests/bin/a.sh" "tests/bin/a.sh"

# ── E6 exit-3 when the tests/ directory is absent (C5/#2290) ───────────────
R="$(make_repo)"
rm -rf "$R/tests"
run_helper --root "$R" --sources "src/x.js"
case_ran E6
assert_eq "E6 missing tests/ dir exits 3" "3" "$RC"
assert_eq "E6 missing tests/ dir prints no row" "" "$OUT"
if printf '%s\n' "$ERR" | grep -q 'tests'; then
    pass "E6 error message mentions tests/"
else
    fail "E6 error message does not mention tests/ — got: $(printf '%q' "$ERR")"
fi

# ── I1 idempotency: identical query, unchanged corpus, identical bytes ─────
R="$(make_repo)"
add_test_file "$R" "bin/a.sh" "src/x.js,src/y.js" "scope:common" 20
add_test_file "$R" "bin/b.sh" "src/x.js" "scope:common" 30
add_test_file "$R" "bin/we,ird.sh" "src/x.js" "scope:common" 40
run_helper --root "$R" --sources "src/x.js" --sources "src/q.js"
I1_FIRST="$OUT"
I1_RC="$RC"
run_helper --root "$R" --sources "src/x.js" --sources "src/q.js"
case_ran I1
assert_eq "I1 the rerun repeats the exit code" "$I1_RC" "$RC"
assert_eq "I1 the rerun is byte-identical" "$I1_FIRST" "$OUT"
if [[ -n "$I1_FIRST" ]]; then
    pass "I1 the compared output was non-empty, so the comparison had content"
else
    fail "I1 both runs produced empty output — the idempotency comparison was vacuous"
fi

case_end

grp_done "edge-cases.sh"
