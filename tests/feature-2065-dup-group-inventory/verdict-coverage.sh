# S12 category 9: every verdict in the closed set, in one corpus (#2065, S2)
# Tests: bin/lib/test-dup-group.sh, bin/audit-tests.sh
# Tags: TL2, audit-tests, dup-groups, coverage, scope:issue-specific
# Sourced by tests/feature-2065-dup-group-inventory.sh

# Earlier fragments exercise the verdicts one family at a time. This one puts
# all five in a single corpus, because the classifier is a priority chain: a
# reason that is correct in isolation can still be shadowed when its neighbours
# are present in the same run.

VC_REPO="$(make_repo)"
add_src "$VC_REPO" "bin/vc-a.sh"
add_src "$VC_REPO" "bin/vc-b.sh"

add_test_file "$VC_REPO" "vc-ok-a.sh" "bin/vc-a.sh"
add_test_file "$VC_REPO" "vc-ok-b.sh" "bin/vc-a.sh"
add_test_file "$VC_REPO" "vc-malformed.sh" "bin/vc a.sh"

add_test_file_raw "$VC_REPO" "vc-notests.sh" <<'VC_NOHDR'
#!/usr/bin/env bash
# Tags: TL2, scope:common
echo fixture
VC_NOHDR

add_test_file_raw "$VC_REPO" "vc-duplicate.sh" <<'VC_DUP'
#!/usr/bin/env bash
# Tests: bin/vc-a.sh
# Tags: TL2, scope:common
# Tests: bin/vc-b.sh
echo fixture
VC_DUP

add_test_file_raw "$VC_REPO" "vc-late.sh" <<'VC_LATE'
#!/usr/bin/env bash
# Tags: TL2, scope:common
: filler 03
: filler 04
: filler 05
: filler 06
: filler 07
: filler 08
: filler 09
: filler 10
# Tests: bin/vc-a.sh
echo fixture
VC_LATE
commit_repo "$VC_REPO" "verdict coverage fixture"

run_dup "$VC_REPO" "$AUDIT"
VC_OUT="$OUT"; VC_RC="$RC"

while IFS='|' read -r vc_name vc_file vc_want; do
    [[ -z "${vc_name//[[:space:]]/}" || "$vc_name" =~ ^[[:space:]]*# ]] && continue
    vc_name="${vc_name//[[:space:]]/}"
    vc_file="${vc_file//[[:space:]]/}"
    vc_want="${vc_want//[[:space:]]/}"
    assert_eq "VC1[$vc_name] verdict" "$vc_want" "$(verdict_of "$VC_OUT" "tests/$vc_file")"
done <<'VC_TABLE'
ok-grouped-a  | vc-ok-a.sh      | ok
ok-grouped-b  | vc-ok-b.sh      | ok
malformed     | vc-malformed.sh | malformed_header
no-header     | vc-notests.sh   | no_tests_header
duplicate     | vc-duplicate.sh | duplicate_header
late          | vc-late.sh      | late_header
VC_TABLE

# VC2 — the closed set is closed: an unrecognized reason token means the
# vocabulary drifted, and every downstream consumer of the TSV would break.
assert_eq "VC2a every skip key belongs to the closed four-reason vocabulary" \
    "0" "$(axis_keys "$VC_OUT" skip | grep -cvE '^(no_tests_header|duplicate_header|late_header|malformed_header)$' || true)"
assert_eq "VC2b all four skip reasons are present in this corpus" \
    "4" "$(axis_keys "$VC_OUT" skip | sort -u | grep -c . || true)"

# VC3 — skip rows are emitted even at count 1, unlike group rows. Suppressing
# them would hide exactly the malformed files the inventory exists to surface.
assert_eq "VC3 a skip reason with a single member is still reported" \
    "1" "$(row_count "$VC_OUT" skip malformed_header)"

# VC4 — the four skipped files must not appear in any group row, and the two
# well-formed files must. This is the partition invariant of the whole format.
assert_eq "VC4a no skipped file leaks into a group row" \
    "0" "$( for vc_f in vc-malformed.sh vc-notests.sh vc-duplicate.sh vc-late.sh; do
                file_group_axes "$VC_OUT" "tests/$vc_f"
            done | grep -c . || true )"
assert_eq "VC4b the two well-formed files form the only group" \
    "2" "$(row_count "$VC_OUT" full "bin/vc-a.sh")"
assert_eq "VC4c the corpus has exactly one full row" \
    "1" "$(axis_row_count "$VC_OUT" full)"
assert_eq "VC5 the corpus contains a group, so the exit code is 0" "0" "$VC_RC"
