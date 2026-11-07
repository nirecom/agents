#!/bin/bash
# tests/tests/feature-689-run-all-all-flag/target-root-cases.sh — sourced by the dispatcher.
# Tests: tests/run-all.sh
# Tags: TL2, tests, run-all, repo-settings, migrate, scope:issue-specific
# #2473: the runner sweeps another repo through `RUN_ALL_TARGET_ROOT` (default: its own checkout),
# takes the categories from that repo's .agents.json only for --all / no argument, exits 6 with a
# /migrate hint when the tests section is missing or malformed, keeps a TESTS_DIR override first,
# and exports `AGENTS_TEST_HARNESS_DIR` to the tests it launches.
# TL3 gap: a real non-agents repo (dotfiles) through /run-tests; here the targets are fixtures.

# Without `RUN_ALL_TARGET_ROOT` support the runner would sweep this checkout's own tests/ instead
# of the fixture, so no case launches it until the variable is read.
target_supported() { grep -q 'RUN_ALL_TARGET_ROOT' "$RUN_ALL"; }
NO_TARGET='tests/run-all.sh does not read RUN_ALL_TARGET_ROOT yet — refusing to launch it (it would sweep the real tests/ tree)'

# rat_repo <name> <settings-json|-> — a git repo for the target fixtures; "-" = no .agents.json.
rat_repo() {
    local d="$TMPROOT/rat-$1"
    mkdir -p "$d"
    git init -q "$d" >/dev/null 2>&1
    git -C "$d" config core.hooksPath /dev/null
    [ "$2" = "-" ] || printf '%s\n' "$2" > "$d/.agents.json"
    printf '%s' "$d"
}
rat_test() {
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/bash\necho "%s HARNESS_DIR=[${AGENTS_TEST_HARNESS_DIR:-}]"\nexit 0\n' "$2" > "$1"
    chmod +x "$1"
}

# rat_run <root> [args...] — sets rat_out / RAT_RC; TESTS_DIR is emptied so the target decides.
rat_run() {
    local root="$1"
    shift
    rat_out="$(cd "$TMPROOT" && TESTS_DIR="" RUN_ALL_TARGET_ROOT="$root" run_with_timeout 120 bash "$RUN_ALL" "$@" 2>&1)"
    RAT_RC=$?
}

rat_setup() {
    unset RUN_ALL_TARGET_ROOT AGENTS_TEST_HARNESS_DIR
    local by_type='{"tests":{"dir":"tests","categorization":"by-type","categories":[{"dir":"unit"}],"supportDirs":["helpers"],"testHarness":"off","caseMarker":"off"}}'
    local flat='{"tests":{"dir":"tests","categorization":"flat","testHarness":"off","caseMarker":"off"}}'
    R_TYPE="$(rat_repo by-type "$by_type")"
    rat_test "$R_TYPE/tests/unit/t1.sh" MARKER_UNIT_T1
    rat_test "$R_TYPE/tests/helpers/h.sh" MARKER_HELPER_LEAKED
    rat_test "$R_TYPE/tests/other/o.sh" MARKER_OTHER_LEAKED
    R_FLAT="$(rat_repo flat "$flat")"
    rat_test "$R_FLAT/tests/f1.sh" MARKER_FLAT_F1
    R_NONE="$(rat_repo none -)"
    rat_test "$R_NONE/tests/unit/n1.sh" MARKER_NONE_N1
    R_BAD="$(rat_repo bad '{ not json')"
    rat_test "$R_BAD/tests/unit/b1.sh" MARKER_BAD_B1
    R_OVR="$(rat_repo override -)"
    rat_test "$R_OVR/tests/bin/ov1.sh" MARKER_OVERRIDE_RAN
}

test_RAT_by_type_target() {
    if ! target_supported; then fail "RAT_by_type_target: $NO_TARGET"; return; fi
    rat_run "$R_TYPE" --all
    if has_line MARKER_UNIT_T1 "$rat_out" && ! has_line 'MARKER_(HELPER|OTHER)_LEAKED' "$rat_out" && [ "$RAT_RC" -eq 0 ]; then
        pass "RAT_by_type_target: --all on a by-type target runs tests/unit/ only, rc=0"
    else
        fail "RAT_by_type_target: rc=$RAT_RC (want MARKER_UNIT_T1, no helpers/ or other/ marker, rc=0)"
        diag "$rat_out"
    fi
}

test_RAT_flat_target() {
    if ! target_supported; then fail "RAT_flat_target: $NO_TARGET"; return; fi
    rat_run "$R_FLAT"
    if [ "$RAT_RC" -eq 0 ] && has_line MARKER_FLAT_F1 "$rat_out"; then
        pass "RAT_flat_target: no argument on a flat target runs tests/<file>"
    else
        fail "RAT_flat_target: rc=$RAT_RC (want MARKER_FLAT_F1 and rc=0)"
        diag "$rat_out"
    fi
}

test_RAT_uninitialized_exit_6() {
    if ! target_supported; then fail "RAT_uninitialized_exit_6: $NO_TARGET"; return; fi
    local pair label root
    for pair in "missing:$R_NONE" "malformed:$R_BAD"; do
        label="${pair%%:*}"
        root="${pair#*:}"
        rat_run "$root" --all
        if [ "$RAT_RC" -eq 6 ] && has_fixed '/migrate' "$rat_out" && ! has_line 'MARKER_(NONE_N1|BAD_B1)' "$rat_out"; then
            pass "RAT_uninitialized_exit_6: $label tests section exits 6 with a /migrate hint and runs nothing"
        else
            fail "RAT_uninitialized_exit_6: $label tests section rc=$RAT_RC (want 6, a /migrate hint, no marker)"
            diag "$rat_out"
        fi
    done
}

# A TESTS_DIR override skips the settings check: the target has no .agents.json, yet its test runs.
test_RAT_tests_dir_override_first() {
    if ! target_supported; then fail "RAT_tests_dir_override_first: $NO_TARGET"; return; fi
    rat_out="$(cd "$TMPROOT" && TESTS_DIR="$R_OVR/tests" RUN_ALL_TARGET_ROOT="$R_OVR" run_with_timeout 120 bash "$RUN_ALL" --all 2>&1)"
    RAT_RC=$?
    if [ "$RAT_RC" -eq 0 ] && has_line MARKER_OVERRIDE_RAN "$rat_out" && ! has_fixed '/migrate' "$rat_out"; then
        pass "RAT_tests_dir_override_first: the override's test ran and the sweep exited 0 with no settings check"
    else
        fail "RAT_tests_dir_override_first: rc=$RAT_RC (want MARKER_OVERRIDE_RAN, no /migrate hint, rc=0)"
        diag "$rat_out"
    fi
}

test_RAT_positional_no_settings() {
    if ! target_supported; then fail "RAT_positional_no_settings: $NO_TARGET"; return; fi
    rat_run "$R_NONE" "$R_NONE/tests/unit/n1.sh"
    if [ "$RAT_RC" -eq 0 ] && has_line MARKER_NONE_N1 "$rat_out"; then
        pass "RAT_positional_no_settings: a positional file runs without reading the settings file"
    else
        fail "RAT_positional_no_settings: rc=$RAT_RC (want MARKER_NONE_N1 and rc=0)"
        diag "$rat_out"
    fi
}

test_RAT_harness_dir_export() {
    if ! target_supported; then fail "RAT_harness_dir_export: $NO_TARGET"; return; fi
    local got
    rat_run "$R_TYPE" "$R_TYPE/tests/unit/t1.sh"
    got="$(printf '%s\n' "$rat_out" | sed -n 's/.*MARKER_UNIT_T1 HARNESS_DIR=\[\(.*\)\].*/\1/p' | head -1)"
    if [ -n "$got" ] && [ -f "$got/harness.sh" ] && [ "$(cd "$got" && pwd -P)" = "$(cd "$SCRIPT_CHECKOUT_ROOT/tests/lib" && pwd -P)" ]; then
        pass "RAT_harness_dir_export: AGENTS_TEST_HARNESS_DIR points at the runner checkout's tests/lib"
    else
        fail "RAT_harness_dir_export: got=[$got] rc=$RAT_RC (want the runner checkout's tests/lib)"
        diag "$rat_out"
    fi
}
