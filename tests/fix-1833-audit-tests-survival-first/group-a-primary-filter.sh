# Group A: the PRIMARY FILTER is target survival, not issue state (#1833)
# Tests: bin/audit-tests.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, primary-filter, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# One fixture repo carries every survival verdict at once so a single run
# proves the filter partitions the input set (CPR-3: the six verdicts are
# separated explicitly, not collapsed into "candidate / not candidate").

A_REPO="$(make_repo)"

# alive target shared by the "alive" and "mixed" fixtures
add_src "$A_REPO" "bin/alive.sh"

# A rename pair: bin/old-name.sh is committed, then git-mv'd away, so
# find_renamed_path() resolves it and the file must NOT be a candidate.
add_src "$A_REPO" "bin/old-name.sh"
commit_repo "$A_REPO" "seed sources"
git -C "$A_REPO" mv bin/old-name.sh bin/new-name.sh >/dev/null 2>&1
commit_repo "$A_REPO" "rename old-name -> new-name"

# 101: every token gone, issue OPEN            -> CANDIDATE (false-negative regression)
add_test_file "$A_REPO" "feature-101-allmissing.sh" "bin/gone-a.sh" "TL2, scope:issue-specific"
# 102: token alive, issue CLOSED + stale       -> NOT a candidate (false-positive regression)
add_test_file "$A_REPO" "feature-102-alive.sh" "bin/alive.sh" "TL2, scope:issue-specific"
# 103: one alive + one gone                    -> NOT a candidate
add_test_file "$A_REPO" "feature-103-mixed.sh" "bin/alive.sh, bin/gone-b.sh" "TL2, scope:issue-specific"
# 104: gone but renamed target resolves        -> NOT a candidate
add_test_file "$A_REPO" "feature-104-renamed.sh" "bin/old-name.sh" "TL2, scope:issue-specific"
# 105: prose / A-class token                   -> MALFORMED_HEADER, never a candidate
add_test_file "$A_REPO" "feature-105-malformed.sh" "bin/gone-c.sh (annotated prose)" "TL2, scope:issue-specific"
# 106: no # Tests: line at all                 -> NO_TESTS_HEADER
add_test_file_nohdr "$A_REPO" "feature-106-noheader.sh"
# 107: # Tests: present but empty              -> NO_TESTS_HEADER
add_test_file_emptyhdr "$A_REPO" "feature-107-emptyheader.sh"
commit_repo "$A_REPO" "dispatchers"

A_STUB="$TMPDIR_BASE/a-stub"
install_gh_mock "$A_STUB"

# Everything except 101 is CLOSED and long stale: under the OLD contract all of
# them would be candidates, under the NEW contract only 101 is.
export MOCK_ISSUES="101 open
102 closed 2019-01-01T00:00:00Z
103 closed 2019-01-01T00:00:00Z
104 closed 2019-01-01T00:00:00Z
105 closed 2019-01-01T00:00:00Z
106 closed 2019-01-01T00:00:00Z
107 closed 2019-01-01T00:00:00Z"

run_in_repo "$A_REPO" "$A_STUB" "$AUDIT" --dry-run --format text
A_OUT="$OUT"; A_ERR="$ERR"; A_RC="$RC"

# A1–A6 — the survival-verdict matrix, one row per fixture. Table-driven per
# skills/_shared/test-design/parser-regex-tests.md: every verdict of the six-way
# partition is stated once, in the same shape, so a missing row is visible.
# `want` is what report_of() reads out of the text report:
#   candidate  — selected by the primary filter
#   malformed  — MALFORMED_HEADER diagnostic, never a candidate
#   no-header  — NO_TESTS_HEADER diagnostic, never a candidate
#   none       — survived the filter: not reported at all
while IFS='|' read -r a_name a_file a_want; do
    [[ -z "${a_name//[[:space:]]/}" || "$a_name" =~ ^[[:space:]]*# ]] && continue
    a_name="${a_name//[[:space:]]/}"
    a_file="${a_file//[[:space:]]/}"
    a_want="${a_want//[[:space:]]/}"
    assert_eq "A-survival[$a_name] (rc=$A_RC)" "$a_want" "$(report_of "$A_OUT" "tests/$a_file")"
done <<'TABLE'
# name              | fixture file                 | want report
all-missing-open    | feature-101-allmissing.sh    | candidate
alive-closed-stale  | feature-102-alive.sh         | none
partially-alive     | feature-103-mixed.sh         | none
renamed-target      | feature-104-renamed.sh       | none
prose-header        | feature-105-malformed.sh     | malformed
absent-header       | feature-106-noheader.sh      | no-header
empty-header        | feature-107-emptyheader.sh   | no-header
TABLE

# A6c — none of the undecidable files may leak into the candidate list, and the
# candidate list must be exactly one file wide (count, not just membership).
assert_eq "A6c exactly one CANDIDATE line in the whole report" "1" "$(count_lines "$A_OUT" CANDIDATE)"

# A7 — exit code contract: 0 when at least one candidate exists.
if [[ "$A_RC" -eq 0 ]]; then
    pass "A7 exit 0 when a survival candidate exists"
else
    fail "A7 expected exit 0 with a candidate present, got $A_RC"
fi

# A8 — the retired WARNING line must not leak back onto stderr; the missing-path
# information now belongs to the diagnostics channel.
if echo "$A_ERR" | grep -q "# Tests: path missing"; then
    fail "A8 legacy 'WARNING: # Tests: path missing' line still emitted (err=<<$A_ERR>>)"
else
    pass "A8 legacy per-token missing-path WARNING is gone"
fi

# A9 — --fix-headers remains an independent path that reports classification
# and never emits survival candidates (regression guard for the early-continue).
run_in_repo "$A_REPO" "$A_STUB" "$AUDIT" --fix-headers --dry-run
if [[ "$RC" -eq 0 ]] && ! echo "$OUT" | grep -q "^CANDIDATE:"; then
    pass "A9a --fix-headers reports classification and emits no candidates"
else
    fail "A9a --fix-headers must exit 0 with no CANDIDATE lines (rc=$RC out=<<$OUT>>)"
fi
if echo "$OUT" | grep -qE "^(C|FIX_A|FIX_B|FIX_AB|MANUAL_REVIEW_REQUIRED):"; then
    pass "A9b --fix-headers still emits per-token classification lines"
else
    fail "A9b --fix-headers emitted no classification lines (out=<<$OUT>>)"
fi

# A10 — CPR-5 mirror: audit-tests-common.sh applies the same survival filter to
# its own scope. A common-scope file with an alive target is never an orphan.
A_COMMON_REPO="$(make_repo)"
add_src "$A_COMMON_REPO" "bin/alive.sh"
add_test_file "$A_COMMON_REPO" "cc-alive.sh" "bin/alive.sh"
add_test_file "$A_COMMON_REPO" "cc-mixed.sh" "bin/alive.sh, bin/gone-d.sh"
add_test_file "$A_COMMON_REPO" "cc-gone.sh" "bin/gone-e.sh"
commit_repo "$A_COMMON_REPO" "common dispatchers"

run_in_repo "$A_COMMON_REPO" "-" "$AUDIT_COMMON" --dry-run --offline --format text
A_COMMON_OUT="$OUT"; A_COMMON_RC="$RC"

# A10 — the same matrix shape applied to the sibling script (CPR-5): the only
# difference allowed between the two scripts is which files they scan.
while IFS='|' read -r a_name a_file a_want; do
    [[ -z "${a_name//[[:space:]]/}" || "$a_name" =~ ^[[:space:]]*# ]] && continue
    a_name="${a_name//[[:space:]]/}"
    a_file="${a_file//[[:space:]]/}"
    a_want="${a_want//[[:space:]]/}"
    assert_eq "A-survival-common[$a_name] (rc=$A_COMMON_RC)" "$a_want" \
        "$(report_of "$A_COMMON_OUT" "tests/$a_file")"
done <<'TABLE'
# name             | fixture file  | want report
all-missing        | cc-gone.sh    | orphan
alive              | cc-alive.sh   | none
partially-alive    | cc-mixed.sh   | none
TABLE

assert_eq "A10c exactly one ORPHAN line in the common report" "1" \
    "$(count_lines "$A_COMMON_OUT" ORPHAN)"
