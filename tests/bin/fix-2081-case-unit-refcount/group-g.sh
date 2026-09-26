# Group G: whole-unit GC on refcount==0 (file + sibling folder) e2e (#2081)
# Tests: bin/audit-tests.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, e2e, scope:issue-specific
# Sourced by tests/bin/fix-2081-case-unit-refcount.sh
#
# A case-unit file whose every case is orphan → refcount 0 → verdict orphan →
# the current whole-unit git rm (dispatcher + sibling folder). The delete gate
# still governs: a closed:stale issue fires the removal, an OPEN issue holds it.

if ! require_fn trp_case_refcount_verdict "G0"; then return 0; fi

G_REPO="$(make_repo)"
# Two dispatchers, each a valid case-unit with BOTH cases orphan (targets gone).
add_raw "$G_REPO" "feature-810-allorphan.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/g-dead1.sh, bin/g-dead2.sh
# Tags: TL2, scope:issue-specific
case_begin "a" "bin/g-dead1.sh"
case_end
case_begin "b" "bin/g-dead2.sh"
case_end
EOF
mkdir -p "$G_REPO/tests/feature-810-allorphan"
printf '#!/usr/bin/env bash\necho sib\n' > "$G_REPO/tests/feature-810-allorphan/part.sh"
add_raw "$G_REPO" "feature-811-allorphan.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/g-dead3.sh, bin/g-dead4.sh
# Tags: TL2, scope:issue-specific
case_begin "a" "bin/g-dead3.sh"
case_end
case_begin "b" "bin/g-dead4.sh"
case_end
EOF
commit_repo "$G_REPO" "group-g whole-unit GC fixtures"

G_STUB="$TMPDIR_BASE/g-stub"
install_gh_mock "$G_STUB"
export MOCK_ISSUES="810 closed 2019-01-01T00:00:00Z
811 open"

run_in_repo "$G_REPO" "$G_STUB" "$AUDIT" --apply --format text
G_OUT="$OUT"; G_RC="$RC"

# 810 is a candidate whose gate clears (closed+stale) → whole unit removed.
assert_eq "G1 refcount-0 case-unit reported as candidate" \
    "1" "$(count_lines "$G_OUT" DELETED)"
assert_eq "G1b the deleted dispatcher is feature-810" "gone" \
    "$(fs_of "$G_REPO" "tests/feature-810-allorphan.sh")"
assert_eq "G1c the sibling folder went with it (whole-unit GC)" "gone" \
    "$(fs_of "$G_REPO" "tests/feature-810-allorphan")"

# 811 is an identical candidate but its OPEN issue holds the removal → kept.
assert_eq "G2 open-issue candidate is held, not deleted" "kept" \
    "$(fs_of "$G_REPO" "tests/feature-811-allorphan.sh")"
if printf '%s\n' "$G_OUT" | grep -qE "^(SKIP_[A-Z_]+|HOLD[A-Z_]*): tests/feature-811-allorphan\.sh"; then
    pass "G2b feature-811 emitted a hold/skip token, not a deletion"
else
    fail "G2b expected a hold token for feature-811 (out=<<$G_OUT>> rc=$G_RC)"
fi

# G3 — the index holds exactly the staged deletions of the fired unit, nothing
# from the held one.
G_STAGED="$(git -C "$G_REPO" status --porcelain | sort)"
assert_eq "G3 index holds exactly the fired unit's staged deletions" \
"D  tests/feature-810-allorphan.sh
D  tests/feature-810-allorphan/part.sh" "$G_STAGED"

unset MOCK_ISSUES

# ── C3 — audit-tests-common.sh --apply: whole-unit GC + dead .Tests.ps1/.py ──
# Orthogonal sibling of the issue-specific GC above (CPR-ORTH): the common
# entrypoint deletes a refcount-0 case-unit (dispatcher + populated sibling
# folder) whole and stages it, and — once #1864 adds them to the scan globs —
# deletes a dead .Tests.ps1 / test_*.py (marker-less file-unit, extension guard)
# the same way.
GC_REPO="$(make_repo)"
# common whole-unit orphan (.sh) with a populated sibling folder.
add_raw "$GC_REPO" "cc-allorphan-g.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/gc-dead1.sh, bin/gc-dead2.sh
# Tags: TL2, scope:common
case_begin "a" "bin/gc-dead1.sh"
case_end
case_begin "b" "bin/gc-dead2.sh"
case_end
EOF
mkdir -p "$GC_REPO/tests/cc-allorphan-g"
printf '#!/usr/bin/env bash\necho sib\n' > "$GC_REPO/tests/cc-allorphan-g/part.sh"
# dead common .Tests.ps1 and test_*.py (marker-less, extension guard).
add_raw "$GC_REPO" "cc-dead-g.Tests.ps1" <<'EOF'
# Tests: bin/gc-dead.ps1
# Tags: TL2, scope:common
Describe 'x' { It 'runs' { $true | Should -Be $true } }
EOF
add_raw "$GC_REPO" "test_g_apply.py" <<'EOF'
# Tests: bin/gc-dead.py
# Tags: TL2, scope:common
def test_x():
    assert True
EOF
commit_repo "$GC_REPO" "group-g common-entrypoint apply fixtures"

GC_STUB="$TMPDIR_BASE/gc-stub"
install_gh_mock "$GC_STUB"
export MOCK_ISSUES=""
run_in_repo "$GC_REPO" "$GC_STUB" "$AUDIT_COMMON" --apply --format text
GC_OUT="$OUT"; GC_RC="$RC"

# Whole-unit GC: dispatcher + sibling folder both gone and staged.
if line_has "$GC_OUT" DELETED "tests/cc-allorphan-g.sh"; then
    pass "G4 common refcount-0 case-unit deleted via --apply"
else
    fail "G4 expected DELETED for the common whole-unit orphan (out=<<$GC_OUT>> rc=$GC_RC)"
fi
assert_eq "G4b common dispatcher gone" "gone" "$(fs_of "$GC_REPO" "tests/cc-allorphan-g.sh")"
assert_eq "G4c sibling folder went with it (whole-unit GC)" "gone" \
    "$(fs_of "$GC_REPO" "tests/cc-allorphan-g")"
GC_STAGED="$(git -C "$GC_REPO" status --porcelain | grep -E 'cc-allorphan-g' | sort)"
assert_eq "G4d both unit paths staged as deletions" \
"D  tests/cc-allorphan-g.sh
D  tests/cc-allorphan-g/part.sh" "$GC_STAGED"

# NOTE: passes after write-code step — #1864 adds .Tests.ps1/test_*.py to the
# common scan globs; before that they are not scanned and nothing fires.
if line_has "$GC_OUT" DELETED "tests/cc-dead-g.Tests.ps1"; then
    pass "G5 dead common .Tests.ps1 deleted via --apply"
else
    fail "G5 expected DELETED for dead .Tests.ps1 — NOTE: passes after write-code step (out=<<$GC_OUT>>)"
fi
if line_has "$GC_OUT" DELETED "tests/test_g_apply.py"; then
    pass "G5b dead test_*.py deleted via --apply"
else
    fail "G5b expected DELETED for dead test_*.py — NOTE: passes after write-code step (out=<<$GC_OUT>>)"
fi

unset MOCK_ISSUES
