#!/usr/bin/env bash
# n10-duration-ledger-deadline.sh — a deadline abort keeps what completed, drops what did not.
# Tests: tests/run-all.sh, bin/lib/run-all-durations.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, ledger, deadline, TL2, scope:issue-specific
# WHY: recording is driven by harvest, not by replay, and the abort path (exit 3) skips the
# whole reporting tail. So a test that finished but was never replayed must still be measured,
# while the killed test must leave nothing — otherwise the next run's LPT sort would either
# lose the only measurement it had or invent a duration for a test that never ended.
# TL3 gap: a real suite whose deadline lands mid-write on a slow filesystem — mitigated at
# WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n10-duration-ledger-deadline"

DUR_LIB_REL="bin/lib/run-all-durations.sh"
DUR_LIB="$FX_REPO_ROOT/$DUR_LIB_REL"

dur_missing() {
    [ -f "$DUR_LIB" ] && return 1
    fx_fail "$1 (implementation missing: $DUR_LIB_REL)"
    return 0
}

# key_secs <basename> — the seconds recorded for that test, "(none)" when unrecorded.
key_secs() {
    fx_ledger_cat | awk -F'|' -v b="$1" '
        NF == 3 { n = split($3, a, /[\/\\]/)
                  if (a[n] == b) { print $2; found = 1; exit } }
        END { if (!found) print "(none)" }'
}

D="$(fx_new_root)"
# Alphabetically first, so glob order submits it at index 0 and its slot is what the
# replay loop is still waiting on when the deadline fires.
fx_add_dummy "$D" a-long --sleep 18
fx_add_dummy "$D" b-short --sleep 1

D_OUT="$FX_TMP_ROOT/d.out"; D_ERR="$FX_TMP_ROOT/d.err"

# ===========================================================================
# N37 — the completed-but-unreplayed test survives the abort; the killed one does not
# ===========================================================================
fx_ledger_clear
fx_exec "$D" 90 "$D_OUT" "$D_ERR" -j 2 --deadline 6 --all
D_RC=$?
D_LINES="$(fx_ledger_lines)"
D_SHORT="$(key_secs b-short.sh)"
D_LONG="$(key_secs a-long.sh)"
D_REPLAYED="$(grep -c '^\(PASS\|FAIL\|SKIP\): ' "$D_OUT" 2>/dev/null || true)"
D_ABORT=0
grep -q 'deadline of 6s exceeded' "$D_ERR" 2>/dev/null && D_ABORT=1

if [ "$D_RC" -eq 3 ] && [ "$D_ABORT" -eq 1 ] && [ "$D_REPLAYED" = "0" ]; then
    fx_pass "N37a. the fixture is real: the run aborted on the deadline (exit 3) with nothing replayed"
else
    fx_fail "N37a. the fixture is not usable — want exit 3, the deadline notice and 0 replayed verdicts, got exit $D_RC notice=$D_ABORT replayed=$D_REPLAYED"
    fx_show_tail "$D_ERR" 8
fi

if dur_missing "N37. the short test is recorded and the killed long test is not"; then :
elif [ "$D_RC" -eq 3 ] && [ "$D_LINES" = "1" ] && [ "$D_SHORT" != "(none)" ] && \
     [ "$D_LONG" = "(none)" ]; then
    fx_pass "N37. the aborted run left exactly one record: b-short.sh=${D_SHORT}s, a-long.sh unrecorded"
else
    fx_fail "N37. want exit 3 with 1 record, b-short.sh measured and a-long.sh absent, got exit $D_RC lines=$D_LINES b-short='$D_SHORT' a-long='$D_LONG'"
fi

# ===========================================================================
# N38 — control: without the deadline the same fixture records BOTH tests
# ===========================================================================
# Without this row N37 would also pass for a writer that records nothing at all,
# or for a fixture whose long test can never be measured in the first place.
fx_ledger_clear
fx_exec "$D" 90 "$D_OUT" "$D_ERR" -j 2 --all
C_RC=$?
C_EXEC="$(fx_contract_field "$D_OUT" EXECUTED)"
C_LINES="$(fx_ledger_lines)"
C_SHORT="$(key_secs b-short.sh)"
C_LONG="$(key_secs a-long.sh)"

if dur_missing "N38. an uninterrupted run of the same fixture records both tests"; then :
elif [ "$C_RC" -eq 0 ] && [ "$C_EXEC" = "2" ] && [ "$C_LINES" = "2" ] && \
     [ "$C_SHORT" != "(none)" ] && [ "$C_LONG" != "(none)" ]; then
    fx_pass "N38. the same fixture run to completion recorded both tests (b-short=${C_SHORT}s a-long=${C_LONG}s)"
else
    fx_fail "N38. want exit 0, EXECUTED=2 and 2 records with both tests measured, got exit $C_RC EXECUTED=${C_EXEC:-absent} lines=$C_LINES b-short='$C_SHORT' a-long='$C_LONG'"
    fx_show_tail "$D_ERR" 8
fi

fx_finish
