#!/bin/bash
# tests/tests/feature-1832-run-all-parallel/_entry.sh — sourced by the split entrypoints
# tests/tests/feature-1832-run-all-parallel-<group>.sh; NOT a test file.
# Tests: tests/run-all.sh
# Tags: tests, bin, parallel, scope:issue-specific
#
# Why (#1832, #2723): the old dispatcher ran every case file serially in one process (about 1800 s).
# Each entrypoint now owns a group of case files. An item is <file> or <file>@<cases>; the
# second form hands CAL_CASES to g-calibrator.sh so its slow knee-curve case gets its own entrypoint.
# Child output goes through a contract mask so a case cannot forge a RUN_CONTRACT: line
# (hooks/workflow-run-tests.js one-contract-line rule).

F1832_DIR="$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-1832-run-all-parallel"
F1832_CASE_TIMEOUT="${FEATURE_1832_CASE_TIMEOUT:-450}"

f1832_mask_contract() { sed 's/^\([[:blank:]]*\)RUN_CONTRACT:/\1[masked] RUN_CONTRACT:/'; }

# f1832_run <item>... — run each case file; one PASS/FAIL line per item (exit 77 counts as a skip).
f1832_run() {
    local item file cases rc
    for item in "$@"; do
        file="${item%%@*}"; cases=""
        case "$item" in *@*) cases="${item#*@}" ;; esac
        if [ ! -f "$F1832_DIR/$file" ]; then
            fail "split case missing: $F1832_DIR/$file"
            continue
        fi
        echo ""
        echo "########## $item ##########"
        CAL_CASES="$cases" "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" "$F1832_CASE_TIMEOUT" bash "$F1832_DIR/$file" 2>&1 | f1832_mask_contract
        rc=${PIPESTATUS[0]}
        if [ "$rc" -eq 0 ]; then pass "$item exited 0"
        elif [ "$rc" -eq 77 ]; then echo "SKIP: $item"
        else fail "$item exited $rc"; fi
    done
}
