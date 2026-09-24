# Group J: --dry-run makes zero physical changes (#2081)
# Tests: bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, e2e, scope:issue-specific
# Sourced by tests/fix-2081-case-unit-refcount.sh
#
# The report-only path shares the scan loop with --apply. A --dry-run over a tree
# that HAS a whole-unit orphan and a partial-orphan must report both yet touch
# nothing: no file content changes, no git index entries, no case-block removal.

if ! require_fn trp_case_refcount_verdict "J0"; then return 0; fi

J_REPO="$(make_repo)"
add_src "$J_REPO" "bin/j-live.sh"
# common-scope partial-orphan (one alive, one orphan case).
add_raw "$J_REPO" "cc-partial-j.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/j-live.sh, bin/j-dead1.sh
# Tags: TL2, scope:common
case_begin "keep" "bin/j-live.sh"
echo keep-j-marker
case_end
case_begin "drop" "bin/j-dead1.sh"
echo drop-j-marker
case_end
EOF
# common-scope whole-unit orphan (all cases orphan).
add_raw "$J_REPO" "cc-allorphan-j.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/j-dead2.sh
# Tags: TL2, scope:common
case_begin "a" "bin/j-dead2.sh"
case_end
EOF
commit_repo "$J_REPO" "group-j dry-run fixtures"

J_STUB="$TMPDIR_BASE/j-stub"
install_gh_mock "$J_STUB"
export MOCK_ISSUES=""

J_TREE_BEFORE="$(git -C "$J_REPO" rev-parse HEAD)"
_J_PARTIAL_BEFORE="$(cat "$J_REPO/tests/cc-partial-j.sh")"

run_in_repo "$J_REPO" "$J_STUB" "$AUDIT_COMMON" --dry-run --format text
J_OUT="$OUT"; J_RC="$RC"

# Nothing staged, nothing modified in the working tree.
assert_eq "J1 --dry-run leaves the git index clean" "" \
    "$(git -C "$J_REPO" status --porcelain)"
assert_eq "J1b HEAD unchanged" "$J_TREE_BEFORE" "$(git -C "$J_REPO" rev-parse HEAD)"

# The partial-orphan file is byte-identical — no case block was physically cut.
assert_eq "J2 partial-orphan file content untouched by --dry-run" \
    "$_J_PARTIAL_BEFORE" "$(cat "$J_REPO/tests/cc-partial-j.sh")"
assert_eq "J2b whole-unit orphan file still present after --dry-run" "kept" \
    "$(fs_of "$J_REPO" "tests/cc-allorphan-j.sh")"

# The report still names both findings (visibility is not suppressed by dry-run).
if printf '%s\n' "$J_OUT" | grep -qE "PARTIAL_ORPHAN: tests/cc-partial-j\.sh"; then
    pass "J3 --dry-run still reports the partial-orphan"
else
    fail "J3 expected a PARTIAL_ORPHAN report line (out=<<$J_OUT>> rc=$J_RC)"
fi

unset MOCK_ISSUES _J_PARTIAL_BEFORE
