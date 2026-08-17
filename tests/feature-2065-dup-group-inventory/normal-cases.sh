# S12 category 5: the happy path — how groups form on both axes (#2065, S2)
# Tests: bin/lib/test-dup-group.sh, bin/audit-tests.sh
# Tags: TL2, audit-tests, dup-groups, grouping, scope:issue-specific
# Sourced by tests/feature-2065-dup-group-inventory.sh

# The inventory has two axes because the two questions differ: `full` finds
# files whose whole target set is identical (candidates for a merge), `token`
# finds files that merely share their primary target (candidates for a review).
# A file can be in both, one, or neither.

NC_REPO="$(make_repo)"
add_src "$NC_REPO" "bin/nc-x.sh"
add_src "$NC_REPO" "bin/nc-y.sh"
add_src "$NC_REPO" "bin/nc-z.sh"
add_src "$NC_REPO" "bin/nc-w.sh"
add_src "$NC_REPO" "bin/nc-v.sh"
add_src "$NC_REPO" "bin/nc-solo.sh"
add_src "$NC_REPO" "bin/nc-other.sh"

# Pair 1 — identical whole value: both axes.
add_test_file "$NC_REPO" "nc-same-a.sh" "bin/nc-x.sh, bin/nc-y.sh"
add_test_file "$NC_REPO" "nc-same-b.sh" "bin/nc-x.sh, bin/nc-y.sh"
# Pair 2 — same first token, different whole value: token axis only.
add_test_file "$NC_REPO" "nc-tok-a.sh" "bin/nc-z.sh, bin/nc-x.sh"
add_test_file "$NC_REPO" "nc-tok-b.sh" "bin/nc-z.sh, bin/nc-other.sh"
# Pair 3 — same value, differing only in inter-token whitespace.
add_test_file "$NC_REPO" "nc-ws-a.sh" "bin/nc-w.sh, bin/nc-v.sh"
add_test_file "$NC_REPO" "nc-ws-b.sh" "bin/nc-w.sh,bin/nc-v.sh"
# Singleton — unique value, unique first token: neither axis.
add_test_file "$NC_REPO" "nc-solo.sh" "bin/nc-solo.sh"
commit_repo "$NC_REPO" "normal cases fixture"

run_dup "$NC_REPO" "$AUDIT"
NC_OUT="$OUT"; NC_RC="$RC"

NC_SAME_KEY="bin/nc-x.sh,bin/nc-y.sh"
NC_WS_KEY="bin/nc-w.sh,bin/nc-v.sh"

# NC1 — axis membership per file, table-driven.
while IFS='|' read -r nc_name nc_file nc_axes; do
    [[ -z "${nc_name//[[:space:]]/}" || "$nc_name" =~ ^[[:space:]]*# ]] && continue
    nc_name="${nc_name//[[:space:]]/}"
    nc_file="${nc_file//[[:space:]]/}"
    nc_axes="${nc_axes//[[:space:]]/}"
    assert_eq "NC1[$nc_name] axis membership" "$nc_axes" \
        "$(file_group_axes "$NC_OUT" "tests/$nc_file")"
done <<'NC_TABLE'
same-line-a      | nc-same-a.sh | full,token
same-line-b      | nc-same-b.sh | full,token
first-token-only | nc-tok-a.sh  | token
first-token-only | nc-tok-b.sh  | token
whitespace-a     | nc-ws-a.sh   | full,token
whitespace-b     | nc-ws-b.sh   | full,token
singleton        | nc-solo.sh   |
NC_TABLE

# NC2 — counts. The x/y pair also shares its first token with nc-tok-a.sh, so
# the token row for bin/nc-x.sh must NOT exist (nc-tok-a has nc-z first).
assert_eq "NC2a identical-value pair forms a full group of 2" \
    "2" "$(row_count "$NC_OUT" full "$NC_SAME_KEY")"
assert_eq "NC2b whitespace-only difference collapses into one full group of 2" \
    "2" "$(row_count "$NC_OUT" full "$NC_WS_KEY")"
assert_eq "NC2c shared first token forms a token group of 2" \
    "2" "$(row_count "$NC_OUT" token "bin/nc-z.sh")"
assert_eq "NC2d differing whole values produce no full group for the token pair" \
    "no" "$(row_exists "$NC_OUT" full "bin/nc-z.sh,bin/nc-x.sh")"

# NC3 — the singleton must be invisible on both axes and generate no skip row:
# a well-formed lone file is simply not part of the inventory.
assert_eq "NC3a the singleton's value forms no full row" \
    "no" "$(row_exists "$NC_OUT" full "bin/nc-solo.sh")"
assert_eq "NC3b the singleton is well-formed, so it has no skip reason" \
    "ok" "$(verdict_of "$NC_OUT" "tests/nc-solo.sh")"

# NC4 — the `files` column is a stable, sorted member list, so a reader can
# diff two inventories without spurious churn.
NC_MEMBERS="$(row_files "$NC_OUT" full "$NC_SAME_KEY")"
assert_eq "NC4a full-group members are listed in ascending order" \
    "$(esc_members "$NC_MEMBERS" | sort)" "$(esc_members "$NC_MEMBERS")"
assert_eq "NC4b the full-group member list holds exactly the two fixtures" \
    "2" "$(esc_count "$NC_MEMBERS")"

# NC5 — this fixture has duplicates, so the mode reports success.
assert_eq "NC5 exit code is 0 when at least one group exists" "0" "$NC_RC"
