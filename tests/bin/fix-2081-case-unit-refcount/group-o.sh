# Group O: apply-by-default — no flag fires removal on both entrypoints (C4) (#2081)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, e2e, scope:issue-specific
# Sourced by tests/bin/fix-2081-case-unit-refcount.sh
#
# sweep-write-mode is apply-by-default: a flagless run writes, --dry-run reports
# only, --apply is a backward-compatible synonym. Every other mutation group
# passes --apply explicitly; this group proves the DEFAULT (no flag) also fires
# removal, on BOTH entrypoints — audit-tests.sh (issue-specific, whole-unit GC)
# and audit-tests-common.sh (common, partial-orphan case removal).

if ! require_fn trp_case_refcount_verdict "O0"; then return 0; fi

O_STUB="$TMPDIR_BASE/o-stub"
install_gh_mock "$O_STUB"

# ── O1: audit-tests.sh with NO flag → whole-unit GC fires (closed:stale) ─────
O1_REPO="$(make_repo)"
add_raw "$O1_REPO" "feature-850-allorphan.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/o-dead1.sh, bin/o-dead2.sh
# Tags: TL2, scope:issue-specific
case_begin "a" "bin/o-dead1.sh"
case_end
case_begin "b" "bin/o-dead2.sh"
case_end
EOF
commit_repo "$O1_REPO" "group-o apply-by-default issue-specific fixture"
export MOCK_ISSUES="850 closed 2019-01-01T00:00:00Z"
run_in_repo "$O1_REPO" "$O_STUB" "$AUDIT" --format text
O1_OUT="$OUT"; O1_RC="$RC"
if line_has "$O1_OUT" DELETED "tests/feature-850-allorphan.sh"; then
    pass "O1 audit-tests.sh removal fires with NO flag (apply-by-default)"
else
    fail "O1 expected DELETED with no flag on audit-tests.sh (out=<<$O1_OUT>> rc=$O1_RC)"
fi
assert_eq "O1b file physically removed by the flagless run" "gone" \
    "$(fs_of "$O1_REPO" "tests/feature-850-allorphan.sh")"
assert_eq "O1c the flagless deletion is staged" \
    "D  tests/feature-850-allorphan.sh" \
    "$(git -C "$O1_REPO" status --porcelain -- tests/feature-850-allorphan.sh)"

# ── O2: audit-tests-common.sh with NO flag → partial-orphan case removal fires ─
# NOTE: passes after write-code step — partial-orphan case removal is #2081.
O2_REPO="$(make_repo)"
add_src "$O2_REPO" "bin/o2-live.sh"
add_raw "$O2_REPO" "cc-partial-o.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/o2-live.sh, bin/o2-dead.sh
# Tags: TL2, scope:common
case_begin "keep" "bin/o2-live.sh"
echo keep-o-marker
case_end
case_begin "drop" "bin/o2-dead.sh"
echo drop-o-marker
case_end
EOF
commit_repo "$O2_REPO" "group-o apply-by-default common fixture"
export MOCK_ISSUES=""
run_in_repo "$O2_REPO" "$O_STUB" "$AUDIT_COMMON" --format text
O2_OUT="$OUT"; O2_RC="$RC"
if line_has "$O2_OUT" CASE_REMOVED "tests/cc-partial-o.sh"; then
    pass "O2 audit-tests-common.sh case removal fires with NO flag"
else
    fail "O2 expected CASE_REMOVED with no flag on audit-tests-common.sh (out=<<$O2_OUT>> rc=$O2_RC)"
fi
if printf '%s\n' "$(cat "$O2_REPO/tests/cc-partial-o.sh")" | grep -q "drop-o-marker"; then
    fail "O2b flagless run did not cut the orphan case"
else
    pass "O2b orphan case cut by the flagless run"
fi
if printf '%s\n' "$(cat "$O2_REPO/tests/cc-partial-o.sh")" | grep -q "keep-o-marker"; then
    pass "O2c surviving case body preserved through the flagless run"
else
    fail "O2c surviving case body lost by the flagless run"
fi

# ── O3: audit-tests.sh NO flag → issue-specific partial-orphan case removal ───
# The issue-specific twin of O2: a feature-<N> file (issue N closed:stale) with
# one live and one orphan case. The flagless (apply-by-default) run on
# audit-tests.sh must fire partial-orphan CASE removal (not whole-unit GC),
# proving the default write path covers partial-orphan on the issue-specific
# entrypoint too — the gap O1 (whole-unit) and O2 (common) leave open.
# NOTE: passes after write-code step — partial-orphan case removal is #2081.
O3_REPO="$(make_repo)"
add_src "$O3_REPO" "bin/o3-live.sh"
add_raw "$O3_REPO" "feature-855-partial.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/o3-live.sh, bin/o3-dead.sh
# Tags: TL2, scope:issue-specific
case_begin "keep" "bin/o3-live.sh"
echo keep-o3-marker
case_end
case_begin "drop" "bin/o3-dead.sh"
echo drop-o3-marker
case_end
EOF
commit_repo "$O3_REPO" "group-o apply-by-default issue-specific partial fixture"
export MOCK_ISSUES="855 closed 2019-01-01T00:00:00Z"
run_in_repo "$O3_REPO" "$O_STUB" "$AUDIT" --format text
O3_OUT="$OUT"; O3_RC="$RC"
if line_has "$O3_OUT" CASE_REMOVED "tests/feature-855-partial.sh"; then
    pass "O3 audit-tests.sh partial-orphan case removal fires with NO flag"
else
    fail "O3 expected CASE_REMOVED with no flag on audit-tests.sh (out=<<$O3_OUT>> rc=$O3_RC)"
fi
if line_has "$O3_OUT" DELETED "tests/feature-855-partial.sh"; then
    fail "O3b partial-orphan wrongly whole-unit-GC'd instead of case-removed"
else
    pass "O3b partial-orphan took case-removal path, not whole-unit GC"
fi
if printf '%s\n' "$(cat "$O3_REPO/tests/feature-855-partial.sh")" | grep -q "drop-o3-marker"; then
    fail "O3c flagless run did not cut the issue-specific orphan case"
else
    pass "O3c issue-specific orphan case cut by the flagless run"
fi
if printf '%s\n' "$(cat "$O3_REPO/tests/feature-855-partial.sh")" | grep -q "keep-o3-marker"; then
    pass "O3d surviving case body preserved through the flagless run"
else
    fail "O3d surviving case body lost by the flagless run"
fi

unset MOCK_ISSUES
