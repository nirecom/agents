#!/usr/bin/env bash
# tests/lib/section-runner.sh — fold a standalone section file's result into a parent total.
# Tests: tests/lib/section-runner.sh
# Tags: test-infrastructure, section-runner, shared-lib, scope:common
# Subprocess-style: each section is a standalone program (own mock/EXIT trap/counters),
# so sourcing N would leak N-1 temp dirs (one EXIT trap per shell); this helper keeps
# one combined total with no swallowed failure. Section contract: `bash <section>` exits
# 0/non-zero and prints one `^Results: <N> passed, <M> failed` line (else parent FAIL).
# Caller defines SECTION_DIR; sourcing tests/lib/harness.sh first supplies PASS, FAIL,
# pass(), fail(), and RWT. Full wiring-style rationale (sourced vs subprocess): git history.
# run_section <file.sh> [timeout-seconds]
run_section() {
    local file="$1" secs="${2:-180}"
    local path="$SECTION_DIR/$file"
    local out rc sp sf

    echo ""
    echo "=== section: $file ==="

    if [ ! -f "$path" ]; then
        fail "section:$file" "section file is missing — the parent references a file that does not exist"
        return
    fi

    out="$(bash "$RWT" "$secs" bash "$path" 2>&1)"
    rc=$?
    printf '%s\n' "$out"

    # Last Results line wins: a section may echo the word earlier in prose.
    sp="$(printf '%s\n' "$out" | sed -n 's/^Results: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed.*$/\1/p' | tail -n 1)"
    sf="$(printf '%s\n' "$out" | sed -n 's/^Results: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed.*$/\2/p' | tail -n 1)"

    if [ -z "$sp" ] || [ -z "$sf" ]; then
        # No parsable total: timeout (rc=124), a crash, or `set -e` aborting mid-file.
        # Counting 0 here would silently shrink the suite, so it is an explicit failure.
        fail "section:$file" "no parsable 'Results:' line (rc=$rc) — the section did not run to completion"
        return
    fi

    PASS=$((PASS + sp))
    FAIL=$((FAIL + sf))

    # Cross-check the two independent signals: exit code and reported counts must agree,
    # or a failure outside the section's own counters gets swallowed.
    if [ "$rc" -ne 0 ] && [ "$sf" -eq 0 ]; then
        fail "section:$file" "exited $rc but reported 0 failures — a failure was swallowed"
    elif [ "$rc" -eq 0 ] && [ "$sf" -ne 0 ]; then
        fail "section:$file" "reported $sf failures but exited 0 — the section's own exit code is wrong"
    fi
}
