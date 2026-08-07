# Group J: idempotency — a second --apply is a clean no-op (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh
# Tags: TL2, audit-tests, retire, idempotency, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# /sweep-tests and the nightly cron both re-run against a tree that may already
# be swept. After the first pass the candidate is gone from the working tree but
# still present in HEAD until the commit lands, which is exactly the window in
# which a re-scan can try to `git rm` a path that is no longer there. The second
# run must therefore report nothing, delete nothing, add nothing to the index,
# and exit 1 (no findings) rather than surfacing a git error.

J_REPO="$(make_repo)"
add_src "$J_REPO" "bin/alive-j.sh"
add_test_file "$J_REPO" "feature-951-orphan.sh" "bin/gone-j1.sh" "TL2, scope:issue-specific"
add_test_file "$J_REPO" "feature-952-alive.sh" "bin/alive-j.sh" "TL2, scope:issue-specific"
add_test_file "$J_REPO" "cc-orphan-j.sh" "bin/gone-j2.sh"
add_test_file "$J_REPO" "cc-alive-j.sh" "bin/alive-j.sh"
commit_repo "$J_REPO" "idempotency fixture"

J_STUB="$TMPDIR_BASE/j-stub"
install_gh_mock "$J_STUB"
export MOCK_ISSUES="951 closed 2019-01-01T00:00:00Z
952 closed 2019-01-01T00:00:00Z"

# ── J1: first --apply pass removes the two orphans ─────────────────────────

run_in_repo "$J_REPO" "$J_STUB" "$AUDIT" --apply --format text
J1_OUT="$OUT"; J1_RC="$RC"
run_in_repo "$J_REPO" "$J_STUB" "$AUDIT_COMMON" --apply --format text
J1C_OUT="$OUT"; J1C_RC="$RC"

assert_gate_row "J1a first pass deletes the issue-specific orphan" \
    "$J1_OUT" "$J_REPO" "tests/feature-951-orphan.sh" candidate deleted gone
assert_gate_row "J1b first pass deletes the common orphan" \
    "$J1C_OUT" "$J_REPO" "tests/cc-orphan-j.sh" orphan deleted gone
assert_eq "J1c first pass exits 0 on both scripts (findings present)" "0 0" "$J1_RC $J1C_RC"

J_STATE_AFTER_1="$(git -C "$J_REPO" status --porcelain | sort)"

# ── J2: second --apply pass over the identical tree ────────────────────────

run_in_repo "$J_REPO" "$J_STUB" "$AUDIT" --apply --format text
J2_OUT="$OUT"; J2_RC="$RC"; J2_ERR="$ERR"
run_in_repo "$J_REPO" "$J_STUB" "$AUDIT_COMMON" --apply --format text
J2C_OUT="$OUT"; J2C_RC="$RC"; J2C_ERR="$ERR"

assert_eq "J2a second pass re-reports nothing (audit-tests)" \
    "0 0" "$(count_lines "$J2_OUT" CANDIDATE) $(count_lines "$J2_OUT" DELETED)"
assert_eq "J2b second pass re-reports nothing (audit-tests-common)" \
    "0 0" "$(count_lines "$J2C_OUT" ORPHAN) $(count_lines "$J2C_OUT" DELETED)"
assert_eq "J2c second pass exits 1 on both scripts (no findings, not an error)" \
    "1 1" "$J2_RC $J2C_RC"

# J2d — no git error may leak: re-running must not attempt to remove a path that
# is already gone from the working tree.
if echo "$J2_ERR$J2C_ERR" | grep -qiE "fatal:|did not match any files|pathspec"; then
    fail "J2d second pass surfaced a git error (audit=<<$J2_ERR>> common=<<$J2C_ERR>>)"
else
    pass "J2d second pass surfaces no git error"
fi

# J2e — the index is byte-identical to the state the first pass left behind: the
# re-run neither re-staged nor un-staged anything.
assert_eq "J2e the index is unchanged by the second pass" \
    "$J_STATE_AFTER_1" "$(git -C "$J_REPO" status --porcelain | sort)"

# J2f — and the files that were never candidates are still untouched.
assert_eq "J2f live-target files survived both passes" \
    "kept kept" \
    "$(fs_of "$J_REPO" "tests/feature-952-alive.sh") $(fs_of "$J_REPO" "tests/cc-alive-j.sh")"

# ── J3: --dry-run after --apply is likewise clean ──────────────────────────
# The report-only path shares the scan loop, so it needs its own confirmation
# that an already-swept tree yields the zero-result exit code.

run_in_repo "$J_REPO" "$J_STUB" "$AUDIT" --dry-run --format json
J3_JSON="$OUT"; J3_RC="$RC"
if json_parses "$J3_JSON" && [[ "$J3_RC" -eq 1 ]]; then
    pass "J3a --dry-run over an already-swept tree exits 1 with parseable JSON"
else
    fail "J3a expected exit 1 + parseable JSON after sweeping (rc=$J3_RC out=<<$J3_JSON>>)"
fi
assert_eq "J3b no candidate remains in the JSON document" \
    "0" "$(json_query "$J3_JSON" '(d.candidates||["x"]).length')"

unset MOCK_ISSUES
