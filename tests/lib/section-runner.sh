#!/usr/bin/env bash
# tests/lib/section-runner.sh — fold a standalone section file's result into a parent total.
# Tests: tests/lib/section-runner.sh
# Tags: test-infrastructure, section-runner, shared-lib, scope:common
#
# tests/run-all.sh globs "$TESTS_DIR"/*.sh — TOP-LEVEL ONLY — so a file under
# tests/<family>/ is dead code in CI unless its top-level parent reaches it.
#
# Two wiring styles exist here and are NOT interchangeable:
#
#   sourced   (tests/feat-1699-meta-parent-guard.sh)
#             Sections are fragments sharing the parent's PASS/FAIL/pass()/fail() and mock.
#             Correct when every section shares one seam and a per-section mock would drift.
#
#   subprocess (this helper; also feature-1733-state-event-stream.sh's run_sub)
#             Sections are standalone programs with their own mock, $WORK, EXIT trap and
#             counters. Correct when sourcing would COLLIDE: bash keeps one EXIT trap per
#             shell, so sourcing N such files leaks N-1 temp dirs — enough to redden
#             feat-1761-candidate-body-safety/tmpfile-residue.sh T6 on a sibling's leftovers.
#
# This helper implements the subprocess style with one combined total and no way for a
# section failure to be swallowed.
#
# Contract required of a section file:
#   - runs standalone: `bash <section>` exits 0 (all pass) or non-zero (any fail)
#   - prints exactly one line matching: ^Results: <N> passed, <M> failed
# A section that violates either is reported as a parent-level FAIL rather than skipped,
# so "the section stopped running" can never read as "the section had nothing to say".
#
# Caller must define, before sourcing this file: PASS, FAIL, pass(), fail(),
# SECTION_DIR, and RWT (path to bin/run-with-timeout.sh).

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
