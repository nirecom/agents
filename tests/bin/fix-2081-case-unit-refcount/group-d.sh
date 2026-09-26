# Group D: refcount judgment — orphan / partial-orphan / alive (#2081)
# Tests: bin/lib/test-retire-predicate.sh, bin/lib/test-retire-predicate/case-parser.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
# Sourced by tests/bin/fix-2081-case-unit-refcount.sh
#
# refcount = surviving-case count. All cases orphan → refcount 0 / verdict
# orphan (whole-unit GC). Some orphan → partial-orphan. None orphan → alive.

if ! require_fn trp_case_refcount_verdict "D0"; then return 0; fi

D_REPO="$(make_repo)"
add_src "$D_REPO" "bin/d-live1.sh"
add_src "$D_REPO" "bin/d-live2.sh"
# bin/d-dead1.sh and bin/d-dead2.sh are intentionally never created.

# All orphan → refcount 0 / orphan.
add_raw "$D_REPO" "d-allorphan.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/d-dead1.sh, bin/d-dead2.sh
# Tags: TL2, scope:issue-specific
case_begin "a" "bin/d-dead1.sh"
case_end
case_begin "b" "bin/d-dead2.sh"
case_end
EOF
# Some orphan → partial-orphan.
add_raw "$D_REPO" "d-partial.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/d-live1.sh, bin/d-dead1.sh
# Tags: TL2, scope:issue-specific
case_begin "a" "bin/d-live1.sh"
case_end
case_begin "b" "bin/d-dead1.sh"
case_end
EOF
# None orphan → alive.
add_raw "$D_REPO" "d-alive.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/d-live1.sh, bin/d-live2.sh
# Tags: TL2, scope:issue-specific
case_begin "a" "bin/d-live1.sh"
case_end
case_begin "b" "bin/d-live2.sh"
case_end
EOF
commit_repo "$D_REPO" "group-d refcount fixtures"

run_verdict "$D_REPO" "tests/d-allorphan.sh"
assert_eq "D1 all-orphan verdict" "orphan" "${TRP_VERDICT:-x}"
assert_eq "D1b all-orphan refcount 0" "0" "${TRP_REFCOUNT:-x}"
assert_eq "D1c unit mode case" "case" "${TRP_UNIT_MODE:-x}"

run_verdict "$D_REPO" "tests/d-partial.sh"
assert_eq "D2 partial-orphan verdict" "partial-orphan" "${TRP_VERDICT:-x}"
assert_eq "D2b partial refcount 1" "1" "${TRP_REFCOUNT:-x}"
assert_eq "D2c one orphan case indexed" "1" "${#TRP_ORPHAN_CASE_IDX[@]}"

run_verdict "$D_REPO" "tests/d-alive.sh"
assert_eq "D3 alive verdict" "alive" "${TRP_VERDICT:-x}"
assert_eq "D3b alive refcount 2" "2" "${TRP_REFCOUNT:-x}"
assert_eq "D3c no orphan cases indexed" "0" "${#TRP_ORPHAN_CASE_IDX[@]}"
