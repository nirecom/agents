# Group B: strict-grammar fail-closed → file-level fallback (C1/C7/C8) (#2081)
# Tests: bin/lib/test-retire-predicate/case-parser.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
# Sourced by tests/fix-2081-case-unit-refcount.sh
#
# Any single non-strict marker call makes the whole file malformed: case-unit
# processing is skipped and the verdict is delegated to the file-level
# trp_survival_verdict (never SKIP/undeterminable — C8). Every fixture below
# carries an ALIVE `# Tests:` target, so the correct fallback verdict is `alive`.

if ! require_fn trp_enumerate_cases "B0a"; then return 0; fi
if ! require_fn trp_case_refcount_verdict "B0b"; then return 0; fi

B_REPO="$(make_repo)"
add_src "$B_REPO" "bin/live.sh"

# assert_malformed_alive <label> <rel> — malformed flag set, file-unit fallback,
# and the survival verdict is `alive` (the header target exists).
assert_malformed_alive() {
    local label="$1" rel="$2"
    run_enum "$B_REPO" "$rel"
    assert_eq "$label malformed flag set" "1" "${_TRP_MARKER_MALFORMED:-x}"
    run_verdict "$B_REPO" "$rel"
    assert_eq "$label file-unit fallback" "file" "${TRP_UNIT_MODE:-x}"
    assert_eq "$label fallback verdict alive (not SKIP/undeterminable)" \
        "alive" "${TRP_VERDICT:-x}"
}

# (a) expansion form — $N and ${VAR}
add_raw "$B_REPO" "b-a-expand.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/live.sh
# Tags: TL2, scope:issue-specific
case_begin "$2" "$3"
echo x
case_end
case_begin "n" "${VAR}"
echo y
case_end
EOF
# (b) indented / control-prefixed
add_raw "$B_REPO" "b-b-indented.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/live.sh
# Tags: TL2, scope:issue-specific
  case_begin "n" "bin/live.sh"
echo x
  case_end
EOF
add_raw "$B_REPO" "b-b-prefixed.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/live.sh
# Tags: TL2, scope:issue-specific
x=1 && case_begin "n" "bin/live.sh"
echo x
case_end
EOF
# (c) arity — too few / too many args
add_raw "$B_REPO" "b-c-few.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/live.sh
# Tags: TL2, scope:issue-specific
case_begin "n"
echo x
case_end
EOF
add_raw "$B_REPO" "b-c-many.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/live.sh
# Tags: TL2, scope:issue-specific
case_begin "n" "bin/live.sh" "extra"
echo x
case_end
EOF
# (d) unquoted args
add_raw "$B_REPO" "b-d-unquoted.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/live.sh
# Tags: TL2, scope:issue-specific
case_begin n p
echo x
case_end
EOF
# (e) target metacharacter / non-path
add_raw "$B_REPO" "b-e-metachar.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/live.sh
# Tags: TL2, scope:issue-specific
case_begin "n" "a;rm -rf x"
echo x
case_end
EOF
commit_repo "$B_REPO" "group-b malformed fixtures"

assert_malformed_alive "B1(a) expansion-form" "tests/b-a-expand.sh"
assert_malformed_alive "B2(b) indented" "tests/b-b-indented.sh"
assert_malformed_alive "B3(b) control-prefixed" "tests/b-b-prefixed.sh"
assert_malformed_alive "B4(c) too-few-args" "tests/b-c-few.sh"
assert_malformed_alive "B5(c) too-many-args" "tests/b-c-many.sh"
assert_malformed_alive "B6(d) unquoted-args" "tests/b-d-unquoted.sh"
assert_malformed_alive "B7(e) target-metachar" "tests/b-e-metachar.sh"

# B8 — the two attested C7 suffix forms are NOT malformed (symmetry with A).
B8_REPO="$(make_repo)"
add_src "$B8_REPO" "bin/b8.sh"
add_raw "$B8_REPO" "b8-suffix.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/b8.sh
# Tags: TL2, scope:issue-specific
case_begin "one" "bin/b8.sh"
echo x
case_end || true
case_begin "two" "bin/b8.sh"
echo y
case_end >/dev/null 2>&1 || rc2=$?
EOF
commit_repo "$B8_REPO" "group-b valid suffix"
run_enum "$B8_REPO" "tests/b8-suffix.sh"
assert_eq "B8 valid C7 suffixes are not malformed" "0" "${_TRP_MARKER_MALFORMED:-x}"

# B9 — the real tests/feature-2080-shared-harness.sh carries expansion-form
# `case_begin "$2" "$3"`, so it must be malformed → file-level fallback and
# therefore never retired as a case-unit orphan.
if [[ -f "$AGENTS_ROOT/tests/feature-2080-shared-harness.sh" ]]; then
    run_enum "$AGENTS_ROOT" "tests/feature-2080-shared-harness.sh"
    assert_eq "B9 real feature-2080-shared-harness.sh is malformed (expansion form)" \
        "1" "${_TRP_MARKER_MALFORMED:-x}"
else
    fail "B9 fixture-free real-file check skipped: feature-2080-shared-harness.sh not found"
fi
