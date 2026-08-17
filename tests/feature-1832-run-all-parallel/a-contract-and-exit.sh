#!/usr/bin/env bash
# a-contract-and-exit.sh — the output contract survives parallel execution.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, scope:issue-specific

# WHY: hooks/workflow-run-tests.js accepts a run-all verdict only when stdout
# holds exactly one RUN_CONTRACT line and nothing but whitespace after it, and
# the exit code is the second half of the same contract. Parallelism must not
# move either. Every assertion below runs at `-j 4`.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "a-contract-and-exit"
# Explicit per-case pins (fx_init sets the same values; kept visible per case).
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export CLAUDE_WORKFLOW_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# --- fixture 1: mixed verdicts -------------------------------------------
MIX="$(fx_new_root)"
fx_add_dummy "$MIX" t1-pass --lines 2
fx_add_dummy "$MIX" t2-pass --lines 2
fx_add_dummy "$MIX" t3-fail --exit 3 --lines 1
fx_add_dummy "$MIX" t4-skip --exit 77 --lines 1
fx_add_dummy "$MIX" t5-fail --exit 5 --lines 1
fx_add_archive_sentinel "$MIX"

MIX_OUT="$FX_TMP_ROOT/mix.out"
MIX_ERR="$FX_TMP_ROOT/mix.err"
fx_exec "$MIX" 60 "$MIX_OUT" "$MIX_ERR" -j 4 --all
MIX_RC=$?

A_PASS="$(fx_contract_field "$MIX_OUT" PASS)"
A_FAIL="$(fx_contract_field "$MIX_OUT" FAIL)"
A_SKIP="$(fx_contract_field "$MIX_OUT" SKIP)"
A_EXEC="$(fx_contract_field "$MIX_OUT" EXECUTED)"

# A1/A2 are stated together with EXECUTED=5: a run where nothing executed also
# emits exactly one contract line as its last line, and that must not read green.
N_CONTRACT="$(fx_count_contract "$MIX_OUT")"
[ "$N_CONTRACT" = "1" ] && [ "$A_EXEC" = "5" ]
fx_check $? "A1. -j 4: 5 tests ran and stdout carries exactly one RUN_CONTRACT line (got $N_CONTRACT for EXECUTED=$A_EXEC)"

# (b) the contract line is the last non-empty line of stdout — the property
# stdoutAttributed() checks for the run-all emitter.
LAST_NONEMPTY="$(grep -v '^[[:blank:]]*$' "$MIX_OUT" | tail -n 1)"
case "$LAST_NONEMPTY" in
    RUN_CONTRACT:*)
        if [ "$A_EXEC" = "5" ]; then
            fx_pass "A2. -j 4: contract line is the last non-empty line of stdout over 5 executed tests"
        else
            fx_fail "A2. -j 4: contract is last, but only EXECUTED=$A_EXEC tests ran (want 5)"
        fi
        ;;
    *) fx_fail "A2. -j 4: last non-empty stdout line is not the contract line (got: ${LAST_NONEMPTY:-<empty>})" ;;
esac

GOT="PASS=$A_PASS FAIL=$A_FAIL SKIP=$A_SKIP EXECUTED=$A_EXEC"
[ "$GOT" = "PASS=2 FAIL=2 SKIP=1 EXECUTED=5" ]
fx_check $? "A3. -j 4: contract counts are correct (want PASS=2 FAIL=2 SKIP=1 EXECUTED=5, got $GOT)"

[ "$MIX_RC" -eq 1 ]
fx_check $? "A4. -j 4: FAIL>0 exits 1 (got exit $MIX_RC)"

# (e) exit-code classification: 77 is a SKIP, every other non-zero is a FAIL.
grep -q "^SKIP: .*t4-skip\.sh$" "$MIX_OUT"
fx_check $? "A5a. -j 4: exit 77 classifies as SKIP"
N_FAILLINE="$(grep -cE '^FAIL: .*(t3-fail|t5-fail)\.sh \(exit [0-9]+\)$' "$MIX_OUT" || true)"
[ "$N_FAILLINE" = "2" ]
fx_check $? "A5b. -j 4: exit 3 and exit 5 both classify as FAIL (got $N_FAILLINE FAIL lines)"

# (f) tests/_archive/ is not executed — asserted together with EXECUTED so the
# check cannot pass merely because nothing ran at all.
if [ "$A_EXEC" = "5" ] && ! grep -q "FX_ARCHIVE_LEAKED" "$MIX_OUT"; then
    fx_pass "A6. -j 4: the 5 top-level dummies ran and _archive/ did not"
else
    fx_fail "A6. -j 4: expected EXECUTED=5 with no _archive/ leak (EXECUTED=$A_EXEC, leak=$(grep -c FX_ARCHIVE_LEAKED "$MIX_OUT" || true))"
fi

[ "$FX_ERRORS" -eq 0 ] || fx_show_tail "$MIX_OUT" 20

# --- fixture 2: all green -------------------------------------------------
GREEN="$(fx_new_root)"
fx_add_dummy "$GREEN" g1-pass --lines 1
fx_add_dummy "$GREEN" g2-pass --lines 1
fx_add_dummy "$GREEN" g3-skip --exit 77

GREEN_OUT="$FX_TMP_ROOT/green.out"
GREEN_ERR="$FX_TMP_ROOT/green.err"
fx_exec "$GREEN" 60 "$GREEN_OUT" "$GREEN_ERR" -j 4 --all
GREEN_RC=$?
G_FAIL="$(fx_contract_field "$GREEN_OUT" FAIL)"
G_EXEC="$(fx_contract_field "$GREEN_OUT" EXECUTED)"
if [ "$GREEN_RC" -eq 0 ] && [ "$G_FAIL" = "0" ] && [ "$G_EXEC" = "3" ]; then
    fx_pass "A7. -j 4: FAIL=0 over 3 executed tests exits 0"
else
    fx_fail "A7. -j 4: want exit 0 with FAIL=0 EXECUTED=3, got exit $GREEN_RC FAIL=$G_FAIL EXECUTED=$G_EXEC"
fi

fx_finish
