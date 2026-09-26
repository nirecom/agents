# Group A: case enumeration from strict-form markers (#2081)
# Tests: bin/lib/test-retire-predicate/case-parser.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
# Sourced by tests/bin/fix-2081-case-unit-refcount.sh
#
# Strict form: column-0 `case_begin "name" "target"` with two static double-
# quoted args, and `case_end` with an optional C7 suffix (`|| true`,
# `>/dev/null 2>&1 || rc2=$?`). Enumeration must extract each target statically,
# record the begin/end line ranges, and count every case.

if ! require_fn trp_enumerate_cases "A0"; then return 0; fi

A_REPO="$(make_repo)"
add_src "$A_REPO" "bin/a1.sh"
add_src "$A_REPO" "bin/a2.sh"
add_src "$A_REPO" "bin/a3.sh"

# Three valid cases; case_end carries the two attested C7 suffix forms.
add_raw "$A_REPO" "fixt-a-valid.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a1.sh, bin/a2.sh, bin/a3.sh
# Tags: TL2, scope:issue-specific
case_begin "one" "bin/a1.sh"
echo hi
case_end
case_begin "two" "bin/a2.sh"
echo bye
case_end || true
case_begin "three" "bin/a3.sh"
echo more
case_end >/dev/null 2>&1 || rc2=$?
EOF
commit_repo "$A_REPO" "group-a valid enumeration"

run_enum "$A_REPO" "tests/fixt-a-valid.sh"

assert_eq "A1 markers detected" "1" "${TRP_HAS_MARKERS:-x}"
assert_eq "A2 not malformed" "0" "${_TRP_MARKER_MALFORMED:-x}"
assert_eq "A3 case count is three" "3" "${TRP_CASE_COUNT:-x}"
assert_eq "A4 targets extracted statically in order" \
    "bin/a1.sh bin/a2.sh bin/a3.sh" "$(join_sp "${TRP_CASE_TARGETS[@]:-}")"
assert_eq "A5 begin line ranges" "4 7 10" "$(join_sp "${TRP_CASE_BEGIN_LINES[@]:-}")"
assert_eq "A6 end line ranges (C7 suffix lines counted)" "6 9 12" \
    "$(join_sp "${TRP_CASE_END_LINES[@]:-}")"

# A7 — a single valid case is enumerated identically (boundary: one element).
A7_REPO="$(make_repo)"
add_src "$A7_REPO" "bin/a7.sh"
add_raw "$A7_REPO" "fixt-a7.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a7.sh
# Tags: TL2, scope:issue-specific
case_begin "solo" "bin/a7.sh"
echo one
case_end
EOF
commit_repo "$A7_REPO" "group-a single case"
run_enum "$A7_REPO" "tests/fixt-a7.sh"
assert_eq "A7 single case count" "1" "${TRP_CASE_COUNT:-x}"
assert_eq "A7b single target" "bin/a7.sh" "$(join_sp "${TRP_CASE_TARGETS[@]:-}")"
