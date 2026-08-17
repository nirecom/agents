# S12 category 3: header structure — duplicate lines and position (#2065, S1-1)
# Tests: bin/lib/test-dup-group.sh, bin/lib/test-frontmatter-constants.sh, bin/check-test-frontmatter.sh
# Tags: TL2, audit-tests, dup-groups, frontmatter, structure, scope:issue-specific
# Sourced by tests/feature-2065-dup-group-inventory.sh

# `grep -m1 '^# Tests:'` reads neither the line number nor the occurrence count,
# so a second header line is silently dropped and a header at line 11+ is
# silently accepted. Both are structural malformations that must become skip
# rows instead of quietly seeding a group from the first value.

SI_REPO="$(make_repo)"
add_src "$SI_REPO" "bin/si-first.sh"
add_src "$SI_REPO" "bin/si-second.sh"
add_src "$SI_REPO" "bin/si-edge.sh"

# Duplicate header. `bin/si-first.sh` is the value the old rule would have used,
# and it appears nowhere else in this fixture, so any full/token row carrying it
# proves the first value seeded a group.
add_test_file_raw "$SI_REPO" "si-dup.sh" <<'SI_DUP'
#!/usr/bin/env bash
# Tests: bin/si-first.sh
# Tags: TL2, scope:common
# Tests: bin/si-second.sh
echo fixture
SI_DUP

# Duplicate AND malformed: priority is duplicate_header > late_header >
# malformed_header, and the file is counted exactly once.
add_test_file_raw "$SI_REPO" "si-dup-malformed.sh" <<'SI_DUPMAL'
#!/usr/bin/env bash
# Tests: bin/si-first.sh (annotated)
# Tags: TL2, scope:common
# Tests: bin/*.sh
echo fixture
SI_DUPMAL

# First header at line 11 — one past FRONTMATTER_HEADER_MAX_LINE.
add_test_file_raw "$SI_REPO" "si-late.sh" <<'SI_LATE'
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
# Tests: bin/si-second.sh
echo fixture
SI_LATE

# Boundary: header at exactly line 10 is inside the contract. Paired with a
# canonical file so "ok" is observable as group membership, not just absence.
add_test_file_raw "$SI_REPO" "si-boundary.sh" <<'SI_EDGE'
#!/usr/bin/env bash
# Tags: TL2, scope:common
: filler 03
: filler 04
: filler 05
: filler 06
: filler 07
: filler 08
: filler 09
# Tests: bin/si-edge.sh
echo fixture
SI_EDGE
add_test_file "$SI_REPO" "si-boundary-partner.sh" "bin/si-edge.sh"
commit_repo "$SI_REPO" "structural fixture"

run_dup "$SI_REPO" "$AUDIT"
SI_OUT="$OUT"

while IFS='|' read -r si_name si_file si_want; do
    [[ -z "${si_name//[[:space:]]/}" || "$si_name" =~ ^[[:space:]]*# ]] && continue
    si_name="${si_name//[[:space:]]/}"
    si_file="${si_file//[[:space:]]/}"
    si_want="${si_want//[[:space:]]/}"
    assert_eq "SI1[$si_name] verdict" "$si_want" "$(verdict_of "$SI_OUT" "tests/$si_file")"
done <<'SI_TABLE'
duplicate          | si-dup.sh              | duplicate_header
duplicate-plus-bad | si-dup-malformed.sh    | duplicate_header
late-line-11       | si-late.sh             | late_header
boundary-line-10   | si-boundary.sh         | ok
canonical-partner  | si-boundary-partner.sh | ok
SI_TABLE

# SI2 — the decisive assertion: no group was seeded from the first header value.
assert_eq "SI2a no full row exists for the duplicate file's first value" \
    "no" "$(row_exists "$SI_OUT" full "bin/si-first.sh")"
assert_eq "SI2b no token row exists for the duplicate file's first value" \
    "no" "$(row_exists "$SI_OUT" token "bin/si-first.sh")"
assert_eq "SI2c the duplicate file is absent from every group axis" \
    "" "$(file_group_axes "$SI_OUT" "tests/si-dup.sh")"
assert_eq "SI2d the late-header file is absent from every group axis" \
    "" "$(file_group_axes "$SI_OUT" "tests/si-late.sh")"

# SI3 — boundary line 10 is inside the contract, so it groups normally.
assert_eq "SI3a header at exactly line 10 forms a full group with its partner" \
    "2" "$(row_count "$SI_OUT" full "bin/si-edge.sh")"
assert_eq "SI3b the boundary file is a group member on both axes" \
    "full,token" "$(file_group_axes "$SI_OUT" "tests/si-boundary.sh")"

# SI4 — one file, one skip reason. Double-counting would inflate `count` and make
# the corpus-wide numbers in the hand-off issue wrong.
SI_TOTAL="$(skip_members_all "$SI_OUT" | grep -c . || true)"
SI_UNIQ="$(skip_members_all "$SI_OUT" | sort -u | grep -c . || true)"
assert_eq "SI4a the skip reason sets are pairwise disjoint" "$SI_UNIQ" "$SI_TOTAL"
assert_eq "SI4b the duplicate+malformed file is not also under malformed_header" \
    "0" "$(row_files "$SI_OUT" skip malformed_header | grep -c 'si-dup-malformed\.sh' || true)"

# SI5 — the pre-commit HARD gate is deliberately unchanged by this PR: duplicate
# and position-violating files must still be accepted. When the hand-off issue
# from S11 lands the structural check in check-test-frontmatter.sh, INVERT this
# case rather than deleting it.
SI_GATE_REPO="$(make_repo)"
add_src "$SI_GATE_REPO" "bin/si-first.sh"
add_src "$SI_GATE_REPO" "bin/si-second.sh"
cp "$SI_REPO/tests/si-dup.sh" "$SI_GATE_REPO/tests/si-dup.sh"
cp "$SI_REPO/tests/si-late.sh" "$SI_GATE_REPO/tests/si-late.sh"
cp "$SI_REPO/tests/si-boundary.sh" "$SI_GATE_REPO/tests/si-boundary.sh"
commit_repo "$SI_GATE_REPO" "frontmatter gate fixture"

run_in_repo "$SI_GATE_REPO" "$FM_CHECK" --all "$SI_GATE_REPO"
assert_eq "SI5 check-test-frontmatter.sh --all still accepts duplicate/late headers" \
    "0" "$RC"
