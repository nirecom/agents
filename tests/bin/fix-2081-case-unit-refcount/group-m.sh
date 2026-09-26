# Group M: delete-gate interactions on partial-orphan (C3) (#2081)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, e2e, scope:issue-specific
# Sourced by tests/bin/fix-2081-case-unit-refcount.sh
#
# partial-orphan must pass trp_delete_gate exactly like whole orphan. An
# issue-specific feature-<N> file with issue N OPEN is held (hold-issue-active):
# reported, case NOT removed. Closing N to closed:stale fires the removal. A
# common file (no issue ref) fires immediately.

if ! require_fn trp_case_refcount_verdict "M0a"; then return 0; fi
if ! require_fn trp_remove_orphan_cases "M0b"; then return 0; fi

M_REPO="$(make_repo)"
add_src "$M_REPO" "bin/m-live.sh"
add_raw "$M_REPO" "feature-830-partial.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/m-live.sh, bin/m-dead.sh
# Tags: TL2, scope:issue-specific
case_begin "keep" "bin/m-live.sh"
echo keep-m-marker
case_end
case_begin "drop" "bin/m-dead.sh"
echo drop-m-marker
case_end
EOF
commit_repo "$M_REPO" "group-m gate fixture"

M_STUB="$TMPDIR_BASE/m-stub"
install_gh_mock "$M_STUB"

# ── M1: issue 830 OPEN → partial-orphan is held, case NOT removed ───────────
export MOCK_ISSUES="830 open"
run_in_repo "$M_REPO" "$M_STUB" "$AUDIT" --apply --format text
M1_OUT="$OUT"
if printf '%s\n' "$M1_OUT" | grep -qE "PARTIAL_ORPHAN: tests/feature-830-partial\.sh"; then
    pass "M1 open-issue partial-orphan is still reported (visibility kept)"
else
    fail "M1 expected PARTIAL_ORPHAN report for the open-issue file (out=<<$M1_OUT>>)"
fi
if printf '%s\n' "$M1_OUT" | grep -qE "CASE_REMOVED: tests/feature-830-partial\.sh"; then
    fail "M1b open-issue partial-orphan wrongly removed a case (hold-issue-active broken)"
else
    pass "M1b open-issue partial-orphan holds — no case removed"
fi
if printf '%s\n' "$(cat "$M_REPO/tests/feature-830-partial.sh")" | grep -q "drop-m-marker"; then
    pass "M1c orphan case still physically present while issue is open"
else
    fail "M1c orphan case was cut despite the open-issue hold"
fi
assert_eq "M1d nothing staged while held" "" "$(git -C "$M_REPO" status --porcelain)"

# ── M2: same file, issue 830 now closed:stale → removal fires ───────────────
export MOCK_ISSUES="830 closed 2019-01-01T00:00:00Z"
run_in_repo "$M_REPO" "$M_STUB" "$AUDIT" --apply --format text
M2_OUT="$OUT"
if printf '%s\n' "$M2_OUT" | grep -qE "CASE_REMOVED: tests/feature-830-partial\.sh"; then
    pass "M2 closed:stale issue fires the case removal"
else
    fail "M2 expected CASE_REMOVED once the issue is closed:stale (out=<<$M2_OUT>>)"
fi
if printf '%s\n' "$(cat "$M_REPO/tests/feature-830-partial.sh")" | grep -q "drop-m-marker"; then
    fail "M2b orphan case block survived after the gate cleared"
else
    pass "M2b orphan case block removed after the gate cleared"
fi

# ── M3: a common file (no issue ref) fires immediately ──────────────────────
M3_REPO="$(make_repo)"
add_src "$M3_REPO" "bin/m3-live.sh"
add_raw "$M3_REPO" "cc-partial-m.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/m3-live.sh, bin/m3-dead.sh
# Tags: TL2, scope:common
case_begin "keep" "bin/m3-live.sh"
echo keep-m3-marker
case_end
case_begin "drop" "bin/m3-dead.sh"
echo drop-m3-marker
case_end
EOF
commit_repo "$M3_REPO" "group-m common gate fixture"
export MOCK_ISSUES=""
run_in_repo "$M3_REPO" "$M_STUB" "$AUDIT_COMMON" --apply --format text
M3_OUT="$OUT"
if printf '%s\n' "$M3_OUT" | grep -qE "CASE_REMOVED: tests/cc-partial-m\.sh"; then
    pass "M3 common partial-orphan (no issue ref) fires removal immediately"
else
    fail "M3 expected CASE_REMOVED for the common file (out=<<$M3_OUT>>)"
fi

# ── M4 (C5): --offline --apply on an issue-specific partial-orphan holds ─────
# NOTE: passes after write-code step. Offline (or otherwise unavailable) issue
# metadata forces hold-metadata-unavailable: the partial-orphan is still
# reported, but no case is cut, nothing is staged, and the metadata hold token
# is issued. Fail-closed — an unknown issue state must never authorise a cut.
M4_REPO="$(make_repo)"
add_src "$M4_REPO" "bin/m4-live.sh"
add_raw "$M4_REPO" "feature-840-partial.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/m4-live.sh, bin/m4-dead.sh
# Tags: TL2, scope:issue-specific
case_begin "keep" "bin/m4-live.sh"
echo keep-m4-marker
case_end
case_begin "drop" "bin/m4-dead.sh"
echo drop-m4-marker
case_end
EOF
commit_repo "$M4_REPO" "group-m offline partial-orphan fixture"

# --offline: gh is never consulted, so no stub is needed ("-").
_M4_BEFORE="$(cat "$M4_REPO/tests/feature-840-partial.sh")"
run_in_repo "$M4_REPO" "-" "$AUDIT" --offline --apply --format text
M4_OUT="$OUT"; M4_RC="$RC"

if printf '%s\n' "$M4_OUT" | grep -qE "PARTIAL_ORPHAN: tests/feature-840-partial\.sh"; then
    pass "M4 offline partial-orphan is still reported (visibility kept)"
else
    fail "M4 expected PARTIAL_ORPHAN under --offline (out=<<$M4_OUT>> rc=$M4_RC)"
fi
if printf '%s\n' "$M4_OUT" | grep -qE "SKIP_DELETE_METADATA_UNAVAILABLE: tests/feature-840-partial\.sh"; then
    pass "M4b metadata hold token issued (hold-metadata-unavailable)"
else
    fail "M4b expected SKIP_DELETE_METADATA_UNAVAILABLE token (out=<<$M4_OUT>>)"
fi
if printf '%s\n' "$M4_OUT" | grep -qE "CASE_REMOVED: tests/feature-840-partial\.sh"; then
    fail "M4c offline hold wrongly removed a case"
else
    pass "M4c no case removed while metadata is unavailable"
fi
assert_eq "M4d orphan block byte-preserved under the offline hold" \
    "$_M4_BEFORE" "$(cat "$M4_REPO/tests/feature-840-partial.sh")"
assert_eq "M4e nothing staged under the offline hold" "" \
    "$(git -C "$M4_REPO" status --porcelain)"

unset _M4_BEFORE
unset MOCK_ISSUES
