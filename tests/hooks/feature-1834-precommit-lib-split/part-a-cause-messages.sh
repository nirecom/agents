# Part A — cause-specific block messages (real bin/check-test-frontmatter.sh).
# Sourced by tests/hooks/feature-1834-precommit-lib-split.sh; shares its helpers/globals.

echo "=== Part A: cause-specific block messages (real bin/check-test-frontmatter.sh) ==="

# A1: flat-location cause fires ALONE.
case_begin "A1-location-cause-alone" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/a1"; init_fixture "$R"
write_valid_flat "$R"
run_fm_check "$R"
if [ "$RC" -ne 1 ]; then
    fail "A1: flat-location cause" "want rc 1, got $RC — out: $(printf '%s' "$OUT" | tr '\n' ' ')"
elif ! printf '%s' "$OUT" | grep -qF "$LOC_MSG"; then
    fail "A1: flat-location cause" "output lacks the location message [$LOC_MSG]"
elif printf '%s' "$OUT" | grep -qF "$FM_MSG"; then
    fail "A1: flat-location cause" "frontmatter message [$FM_MSG] leaked though only the location is wrong"
else
    pass "A1: a new flat tests/*.sh blocks with the location message alone"
fi
case_end

# A2: frontmatter cause fires ALONE.
case_begin "A2-frontmatter-cause-alone" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/a2"; init_fixture "$R"
write_broken_categorized "$R"
run_fm_check "$R"
if [ "$RC" -ne 1 ]; then
    fail "A2: frontmatter cause" "want rc 1, got $RC — out: $(printf '%s' "$OUT" | tr '\n' ' ')"
elif ! printf '%s' "$OUT" | grep -qF "$FM_MSG"; then
    fail "A2: frontmatter cause" "output lacks the frontmatter message [$FM_MSG]"
elif printf '%s' "$OUT" | grep -qF "$LOC_MSG"; then
    fail "A2: frontmatter cause" "location message [$LOC_MSG] leaked though the file is correctly categorized"
else
    pass "A2: a categorized file with a bad header blocks with the frontmatter message alone"
fi
case_end

# A3: BOTH causes fire in one run (CPR-ORTH both-may-fire).
case_begin "A3-both-causes-fire" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/a3"; init_fixture "$R"
write_valid_flat "$R"
write_broken_categorized "$R"
run_fm_check "$R"
if [ "$RC" -ne 1 ]; then
    fail "A3: both causes" "want rc 1, got $RC — out: $(printf '%s' "$OUT" | tr '\n' ' ')"
elif ! printf '%s' "$OUT" | grep -qF "$LOC_MSG"; then
    fail "A3: both causes" "output lacks the location message [$LOC_MSG]"
elif ! printf '%s' "$OUT" | grep -qF "$FM_MSG"; then
    fail "A3: both causes" "output lacks the frontmatter message [$FM_MSG]"
else
    pass "A3: a flat + a bad-header file together fire both block messages"
fi
case_end

# A4: clean sanctioned input — the non-targeted verdict (no over-blocking).
# The fixture ships NO tests/lib/harness.sh, so the harness-source rule is skipped and
# only frontmatter + location are checked; a well-formed categorized file passes clean.
case_begin "A4-clean-input-passes" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/a4"; init_fixture "$R"
write_good_categorized "$R"
run_fm_check "$R"
if [ "$RC" -ne 0 ]; then
    fail "A4: clean input" "want rc 0, got $RC — out: $(printf '%s' "$OUT" | tr '\n' ' ')"
elif printf '%s' "$OUT" | grep -qF "$LOC_MSG"; then
    fail "A4: clean input" "location message [$LOC_MSG] fired on sanctioned input"
elif printf '%s' "$OUT" | grep -qF "$FM_MSG"; then
    fail "A4: clean input" "frontmatter message [$FM_MSG] fired on sanctioned input"
else
    pass "A4: a well-formed categorized file is not blocked and prints no block message"
fi
case_end

# A5: edge — nothing staged under tests/.
case_begin "A5-nothing-staged" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/a5"; init_fixture "$R"
run_fm_check "$R"
if [ "$RC" -ne 0 ]; then
    fail "A5: nothing staged" "want rc 0, got $RC — out: $(printf '%s' "$OUT" | tr '\n' ' ')"
elif [ -n "$OUT" ]; then
    fail "A5: nothing staged" "expected no block output, got: $(printf '%s' "$OUT" | tr '\n' ' ')"
else
    pass "A5: nothing staged under tests/ returns rc 0 with no output"
fi
case_end

# A6: infra + suite-subfile paths are EXCLUDED — staging them is a gate no-op (CPR-UNV: the
# exclusion must hold for EVERY excluded class, not just the observed one). Each fixture stages
# a HEADERLESS file (would fail frontmatter validation if inspected) at an excluded path; the
# gate must filter it before the checker runs, so the verdict is rc 0 with no block output.
case_begin "A6-excluded-paths-bypass-gate" "hooks/lib/precommit-tests-frontmatter.sh"
_a6_fail=""
for _rel in tests/_archive/old.sh tests/lib/harness-extra.sh tests/run-all.sh \
            tests/hooks/dispatcher/sub-part.sh tests/bin/suite/sub-part.sh; do
    R="$TMPBASE/a6_$(printf '%s' "$_rel" | tr '/.' '__')"; init_fixture "$R"
    write_staged_nofm "$R" "$_rel"
    run_fm_check "$R"
    if [ "$RC" -ne 0 ]; then
        _a6_fail="$_a6_fail [$_rel: want rc 0, got $RC]"
    elif [ -n "$OUT" ]; then
        _a6_fail="$_a6_fail [$_rel: want no output, got '$(printf '%s' "$OUT" | tr '\n' ' ')']"
    fi
done
if [ -n "$_a6_fail" ]; then
    fail "A6: excluded paths" "exclusion no-op broken:$_a6_fail"
else
    pass "A6: _archive/lib/run-all.sh/suite-subfiles are excluded — staging them is a gate no-op (rc 0, no output)"
fi
case_end

# A7-A9 (#2392): .Tests.ps1 / test_*.py get the same classification as .sh — category-direct is
# validated, a suite sub-file is skipped, a new flat file is forwarded and location-rejected.
case_begin "A7-A9-nonsh-classification" "hooks/lib/precommit-tests-frontmatter.sh"
_a7_fail=""
for _nm in x.Tests.ps1 test_x.py; do
    # A7: headerless category-direct file must reach the checker → frontmatter block.
    R="$TMPBASE/a7_$_nm"; init_fixture "$R"
    write_staged_nofm "$R" "tests/bin/$_nm"
    run_fm_check "$R"
    if [ "$RC" -ne 1 ] || ! printf '%s' "$OUT" | grep -qF "$FM_MSG"; then
        _a7_fail="$_a7_fail [A7 tests/bin/$_nm: want rc 1 + frontmatter msg, got rc $RC]"
    fi
    # A8: headerless suite sub-file must be filtered before the checker → no-op.
    R="$TMPBASE/a8_$_nm"; init_fixture "$R"
    write_staged_nofm "$R" "tests/bin/sub/$_nm"
    run_fm_check "$R"
    if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then
        _a7_fail="$_a7_fail [A8 tests/bin/sub/$_nm: want rc 0 + no output, got rc $RC]"
    fi
    # A9: new flat file with VALID frontmatter → FLAT_TEST_REJECTED + location msg only.
    R="$TMPBASE/a9_$_nm"; init_fixture "$R"
    mkdir -p "$R/tests"
    printf '%s\n' '# Tests: hooks/pre-commit' '# Tags: scope:common' > "$R/tests/$_nm"
    git -C "$R" add -- "tests/$_nm" >/dev/null 2>&1
    run_fm_check "$R"
    if [ "$RC" -ne 1 ] || ! printf '%s' "$OUT" | grep -qF 'FLAT_TEST_REJECTED' \
       || ! printf '%s' "$OUT" | grep -qF "$LOC_MSG" || printf '%s' "$OUT" | grep -qF "$FM_MSG"; then
        _a7_fail="$_a7_fail [A9 tests/$_nm: want rc 1 + FLAT_TEST_REJECTED + location msg only, got rc $RC out '$(printf '%s' "$OUT" | tr '\n' ' ')']"
    fi
done
if [ -n "$_a7_fail" ]; then
    fail "A7-A9: .Tests.ps1/test_*.py classification" "$_a7_fail"
else
    pass "A7-A9: .Tests.ps1/test_*.py — category-direct validated, sub-file skipped, new flat file location-rejected"
fi
case_end

# A10 (#2392): non-test entrypoints (helper.ps1, helper.py) are silently ignored —
# files not matching *.Tests.ps1 or test_*.py must pass through the gate as a no-op.
case_begin "A10-non-entrypoint-ignored" "hooks/lib/precommit-tests-frontmatter.sh"
_a10_fail=""
for _nm in helper.ps1 helper.py; do
    R="$TMPBASE/a10_$_nm"; init_fixture "$R"
    write_staged_nofm "$R" "tests/bin/$_nm"
    run_fm_check "$R"
    if [ "$RC" -ne 0 ]; then
        _a10_fail="$_a10_fail [tests/bin/$_nm: want rc 0, got $RC]"
    elif [ -n "$OUT" ]; then
        _a10_fail="$_a10_fail [tests/bin/$_nm: want no output, got '$(printf '%s' "$OUT" | tr '\n' ' ')']"
    fi
done
if [ -n "$_a10_fail" ]; then
    fail "A10: non-test entrypoints ignored" "gate not silent:$_a10_fail"
else
    pass "A10: helper.ps1 and helper.py are not test entrypoints — gate is a no-op (rc 0, no output)"
fi
case_end
