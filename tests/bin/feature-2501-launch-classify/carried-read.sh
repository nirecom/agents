# tests/bin/feature-2501-launch-classify/carried-read.sh
# Tests: bin/lib/run-all-launch.sh
# Tags: TL2, bin, run-all, launch, carried-settings, scope:issue-specific
# shellcheck shell=bash
# run_all_carried_read (#2997): prints KEY=VALUE for RUN_TL3 / RUN_TL4 — the environment first, else the
# real setting (a stub get-config-var here) — and omits an empty value. Sourced by the dispatcher.
# TL3 gap (not caught here): a stub get-config-var always succeeds, so a real session whose actual
# settings read fails (settings dir not found, bridge names unreadable) still carries nothing; only a
# real run-tests session shows it. Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh, category skill-orchestration.

echo ""
echo "=== run_all_carried_read: environment first, then the real settings ==="

# cr_fixture <dir> [tl4] — <dir>/bin/lib is a copy of bin/lib and <dir>/bin/get-config-var a stub that
# appends the key to <dir>/calls and answers on for RUN_TL3, <tl4> (default cfg-RUN_TL4, may be empty)
# for RUN_TL4, else nothing.
cr_fixture() {
  local d="$1" tl4="${2-cfg-RUN_TL4}"
  mkdir -p "$d/bin"
  cp -R "$SCRIPT_CHECKOUT_ROOT/bin/lib" "$d/bin/" || return 1
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' \"\$1\" >>\"$d/calls\"" \
    "case \"\$1\" in RUN_TL3) echo on ;; RUN_TL4) echo '$tl4' ;; esac" 'exit 0' >"$d/bin/get-config-var"
  rm -f "$d/calls"
}

# cr_run <dir> [VAR=val...] — the output of run_all_carried_read on one line ("|"-joined) followed by
# "rc=<status>"; the inherited RUN_TL3 / RUN_TL4 are unset first and only the given VAR=val are exported.
cr_run() {
  local d="$1" a out rc
  shift
  out="$(
    unset RUN_TL3 RUN_TL4
    for a in "$@"; do export "$a"; done
    run_with_timeout 60 bash -c '. "$1/bin/lib/run-all-launch.sh" || exit 95; run_all_carried_read' cr_run "$d" 2>/dev/null
    printf 'rc=%s' "$?"
  )"
  printf '%s' "$out" | tr '\n' '|'
}

# cr_err <dir> [VAR=val...] — the stderr of run_all_carried_read on one line ("|"-joined); stdout is discarded.
cr_err() {
  local d="$1" a out
  shift
  out="$(
    unset RUN_TL3 RUN_TL4
    for a in "$@"; do export "$a"; done
    run_with_timeout 60 bash -c '. "$1/bin/lib/run-all-launch.sh" || exit 95; run_all_carried_read >/dev/null' cr_err "$d" 2>&1
  )"
  printf '%s' "$out" | tr '\n' '|'
}

# cr_pin_run <dir> [VAR=val...] — what the test environment holds after the real run_all_pin_test_env: "TL3=<v> TL4=<v>
# rc=<n>". Only the pins unrelated to the carry (decoy build, run root, command guard, state dirs) are stubbed; the
# inherited RUN_TL3 / RUN_TL4 are unset first and only the given VAR=val are exported.
cr_pin_run() {
  local d="$1" a
  shift
  mkdir -p "$d/pin/workflow"
  (
    unset RUN_TL3 RUN_TL4
    for a in "$@"; do export "$a"; done
    export WORKFLOW_STATE_DIR="$d/pin/workflow"
    run_with_timeout 60 bash -c '. "$1/bin/lib/run-all-launch.sh" || exit 95; run_all_pin_root_decoy() { :; }; run_all_pin_state_dirs() { :; }; _run_all_fixture_pins_inherited() { return 0; }; run_all_pin_test_env "$1/pin"; rc=$?; printf "TL3=%s TL4=%s rc=%s" "${RUN_TL3-<unset>}" "${RUN_TL4-<unset>}" "$rc"' cr_pin_run "$d" 2>/dev/null
  )
}

CRF="$TMPBASE/co-carried"
cr_fixture "$CRF" || fail "fixture (carried read)" "cr_fixture failed"

# Regression detection: both values live only in the stub settings (the environment is unset).
case_begin "carried-read-takes-unset-env-from-the-settings" "bin/lib/run-all-launch.sh"
rm -f "$CRF/calls"
assert_eq "env unset: $(cr_run "$CRF")" "env unset: RUN_TL3=on|RUN_TL4=cfg-RUN_TL4|rc=0"
case_end

# Contract: status 0 even when the last key (RUN_TL4) has no value; the value-bearing RUN_TL3 is kept.
case_begin "carried-read-returns-zero-when-the-last-key-is-empty" "bin/lib/run-all-launch.sh"
CRF2="$TMPBASE/co-carried-tl4empty"
cr_fixture "$CRF2" "" || fail "fixture (carried read, empty RUN_TL4)" "cr_fixture failed"
assert_eq "RUN_TL4 empty: $(cr_run "$CRF2")" "RUN_TL4 empty: RUN_TL3=on|rc=0"
assert_eq "RUN_TL4 empty, RUN_TL3 exported: $(cr_run "$CRF2" RUN_TL3=off)" "RUN_TL4 empty, RUN_TL3 exported: RUN_TL3=off|rc=0"
case_end

# Pins the priority rule; not regression detection.
case_begin "carried-read-prefers-the-environment-over-the-settings" "bin/lib/run-all-launch.sh"
rm -f "$CRF/calls"
assert_eq "RUN_TL3=off exported: $(cr_run "$CRF" RUN_TL3=off)" "RUN_TL3=off exported: RUN_TL3=off|RUN_TL4=cfg-RUN_TL4|rc=0"
assert_eq "settings asked for: $(file_text "$CRF/calls")" "settings asked for: RUN_TL4 "
case_end

case_begin "carried-read-prefers-the-environment-for-the-second-key-too" "bin/lib/run-all-launch.sh"
rm -f "$CRF/calls"
assert_eq "RUN_TL4=off exported: $(cr_run "$CRF" RUN_TL4=off)" "RUN_TL4=off exported: RUN_TL3=on|RUN_TL4=off|rc=0"
assert_eq "settings asked for: $(file_text "$CRF/calls")" "settings asked for: RUN_TL3 "
case_end

# Integration through run_all_pin_test_env: settings-only values reach the test environment.
case_begin "pin-test-env-exports-the-settings-when-the-environment-is-unset" "bin/lib/run-all-launch.sh"
assert_eq "pin_test_env, env unset: $(cr_pin_run "$CRF")" "pin_test_env, env unset: TL3=on TL4=cfg-RUN_TL4 rc=0"
case_end

# Integration through run_all_pin_test_env: an environment value beats the settings (not regression detection).
case_begin "pin-test-env-prefers-the-environment-over-the-settings" "bin/lib/run-all-launch.sh"
assert_eq "pin_test_env, RUN_TL3=off: $(cr_pin_run "$CRF" RUN_TL3=off)" "pin_test_env, RUN_TL3=off: TL3=off TL4=cfg-RUN_TL4 rc=0"
assert_eq "pin_test_env, RUN_TL4=off: $(cr_pin_run "$CRF" RUN_TL4=off)" "pin_test_env, RUN_TL4=off: TL3=on TL4=off rc=0"
case_end

case_begin "carried-read-omits-an-empty-value" "bin/lib/run-all-launch.sh"
rm -f "$CRF/calls"
assert_eq "RUN_TL3 empty: $(cr_run "$CRF" RUN_TL3=)" "RUN_TL3 empty: RUN_TL4=cfg-RUN_TL4|rc=0"
assert_eq "settings asked for: $(file_text "$CRF/calls")" "settings asked for: RUN_TL4 "
case_end

# Regression detection (security): a value with a line break is dropped, so it cannot add a forged
# KEY=VALUE line that a consumer would export (here RUN_TL3=off in place of the real RUN_TL3 setting).
case_begin "carried-read-drops-a-value-with-a-line-break" "bin/lib/run-all-launch.sh"
CR_NL=$'\n'
CR_CR=$'\r'
assert_eq "RUN_TL4 with LF: $(cr_run "$CRF" "RUN_TL4=on${CR_NL}RUN_TL3=off")" "RUN_TL4 with LF: RUN_TL3=on|rc=0"
assert_eq "RUN_TL4 with CR: $(cr_run "$CRF" "RUN_TL4=on${CR_CR}RUN_TL3=off")" "RUN_TL4 with CR: RUN_TL3=on|rc=0"
assert_eq "RUN_TL3 with trailing CR: $(cr_run "$CRF" "RUN_TL3=on${CR_CR}")" "RUN_TL3 with trailing CR: RUN_TL4=cfg-RUN_TL4|rc=0"
assert_eq "RUN_TL4 with LF, warning: $(cr_err "$CRF" "RUN_TL4=on${CR_NL}RUN_TL3=off")" "RUN_TL4 with LF, warning: [run-all-launch] RUN_TL4 holds a line break; not carried"
assert_eq "RUN_TL4 with CR, warning: $(cr_err "$CRF" "RUN_TL4=on${CR_CR}RUN_TL3=off")" "RUN_TL4 with CR, warning: [run-all-launch] RUN_TL4 holds a line break; not carried"
CR_PIN_OUT="$(cr_pin_run "$CRF" "RUN_TL4=on${CR_NL}RUN_TL3=off")"
assert_eq "pin_test_env, LF-injected RUN_TL4: RUN_TL3 stays ${CR_PIN_OUT%% TL4=*}" "pin_test_env, LF-injected RUN_TL4: RUN_TL3 stays TL3=on"
assert_eq "pin_test_env, LF-injected RUN_TL4: rc ${CR_PIN_OUT##* rc=}" "pin_test_env, LF-injected RUN_TL4: rc 0"
case_end
