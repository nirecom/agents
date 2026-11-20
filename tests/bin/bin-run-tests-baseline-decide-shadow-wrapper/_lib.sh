# shellcheck shell=bash
# tests/bin/bin-run-tests-baseline-decide-shadow-wrapper/_lib.sh
# Tests: bin/lib/run-tests-baseline-decide-shadow.sh
# Tags: run-tests, baseline, decide-shadow, helpers, scope:common, pwsh-not-required, TL2
# Shared part of tests/bin/bin-run-tests-baseline-decide-shadow-wrapper.sh: feature-2431's helpers
# (TMPROOT, isolation, run_with_timeout), two checkouts with a stub launcher (branch side and
# merge base side), ws_drive, which runs driver.sh in a child bash, and ws_line, which picks an output line.
# The entrypoint sources it after tests/lib/harness.sh. Not run on its own.

: "${SCRIPT_CHECKOUT_ROOT:?the entrypoint sets SCRIPT_CHECKOUT_ROOT before sourcing _lib.sh}"
# shellcheck source=../feature-2431-run-tests-baseline/helpers.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/helpers.sh"

unset RUN_TESTS_BASELINE_DECIDE_SHADOW RUN_TESTS_BASELINE_DECIDE_SHADOW_FAULT_FOR_TEST
WS_DRIVER="$SCRIPT_CHECKOUT_ROOT/tests/bin/bin-run-tests-baseline-decide-shadow-wrapper/driver.sh"
WS_DIR="$TMPROOT/ws"
WS_WT="$WS_DIR/wt-branch"
WS_WT_BASE="$WS_DIR/wt-base"
# Stub launcher results. fail is rc 3, setup is the launcher's own rc 2 (LAUNCHED=0),
# unsupported is rc 78 (LAUNCHED=0), decoy turns rc 0 into 1 with one hit.
WS_MODES="pass fail setup unsupported decoy"

# ws_make_wt <dir> — puts a stub at <dir>/bin/lib/run-all-launch.sh, which rtb_exec_one prefers.
ws_make_wt() {
  mkdir -p "$1/bin/lib" "$1/tests/bin" || return 1
  printf '%s\n' \
    'run_all_exec() {' \
    '  case "${WS_STUB_MODE:-pass}" in' \
    '    pass) RUN_ALL_EXEC_LAUNCHED=1; RUN_ALL_EXEC_STATE=PASS; return 0 ;;' \
    '    fail) RUN_ALL_EXEC_LAUNCHED=1; RUN_ALL_EXEC_STATE=FAIL; return 3 ;;' \
    '    setup) RUN_ALL_EXEC_LAUNCHED=0; return 2 ;;' \
    '    unsupported) RUN_ALL_EXEC_LAUNCHED=0; return 78 ;;' \
    '    decoy) RUN_ALL_EXEC_LAUNCHED=1; RUN_ALL_EXEC_HITS=1; RUN_ALL_EXEC_STATE=PASS; return 0 ;;' \
    '  esac' \
    '}' >"$1/bin/lib/run-all-launch.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$1/tests/bin/x.sh"
}
ws_make_wt "$WS_WT" && ws_make_wt "$WS_WT_BASE" || { echo "fixture: stub checkouts not built"; exit 1; }

# ws_drive <work-dir> <snippet> [VAR=val...] — runs the snippet through driver.sh. Sets WS_OUT (stdout+stderr) and WS_RC.
ws_drive() {
  local work="$1" snippet="$2"; shift 2
  mkdir -p "$work"
  WS_RC=0
  WS_OUT="$(cd "$TMPROOT" && env "$@" bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 90 \
    bash "$WS_DRIVER" "$WS_WT" "$WS_WT_BASE" "$work" "$snippet" 2>&1)" || WS_RC=$?
}

# ws_line <prefix> — the first WS_OUT line starting with <prefix>, with <prefix> removed. "(none)" if there is none.
ws_line() {
  local l
  l="$(printf '%s\n' "$WS_OUT" | grep -m 1 -F -- "$1")" || { printf '(none)'; return 0; }
  printf '%s' "${l#"$1"}"
}

# ws_install_ok <label> — if the install failed, fails with the reason and returns 1.
ws_install_ok() {
  case "$WS_OUT" in
    *DRV_INSTALL_ERR*) fail "$1: $(ws_line 'DRV_INSTALL_ERR ')"; return 1 ;;
    *DRV_ERR*) fail "$1: driver error: $(ws_line 'DRV_ERR ')"; return 1 ;;
  esac
  return 0
}

# ws_captures <dir> — the capture files under <dir> (one per line).
ws_captures() { find "$1" -name '*.decide-shadow-capture.tsv' 2>/dev/null; }
