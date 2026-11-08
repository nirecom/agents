#!/bin/bash
# tests/tests/feature-689-run-all-all-flag/dispatch-cases.sh — sourced by the dispatcher.
# Tests: tests/run-all.sh
# Tags: bin, tests, scope:issue-specific
# C1-C4c: --all, the default sweep minus _archive/, a missing TESTS_DIR, the default tests dir
# resolution, and a positional file over a TESTS_DIR pin.

# C1: `--all` sweeps exactly the fixture suite pointed at by TESTS_DIR.
test_C1_all_flag_iterates() {
    if ! tests_dir_override_supported; then
        fail "C1_all_flag_iterates: $MISSING_OVERRIDE"
        return
    fi
    local out rc dispatch contract
    out="$(TESTS_DIR="$FX/tests" run_with_timeout 60 bash "$RUN_ALL" --all 2>&1)"
    rc=$?
    dispatch="$(count_lines '^(PASS|FAIL|SKIP): ' "$out")"
    contract="$(count_lines '^RUN_CONTRACT: PASS=2 FAIL=1 SKIP=1 EXECUTED=4 UNRUNNABLE=0 TIMEOUT=0$' "$out")"
    if [ "$dispatch" = "4" ] && [ "$contract" = "1" ] && [ "$rc" = "1" ]; then
        pass "C1_all_flag_iterates: --all swept exactly the 4 fixture tests (rc=$rc)"
    else
        fail "C1_all_flag_iterates: dispatch=$dispatch contract=$contract rc=$rc (want 4 verdict lines, one contract line PASS=2 FAIL=1 SKIP=1 EXECUTED=4 UNRUNNABLE=0 TIMEOUT=0, rc=1)"
        diag "$out"
    fi
}

# C2: a single positional file argument runs exactly that file.
test_C2_positional_single_file() {
    local target="$TMPROOT/lone/only-this.sh"
    mkdir -p "$TMPROOT/lone"
    printf '#!/bin/bash\necho MARKER_LONE\nexit 0\n' > "$target"
    chmod +x "$target"
    local out rc dispatch marker
    out="$(run_with_timeout 60 bash "$RUN_ALL" "$target" 2>&1)"
    rc=$?
    dispatch="$(count_lines '^(PASS|FAIL|SKIP): ' "$out")"
    marker="$(count_lines 'MARKER_LONE' "$out")"
    if [ "$dispatch" = "1" ] && [ "$marker" -ge 1 ] && [ "$rc" = "0" ]; then
        pass "C2_positional_single_file: only the named file ran (dispatch=$dispatch marker=$marker)"
    else
        fail "C2_positional_single_file: dispatch=$dispatch marker=$marker rc=$rc (want 1 verdict line, marker>=1, rc=0)"
        diag "$out"
    fi
}

# C3: the default (no-argument) sweep excludes <tests>/_archive/.
test_C3_default_excludes_archive() {
    if ! tests_dir_override_supported; then
        fail "C3_default_excludes_archive: $MISSING_OVERRIDE"
        return
    fi
    local out rc
    out="$(TESTS_DIR="$FX/tests" run_with_timeout 60 bash "$RUN_ALL" 2>&1)"
    rc=$?
    if ! has_line 'MARKER_ARCHIVE_LEAKED' "$out" && has_line 'EXECUTED=4 UNRUNNABLE=0 TIMEOUT=0$' "$out"; then
        pass "C3_default_excludes_archive: default sweep ran the 4 bin/ fixture tests and skipped _archive/"
    else
        fail "C3_default_excludes_archive: archive sentinel leaked or EXECUTED was not 4 (rc=$rc)"
        diag "$out"
    fi
}

# C4(a): a TESTS_DIR pointing at a non-existent directory sweeps nothing (zero selected → 77, #2501).
test_C4a_missing_tests_dir() {
    if ! tests_dir_override_supported; then
        fail "C4a_missing_tests_dir: $MISSING_OVERRIDE"
        return
    fi
    local out rc
    out="$(TESTS_DIR="$TMPROOT/does-not-exist" run_with_timeout 60 bash "$RUN_ALL" --all 2>&1)"
    rc=$?
    if has_line 'EXECUTED=0 UNRUNNABLE=0 TIMEOUT=0$' "$out" && [ "$rc" = "77" ]; then
        pass "C4a_missing_tests_dir: non-existent TESTS_DIR executes nothing and exits 77"
    else
        fail "C4a_missing_tests_dir: rc=$rc (want an EXECUTED=0 contract line and rc=77)"
        diag "$out"
    fi
}

# C4(b): default resolution — with TESTS_DIR empty and with it unset, the
# copied runner must resolve its tests dir from its own SCRIPT_CHECKOUT_ROOT. Exercised
# only against the fixture copy; the real tests/ tree is never launched.
test_C4b_default_from_agents_dir() {
    local out rc unset_out unset_rc ok=1
    out="$(TESTS_DIR="" run_with_timeout 60 bash "$FIXTURE_RUNNER" --all 2>&1)"
    rc=$?
    unset_out="$(unset TESTS_DIR; run_with_timeout 60 bash "$FIXTURE_RUNNER" --all 2>&1)"
    unset_rc=$?
    has_line 'EXECUTED=4 UNRUNNABLE=0 TIMEOUT=0$' "$out" || ok=0
    has_line 'MARKER_T1' "$out" || ok=0
    [ "$rc" = "1" ] || ok=0
    has_line 'EXECUTED=4 UNRUNNABLE=0 TIMEOUT=0$' "$unset_out" || ok=0
    has_line 'MARKER_T1' "$unset_out" || ok=0
    [ "$unset_rc" = "1" ] || ok=0
    # Mechanical proof that the repository's own suite was not swept.
    ! has_fixed "$SCRIPT_CHECKOUT_ROOT/tests/" "$out" || ok=0
    ! has_fixed "$SCRIPT_CHECKOUT_ROOT/tests/" "$unset_out" || ok=0
    if [ "$ok" = "1" ]; then
        pass "C4b_default_from_agents_dir: empty and unset TESTS_DIR both fall back to the fixture repo's own tests dir"
    else
        fail "C4b_default_from_agents_dir: empty-rc=$rc unset-rc=$unset_rc (want EXECUTED=4 + MARKER_T1 + rc=1 for both, and no real tests/ path in the output)"
        diag "$out"
        diag "$unset_out"
    fi
}

# C4(c): a positional argument wins over TESTS_DIR.
test_C4c_positional_beats_tests_dir() {
    local target="$TMPROOT/pos/named-only.sh"
    mkdir -p "$TMPROOT/pos"
    printf '#!/bin/bash\necho MARKER_NAMED\nexit 0\n' > "$target"
    chmod +x "$target"
    local out rc dispatch ok=1
    out="$(TESTS_DIR="$FX/tests" run_with_timeout 60 bash "$RUN_ALL" "$target" 2>&1)"
    rc=$?
    dispatch="$(count_lines '^(PASS|FAIL|SKIP): ' "$out")"
    [ "$dispatch" = "1" ] || ok=0
    has_line 'MARKER_NAMED' "$out" || ok=0
    ! has_line 'MARKER_T1' "$out" || ok=0
    [ "$rc" = "0" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "C4c_positional_beats_tests_dir: only the named file ran despite a TESTS_DIR pin (dispatch=$dispatch)"
    else
        fail "C4c_positional_beats_tests_dir: dispatch=$dispatch rc=$rc (want only the named file to run)"
        diag "$out"
    fi
}
