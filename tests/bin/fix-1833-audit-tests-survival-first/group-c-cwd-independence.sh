# Group C: verdicts must not depend on the caller's CWD (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, cwd-independence, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# classify_tests_header() evaluates `[[ -e "$eff" ]]` relative to the CURRENT
# WORKING DIRECTORY. audit-tests.sh happens to cd into the repo root first;
# audit-tests-common.sh does not. Routing both through one shared predicate
# without passing the repo root explicitly would make every live target look
# missing when the caller runs from elsewhere — and, with apply-by-default,
# would delete the entire tests/ tree. These cases pin the repo-root contract.
#
# The caller runs from a non-repo temp dir and designates the repo via
# GIT_DIR / GIT_WORK_TREE, which is exactly how a hook or a wrapper invokes a
# script without changing directory.

# c_fixture — repo with alive targets in both scopes plus one true orphan.
c_fixture() {
    local root
    root="$(make_repo)"
    add_src "$root" "bin/alive.sh"
    add_test_file "$root" "cc-alive.sh" "bin/alive.sh"
    add_test_file "$root" "feature-701-alive.sh" "bin/alive.sh" "TL2, scope:issue-specific"
    add_test_file "$root" "cc-orphan.sh" "bin/gone-cwd.sh"
    commit_repo "$root" "cwd fixture"
    echo "$root"
}

C_REPO="$(c_fixture)"

# C1 — common script, repo-outside CWD, report only.
run_outside_repo "$C_REPO" "-" "$AUDIT_COMMON" --dry-run --offline --format text
C1_OUT="$OUT"; C1_RC="$RC"
if [[ "$C1_RC" -ne 2 ]] && ! echo "$C1_OUT" | grep -q "cc-alive.sh"; then
    pass "C1 audit-tests-common from a repo-outside CWD does not misreport a live target"
else
    fail "C1 audit-tests-common misjudged a live target from outside the repo (rc=$C1_RC out=<<$C1_OUT>> err=<<$ERR>>)"
fi
if echo "$C1_OUT" | grep -q "^ORPHAN: tests/cc-orphan.sh$"; then
    pass "C1b the genuine orphan is still detected from a repo-outside CWD"
else
    fail "C1b expected ORPHAN for tests/cc-orphan.sh from outside the repo (rc=$C1_RC out=<<$C1_OUT>>)"
fi

# C2 — issue-specific script, same conditions.
run_outside_repo "$C_REPO" "-" "$AUDIT" --dry-run --offline --format text
C2_OUT="$OUT"; C2_RC="$RC"
if [[ "$C2_RC" -ne 2 ]] && ! echo "$C2_OUT" | grep -q "feature-701-alive.sh"; then
    pass "C2 audit-tests from a repo-outside CWD does not misreport a live target"
else
    fail "C2 audit-tests misjudged a live target from outside the repo (rc=$C2_RC out=<<$C2_OUT>> err=<<$ERR>>)"
fi

# C3 — the same scenario with the write path armed: nothing with a live target
# may be removed. This is the blast-radius case.
C3_REPO="$(c_fixture)"
run_outside_repo "$C3_REPO" "-" "$AUDIT_COMMON" --apply --offline --format text
C3_OUT="$OUT"; C3_RC="$RC"
if [[ -e "$C3_REPO/tests/cc-alive.sh" && -e "$C3_REPO/tests/feature-701-alive.sh" ]]; then
    pass "C3a repo-outside --apply deleted no file with a live target"
else
    fail "C3a repo-outside --apply destroyed live-target files (rc=$C3_RC out=<<$C3_OUT>>)"
fi
if [[ -e "$C3_REPO/bin/alive.sh" ]]; then
    pass "C3b repo-outside --apply left non-test sources untouched"
else
    fail "C3b repo-outside --apply removed bin/alive.sh"
fi

# C4 — byte-identical output from inside and outside the repo.
C4_REPO="$(c_fixture)"
run_outside_repo "$C4_REPO" "-" "$AUDIT_COMMON" --dry-run --offline --format text
C4_OUTSIDE="$OUT"
run_in_repo "$C4_REPO" "-" "$AUDIT_COMMON" --dry-run --offline --format text
C4_INSIDE="$OUT"
if [[ -n "$C4_INSIDE" && "$C4_OUTSIDE" == "$C4_INSIDE" ]]; then
    pass "C4a audit-tests-common output is identical inside and outside the repo"
else
    fail "C4a audit-tests-common output differs by CWD (outside=<<$C4_OUTSIDE>> inside=<<$C4_INSIDE>>)"
fi

run_outside_repo "$C4_REPO" "-" "$AUDIT" --dry-run --offline --format text
C4B_OUTSIDE="$OUT"
run_in_repo "$C4_REPO" "-" "$AUDIT" --dry-run --offline --format text
C4B_INSIDE="$OUT"
if [[ -n "$C4B_INSIDE" && "$C4B_OUTSIDE" == "$C4B_INSIDE" ]]; then
    pass "C4b audit-tests output is identical inside and outside the repo"
else
    fail "C4b audit-tests output differs by CWD (outside=<<$C4B_OUTSIDE>> inside=<<$C4B_INSIDE>>)"
fi

# C5 — repo root cannot be resolved at all: fail closed, delete nothing.
C5_REPO="$(c_fixture)"
C5_BEFORE="$(ls "$C5_REPO/tests" | sort)"
run_no_repo "-" "$AUDIT_COMMON" --apply --offline --format text
C5_RC_COMMON="$RC"
run_no_repo "-" "$AUDIT" --apply --offline --format text
C5_RC_AUDIT="$RC"
C5_AFTER="$(ls "$C5_REPO/tests" | sort)"

if [[ "$C5_RC_COMMON" -eq 2 ]]; then
    pass "C5a audit-tests-common exits 2 when the repo root cannot be resolved"
else
    fail "C5a expected exit 2 outside any git repo, got $C5_RC_COMMON"
fi
if [[ "$C5_RC_AUDIT" -eq 2 ]]; then
    pass "C5b audit-tests exits 2 when the repo root cannot be resolved"
else
    fail "C5b expected exit 2 outside any git repo, got $C5_RC_AUDIT"
fi
if [[ "$C5_BEFORE" == "$C5_AFTER" ]]; then
    pass "C5c fail-closed run deleted nothing"
else
    fail "C5c fail-closed run changed the tests/ tree (before=<<$C5_BEFORE>> after=<<$C5_AFTER>>)"
fi
