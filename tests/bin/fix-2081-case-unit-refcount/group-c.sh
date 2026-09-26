# Group C: conditional-block & imbalance fail-closed (C2/C6) (#2081)
# Tests: bin/lib/test-retire-predicate/case-parser.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
# Sourced by tests/bin/fix-2081-case-unit-refcount.sh
#
# Markers inside if/while/for/case blocks (depth>0) and any imbalance are
# malformed → file-level fallback. C6: a top-level marker pair coexisting with a
# real case/esac block must NOT be misread as depth>0.

if ! require_fn trp_enumerate_cases "C0"; then return 0; fi

C_REPO="$(make_repo)"
add_src "$C_REPO" "bin/c.sh"

# c_mal <label> <rel> — asserts the enumerated fixture is malformed.
c_mal() {
    run_enum "$C_REPO" "$2"
    assert_eq "$1 malformed" "1" "${_TRP_MARKER_MALFORMED:-x}"
}

# depth>0: inside if
add_raw "$C_REPO" "c-if.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/c.sh
# Tags: TL2, scope:issue-specific
if true; then
case_begin "n" "bin/c.sh"
echo x
case_end
fi
EOF
# depth>0: inside while
add_raw "$C_REPO" "c-while.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/c.sh
# Tags: TL2, scope:issue-specific
while true; do
case_begin "n" "bin/c.sh"
case_end
break
done
EOF
# imbalance: missing case_end
add_raw "$C_REPO" "c-noend.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/c.sh
# Tags: TL2, scope:issue-specific
case_begin "n" "bin/c.sh"
echo x
EOF
# imbalance: case_end before case_begin
add_raw "$C_REPO" "c-endfirst.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/c.sh
# Tags: TL2, scope:issue-specific
case_end
case_begin "n" "bin/c.sh"
case_end
EOF
# imbalance: two consecutive begins
add_raw "$C_REPO" "c-doublebegin.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/c.sh
# Tags: TL2, scope:issue-specific
case_begin "a" "bin/c.sh"
case_begin "b" "bin/c.sh"
case_end
EOF
# imbalance: trailing begin (stream ends on begin)
add_raw "$C_REPO" "c-trailbegin.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/c.sh
# Tags: TL2, scope:issue-specific
case_begin "a" "bin/c.sh"
case_end
case_begin "b" "bin/c.sh"
EOF
commit_repo "$C_REPO" "group-c malformed fixtures"

c_mal "C1 marker inside if-block" "tests/c-if.sh"
c_mal "C2 marker inside while-block" "tests/c-while.sh"
c_mal "C3 missing case_end" "tests/c-noend.sh"
c_mal "C4 case_end before case_begin" "tests/c-endfirst.sh"
c_mal "C5 two consecutive case_begin" "tests/c-doublebegin.sh"
c_mal "C6 trailing case_begin" "tests/c-trailbegin.sh"

# C7 — C6 dedicated: a top-level marker pair PLUS a real case/esac block. The
# depth tracker must distinguish `case` from `case_begin`/`case_end` (exact
# token equality) so the markers are read at depth 0, not malformed.
C7_REPO="$(make_repo)"
add_src "$C7_REPO" "bin/c7.sh"
add_raw "$C7_REPO" "c7-caseblock.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/c7.sh
# Tags: TL2, scope:issue-specific
case_begin "one" "bin/c7.sh"
val=x
case "$val" in
  x) echo ex ;;
  *) echo other ;;
esac
case_end
EOF
commit_repo "$C7_REPO" "group-c C6 coexistence"
run_enum "$C7_REPO" "tests/c7-caseblock.sh"
assert_eq "C7 top-level markers not misread as depth>0 (C6)" "0" "${_TRP_MARKER_MALFORMED:-x}"
assert_eq "C7b one valid case enumerated alongside case/esac" "1" "${TRP_CASE_COUNT:-x}"

# C8 — malformed short-circuits BEFORE the balance check on mixed input: an
# indented marker plus an otherwise-balanced stream is still malformed.
add_raw "$C7_REPO" "c8-mixed.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/c7.sh
# Tags: TL2, scope:issue-specific
  case_begin "one" "bin/c7.sh"
case_end
case_begin "two" "bin/c7.sh"
case_end
EOF
commit_repo "$C7_REPO" "group-c mixed short-circuit"
run_enum "$C7_REPO" "tests/c8-mixed.sh"
assert_eq "C8 malformed short-circuits balance check on mixed input" \
    "1" "${_TRP_MARKER_MALFORMED:-x}"
