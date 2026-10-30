#!/bin/bash
# tests/bin/feature-workflow-init-driver/_entry-guard.sh — sourced by the per-group entrypoints
# tests/bin/feature-workflow-init-driver-<group>.sh; NOT a test file.
# Tests: bin/workflow/workflow-init-driver
# Tags: workflow-init, driver, timeout-guard, scope:issue-specific
#
# Why (#2445, #2723): the old aggregate ran 13 groups under one 1800 s guard, so one hang cost
# the whole file. Each group is now its own entrypoint with its own 600 s guard, below the
# runner's 660 s per-file budget, so a hang ends as one file's exit 124.
# Entrypoint order: source this guard (re-execs once), source harness.sh, then
# case_begin / driver_entry_run <group> / case_end, and exit on $FAIL.

if [ -z "${_DRV_EP_WRAPPED:-}" ]; then
    export _DRV_EP_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 600 bash "$0" "$@"
    else
        exec perl -e 'alarm 600; exec @ARGV' -- bash "$0" "$@"
    fi
fi

# driver_entry_run <group> — run one group script as a child; its output passes through and it
# prints its own `Results:` line. The one PASS/FAIL line recorded here is all the entrypoint adds.
driver_entry_run() {
    local group="$1" rc
    local script="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-workflow-init-driver/$group"
    if [ ! -f "$script" ]; then
        fail "split group missing: $script"
        return 1
    fi
    bash "$script"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$group exited 0"
    else
        fail "$group exited $rc"
    fi
    return "$rc"
}
