# Group L: scan-glob expansion for .Tests.ps1 / test_*.py (#1864)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, e2e, scope:issue-specific
# Sourced by tests/bin/fix-2081-case-unit-refcount.sh
#
# .Tests.ps1 / test_*.py carry no case markers (extension guard C10) so they are
# always file-unit fallback. #1864 only adds them to the SCAN globs: an
# issue-specific feature-<N>-*.Tests.ps1 is owned by audit-tests.sh, everything
# else (incl. test_*.py) by audit-tests-common.sh, and tests/_archive is excluded.

if ! require_fn trp_case_refcount_verdict "L0"; then return 0; fi

L_REPO="$(make_repo)"
add_src "$L_REPO" "bin/l-live.ps1"

# issue-specific dead .Tests.ps1 → audit-tests.sh territory.
add_raw "$L_REPO" "feature-820-x.Tests.ps1" <<'EOF'
# Tests: bin/l-dead.ps1
# Tags: TL2, scope:issue-specific
Describe 'x' { It 'runs' { $true | Should -Be $true } }
EOF
# common dead .Tests.ps1 → audit-tests-common.sh territory.
add_raw "$L_REPO" "cc-l.Tests.ps1" <<'EOF'
# Tests: bin/l-dead-cc.ps1
# Tags: TL2, scope:common
Describe 'y' { It 'runs' { $true | Should -Be $true } }
EOF
# common dead test_*.py → audit-tests-common.sh territory.
add_raw "$L_REPO" "test_l_guard.py" <<'EOF'
# Tests: bin/l-dead.py
# Tags: TL2, scope:common
def test_x():
    assert True
EOF
# alive common .Tests.ps1 → must NOT be flagged.
add_raw "$L_REPO" "cc-l-alive.Tests.ps1" <<'EOF'
# Tests: bin/l-live.ps1
# Tags: TL2, scope:common
Describe 'z' { It 'runs' { $true | Should -Be $true } }
EOF
# archived dead .Tests.ps1 → excluded from the common scan.
mkdir -p "$L_REPO/tests/_archive"
printf '# Tests: bin/l-dead-arch.ps1\n# Tags: TL2, scope:common\nDescribe q {}\n' \
    > "$L_REPO/tests/_archive/cc-l-arch.Tests.ps1"
commit_repo "$L_REPO" "group-l glob-expansion fixtures"

L_STUB="$TMPDIR_BASE/l-stub"
install_gh_mock "$L_STUB"
export MOCK_ISSUES="820 open"

# ── audit-tests.sh: only the issue-specific .Tests.ps1 is in scope ──────────
run_in_repo "$L_REPO" "$L_STUB" "$AUDIT" --dry-run --format text
L_IS_OUT="$OUT"
if line_has "$L_IS_OUT" CANDIDATE "tests/feature-820-x.Tests.ps1"; then
    pass "L1 audit-tests.sh scans issue-specific .Tests.ps1 (dead → candidate)"
else
    fail "L1 expected feature-820-x.Tests.ps1 as candidate (out=<<$L_IS_OUT>>)"
fi
if line_has "$L_IS_OUT" CANDIDATE "tests/cc-l.Tests.ps1"; then
    fail "L1b audit-tests.sh wrongly claimed a common .Tests.ps1"
else
    pass "L1b audit-tests.sh leaves common .Tests.ps1 to the common script"
fi

# ── audit-tests-common.sh: common .Tests.ps1 + test_*.py, not the feature one ──
run_in_repo "$L_REPO" "$L_STUB" "$AUDIT_COMMON" --dry-run --format text
L_CC_OUT="$OUT"
if line_has "$L_CC_OUT" ORPHAN "tests/cc-l.Tests.ps1"; then
    pass "L2 audit-tests-common.sh scans common .Tests.ps1 (dead → orphan)"
else
    fail "L2 expected cc-l.Tests.ps1 as orphan (out=<<$L_CC_OUT>>)"
fi
if line_has "$L_CC_OUT" ORPHAN "tests/test_l_guard.py"; then
    pass "L2b audit-tests-common.sh scans test_*.py (dead → orphan)"
else
    fail "L2b expected test_l_guard.py as orphan (out=<<$L_CC_OUT>>)"
fi
if line_has "$L_CC_OUT" ORPHAN "tests/feature-820-x.Tests.ps1"; then
    fail "L2c common script wrongly claimed the issue-specific .Tests.ps1 (routing)"
else
    pass "L2c common script excludes issue-specific feature-<N>-*.Tests.ps1"
fi
if line_has "$L_CC_OUT" ORPHAN "tests/cc-l-alive.Tests.ps1"; then
    fail "L2d alive .Tests.ps1 wrongly flagged"
else
    pass "L2d alive .Tests.ps1 not flagged"
fi
if printf '%s\n' "$L_CC_OUT" | grep -qE "cc-l-arch\.Tests\.ps1"; then
    fail "L3 tests/_archive .Tests.ps1 leaked into the common scan"
else
    pass "L3 tests/_archive excluded from the common scan"
fi

unset MOCK_ISSUES
