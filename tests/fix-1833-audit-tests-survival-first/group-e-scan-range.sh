# Group E: scan range — exactly-one ownership, archive exclusion, cron wiring (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, .github/workflows/sweep.yml
# Tags: TL2, audit-tests, retire, scan-range, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# The two scripts partition tests/ by filename scope. Once both apply the same
# survival predicate, a gap in that partition means a dead test is invisible to
# BOTH sweeps and an overlap means a file can be judged twice with two verdicts.
# Every top-level test file must be owned by exactly one script.

E_REPO="$(make_repo)"
# Header-less on purpose: NO_TESTS_HEADER is emitted for every file a script
# scans, which makes the scanned set directly observable.
add_test_file_nohdr "$E_REPO" "feature-501-issue-scope.sh"
add_test_file_nohdr "$E_REPO" "feature-502-issue-scope.sh"
add_test_file_nohdr "$E_REPO" "fix-503-common-scope.sh"
add_test_file_nohdr "$E_REPO" "cc-plain-common.sh"
add_test_file_nohdr "$E_REPO" "feature-test-cleanup-944.sh"
mkdir -p "$E_REPO/tests/_archive"
add_test_file_nohdr "$E_REPO" "_archive/feature-599-archived.sh"
add_test_file_nohdr "$E_REPO" "_archive/cc-archived.sh"
commit_repo "$E_REPO" "scan-range fixture"

E_STUB="$TMPDIR_BASE/e-stub"
install_gh_mock "$E_STUB"
export MOCK_ISSUES="501 closed 2019-01-01T00:00:00Z
502 closed 2019-01-01T00:00:00Z"

scanned_set() { # <output> -> sorted file list from the diagnostics lines
    echo "$1" | grep -oE "^(NO_TESTS_HEADER|MALFORMED_HEADER|ORPHAN|CANDIDATE): tests/[^ ]+" \
        | sed 's/^[A-Z_]*: //' | sort -u
}

run_in_repo "$E_REPO" "$E_STUB" "$AUDIT" --dry-run --format text
E_ISSUE_OUT="$OUT"
E_ISSUE_SET="$(scanned_set "$E_ISSUE_OUT")"
run_in_repo "$E_REPO" "-" "$AUDIT_COMMON" --dry-run --offline --format text
E_COMMON_OUT="$OUT"
E_COMMON_SET="$(scanned_set "$E_COMMON_OUT")"

E_EXPECTED="tests/cc-plain-common.sh
tests/feature-501-issue-scope.sh
tests/feature-502-issue-scope.sh
tests/feature-test-cleanup-944.sh
tests/fix-503-common-scope.sh"

# E1 (case 30) — union covers every top-level test file: no gap.
E_UNION="$(printf '%s\n%s\n' "$E_ISSUE_SET" "$E_COMMON_SET" | grep -v '^$' | sort -u)"
if [[ "$E_UNION" == "$E_EXPECTED" ]]; then
    pass "E1a every top-level test file is scanned by at least one script (no gap)"
else
    fail "E1a scan coverage gap (union=<<$E_UNION>> expected=<<$E_EXPECTED>>)"
fi

# E1b — intersection is empty: no file is judged by both.
E_BOTH="$(comm -12 <(printf '%s\n' "$E_ISSUE_SET" | grep -v '^$') \
                   <(printf '%s\n' "$E_COMMON_SET" | grep -v '^$'))"
if [[ -z "$E_BOTH" ]]; then
    pass "E1b no test file is scanned by both scripts (no overlap)"
else
    fail "E1b files scanned by both scripts: <<$E_BOTH>>"
fi

# E1c — the scope split itself: `feature-<digits>-` is issue-specific, all else common.
if [[ "$E_ISSUE_SET" == "tests/feature-501-issue-scope.sh
tests/feature-502-issue-scope.sh" ]]; then
    pass "E1c audit-tests owns exactly the feature-<digits>- files"
else
    fail "E1c audit-tests scope set wrong (got=<<$E_ISSUE_SET>>)"
fi
if echo "$E_COMMON_SET" | grep -q "^tests/feature-test-cleanup-944.sh$"; then
    pass "E1d a non-numeric feature-* name belongs to the common scope"
else
    fail "E1d tests/feature-test-cleanup-944.sh must be scanned by audit-tests-common (got=<<$E_COMMON_SET>>)"
fi

# E2 (case 31) — tests/_archive/ is out of range for both scripts.
if echo "$E_ISSUE_OUT$E_COMMON_OUT" | grep -q "_archive/"; then
    fail "E2a tests/_archive/ must be excluded from both scans (issue=<<$E_ISSUE_OUT>> common=<<$E_COMMON_OUT>>)"
else
    pass "E2a tests/_archive/ is excluded from both scans"
fi

E2_REPO="$(make_repo)"
mkdir -p "$E2_REPO/tests/_archive"
add_test_file "$E2_REPO" "_archive/feature-598-archived.sh" "bin/gone-e1.sh" "TL2, scope:issue-specific"
add_test_file "$E2_REPO" "_archive/cc-archived.sh" "bin/gone-e2.sh"
commit_repo "$E2_REPO" "archive-only fixture"
run_in_repo "$E2_REPO" "$E_STUB" "$AUDIT" --apply --offline --format text
run_in_repo "$E2_REPO" "-" "$AUDIT_COMMON" --apply --offline --format text
if [[ -e "$E2_REPO/tests/_archive/feature-598-archived.sh" && -e "$E2_REPO/tests/_archive/cc-archived.sh" ]]; then
    pass "E2b archived files with dead targets are never deleted by the write path"
else
    fail "E2b the write path deleted a file under tests/_archive/"
fi

# E3 (case 32) — the nightly sweep must stay report-only after apply-by-default.
if [[ -f "$SWEEP_YML" ]]; then
    E3_AUDIT_LINE="$(grep -E 'bin/audit-tests\.sh' "$SWEEP_YML" || true)"
    E3_COMMON_LINE="$(grep -E 'bin/audit-tests-common\.sh' "$SWEEP_YML" || true)"
    if [[ -n "$E3_AUDIT_LINE" && "$E3_AUDIT_LINE" == *"--dry-run"* ]]; then
        pass "E3a sweep.yml invokes bin/audit-tests.sh with --dry-run"
    else
        fail "E3a sweep.yml audit-tests step is not --dry-run (line=<<$E3_AUDIT_LINE>>)"
    fi
    if [[ -n "$E3_COMMON_LINE" && "$E3_COMMON_LINE" == *"--dry-run"* ]]; then
        pass "E3b sweep.yml invokes bin/audit-tests-common.sh with --dry-run"
    else
        fail "E3b sweep.yml audit-tests-common step is not --dry-run (line=<<$E3_COMMON_LINE>>)"
    fi
    if echo "$E3_AUDIT_LINE$E3_COMMON_LINE" | grep -q -- "--apply"; then
        fail "E3c sweep.yml must not pass --apply to either audit script"
    else
        pass "E3c sweep.yml passes --apply to neither audit script"
    fi
else
    fail "E3 .github/workflows/sweep.yml not found at $SWEEP_YML"
fi

# E4 (case 33) — --dry-run is genuinely read-only on the common script, while
# the flagless (apply-by-default) invocation does delete. Same repo shape, two
# runs: the difference isolates the write-mode flag as the only cause.
E4_REPO="$(make_repo)"
add_src "$E4_REPO" "bin/alive.sh"
add_test_file "$E4_REPO" "cc-dead.sh" "bin/gone-e3.sh"
add_test_file "$E4_REPO" "cc-live.sh" "bin/alive.sh"
commit_repo "$E4_REPO" "write-mode fixture"

run_in_repo "$E4_REPO" "-" "$AUDIT_COMMON" --dry-run --offline --format text
if [[ -e "$E4_REPO/tests/cc-dead.sh" ]]; then
    pass "E4a --dry-run reports an orphan without deleting it"
else
    fail "E4a --dry-run deleted tests/cc-dead.sh (out=<<$OUT>>)"
fi

run_in_repo "$E4_REPO" "-" "$AUDIT_COMMON" --offline --format text
E4_OUT="$OUT"
if [[ ! -e "$E4_REPO/tests/cc-dead.sh" ]] && echo "$E4_OUT" | grep -q "^DELETED: tests/cc-dead.sh$"; then
    pass "E4b flagless (apply-by-default) run deletes the orphan and reports DELETED:"
else
    fail "E4b expected flagless run to delete tests/cc-dead.sh with a DELETED: line (rc=$RC out=<<$E4_OUT>> err=<<$ERR>>)"
fi
if [[ -e "$E4_REPO/tests/cc-live.sh" ]]; then
    pass "E4c the live-target file survives the flagless run"
else
    fail "E4c flagless run deleted a live-target file"
fi

# E5 — filename edge cases inside the scan range.
# Two distinct axes are checked here, and they must not be conflated:
#   (a) a name the shell can mangle (embedded space) must be scanned, reported
#       and deleted intact — an unquoted expansion would either miss it or hand
#       `git rm` two bogus pathspecs;
#   (b) a test-shaped file that is NOT `*.sh` (extensionless, .py, .Tests.ps1)
#       is outside both globs today. That is a known scan hole, deliberately out
#       of scope for #1833 — this pins the current boundary so a future glob
#       widening is a conscious change, not an accident.
E5_REPO="$(make_repo)"
add_test_file "$E5_REPO" "cc common with space.sh" "bin/gone-e5a.sh"
add_test_file "$E5_REPO" "feature-521-with space.sh" "bin/gone-e5b.sh" "TL2, scope:issue-specific"
add_test_file "$E5_REPO" "cc-plain-e5.sh" "bin/gone-e5c.sh"
# Not *.sh — outside both globs.
{ printf '#!/usr/bin/env bash\n# Tests: bin/gone-e5d.sh\n'; } > "$E5_REPO/tests/extensionless-test"
{ printf '# Tests: bin/gone-e5e.sh\n'; } > "$E5_REPO/tests/test_shaped_like_a_test.py"
{ printf '# Tests: bin/gone-e5f.sh\n'; } > "$E5_REPO/tests/Shaped.Tests.ps1"
commit_repo "$E5_REPO" "filename edge-case fixture"

unset MOCK_ISSUES
run_in_repo "$E5_REPO" "-" "$AUDIT" --offline --apply --format text
E5_ISSUE_OUT="$OUT"
run_in_repo "$E5_REPO" "-" "$AUDIT_COMMON" --offline --apply --format text
E5_COMMON_OUT="$OUT"
E5_BOTH="$E5_ISSUE_OUT
$E5_COMMON_OUT"

# E5a/E5b — the space-bearing common-scope file is scanned, reported, and
# actually removed (no issue reference, so the delete gate opens).
assert_gate_row "E5a space in filename: common scope is reported and deleted intact" \
    "$E5_COMMON_OUT" "$E5_REPO" "tests/cc common with space.sh" orphan deleted gone
# E5c — its issue-specific sibling is scanned too; --offline holds the delete.
assert_gate_row "E5c space in filename: issue-specific scope is reported, delete held" \
    "$E5_ISSUE_OUT" "$E5_REPO" "tests/feature-521-with space.sh" \
    candidate metadata-unavailable kept

# E5d/E5e — non-.sh test-shaped files are neither reported nor touched.
for e5_other in "extensionless-test" "test_shaped_like_a_test.py" "Shaped.Tests.ps1"; do
    assert_eq "E5d non-.sh file is outside both scan ranges: $e5_other" \
        "none" "$(report_of "$E5_BOTH" "tests/$e5_other")"
    assert_eq "E5e non-.sh file survives both --apply runs: $e5_other" \
        "kept" "$(fs_of "$E5_REPO" "tests/$e5_other")"
done
