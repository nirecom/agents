# S12 category 6: malformed input and mode-exclusivity guards (#2065, S3)
# Tests: bin/lib/test-dup-group.sh, bin/audit-tests.sh, bin/audit-tests-common.sh
# Tags: TL2, audit-tests, dup-groups, cli, guards, scope:issue-specific
# Sourced by tests/feature-2065-dup-group-inventory.sh
# Two distinct failure families, kept apart on purpose (CPR-SC): malformed
# CONTENT is data the mode must classify and keep running on, while a bad
# COMMAND LINE is an operator error the mode must refuse outright with rc 2.

EC_REPO="$(make_repo)"
add_src "$EC_REPO" "bin/ec-ok.sh"
add_test_file "$EC_REPO" "ec-space.sh" "bin/ec a.sh"
add_test_file "$EC_REPO" "ec-paren.sh" "bin/ec-ok.sh (helper)"
add_test_file "$EC_REPO" "ec-glob.sh" "bin/*.sh"
add_test_file "$EC_REPO" "ec-mixed.sh" "bin/ec-ok.sh, bin/ec b.sh"
add_test_file "$EC_REPO" "ec-empty.sh" ""

add_test_file_raw "$EC_REPO" "ec-noheader.sh" <<'EC_NOHDR'
#!/usr/bin/env bash
# Tags: TL2, scope:common
echo fixture
EC_NOHDR
commit_repo "$EC_REPO" "error cases fixture"

run_dup "$EC_REPO" "$AUDIT"
EC_OUT="$OUT"; EC_RC="$RC"; EC_ERR="$ERR"

# EC1 — content classification. A malformed token anywhere in the value
# disqualifies the whole line: a partially-parsed value would seed a group key
# that does not correspond to any real target set.
while IFS='|' read -r ec_name ec_file ec_want; do
    [[ -z "${ec_name//[[:space:]]/}" || "$ec_name" =~ ^[[:space:]]*# ]] && continue
    ec_name="${ec_name//[[:space:]]/}"
    ec_file="${ec_file//[[:space:]]/}"
    ec_want="${ec_want//[[:space:]]/}"
    assert_eq "EC1[$ec_name] verdict" "$ec_want" "$(verdict_of "$EC_OUT" "tests/$ec_file")"
    assert_eq "EC1[$ec_name] contributes to no group axis" \
        "" "$(file_group_axes "$EC_OUT" "tests/$ec_file")"
done <<'EC_TABLE'
embedded-space   | ec-space.sh    | malformed_header
parenthesis      | ec-paren.sh    | malformed_header
glob             | ec-glob.sh     | malformed_header
one-bad-of-two   | ec-mixed.sh    | malformed_header
empty-value      | ec-empty.sh    | no_tests_header
missing-header   | ec-noheader.sh | no_tests_header
EC_TABLE

# EC2 — malformed content is data, not a crash: the run completes and the only
# non-zero possibility is the "no groups" code, never the error code.
assert_eq "EC2a malformed content does not make the run exit with the error code" \
    "not-2" "$( [[ "$EC_RC" == "2" ]] && echo "2" || echo "not-2" )"
assert_eq "EC2b malformed content produces no ERROR line" \
    "0" "$(printf '%s\n' "$EC_ERR" | grep -c '^ERROR:' || true)"
assert_eq "EC2c this fixture has no duplicate group, so the exit code is 1" "1" "$EC_RC"

# EC3 — command-line guards. Each row asserts rc 2 AND the specific message:
# an unknown-argument rejection also exits 2 today, so an exit-code-only
# assertion would pass for the wrong reason before the feature exists.
for ec_script in "$AUDIT" "$AUDIT_COMMON"; do
    ec_tag="$(basename "$ec_script")"

    run_dup "$EC_REPO" "$ec_script" --fix-headers
    assert_eq "EC3a[$ec_tag] --dup-groups --fix-headers exits 2" "2" "$RC"
    assert_eq "EC3b[$ec_tag] the message names the two modes as separate" \
        "1" "$(printf '%s\n' "$ERR" | grep -c -- '--dup-groups and --fix-headers are separate modes' || true)"

    run_dup "$EC_REPO" "$ec_script" --format json
    assert_eq "EC3c[$ec_tag] --dup-groups --format json exits 2" "2" "$RC"
    assert_eq "EC3d[$ec_tag] the message states that the mode emits TSV only" \
        "1" "$(printf '%s\n' "$ERR" | grep -c -- '--dup-groups emits TSV only' || true)"

    # EC4 — repo-root resolution is fail-closed and applies to the new mode too.
    run_no_repo "$ec_script" --dup-groups
    assert_eq "EC4a[$ec_tag] running outside a git repository exits 2" "2" "$RC"
    assert_eq "EC4b[$ec_tag] the message names the repo-root resolution failure" \
        "1" "$(printf '%s\n' "$ERR" | grep -c 'not inside a git repository' || true)"
done

grp_done "error-cases.sh"
