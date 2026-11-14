#!/usr/bin/env bash
# Tests: bin/run-codex-review-loop, bin/lib/codex-review-loop/review-record.sh, bin/lib/codex-review-loop/round-counter.sh
# Tags: feature-2938, review-record, codex-review-loop, preflight, scope:issue-specific, TL2, round-rollback
#
# #2938 T5-1, T5-4, T5-6, T5-9: the loop writes one record row per committed round; the row
# outlives the counter, the terminal guard and a reset; a non-committing exit leaves no row
# and no inflight; preflight halts (exit 4, reviewer not run) on an unconsumed fallback
# pending or an unwritable record.
# TL3 gap: a real codex CLI round is not run; the reviewer is the stub of tests/bin/feature-2937-review-loop/fixture.sh.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"

LOOP_ARGS=(--cap 3 --max-extensions 0 --extensions-used 0)

case_begin "t5-1-rows-outlive-counter-guard-and-reset" "bin/run-codex-review-loop"
sid="r1"; F=detail-plan
st seed "$sid"
loop "$sid" "$F" "${LOOP_ARGS[@]}"
loop "$sid" "$F" "${LOOP_ARGS[@]}"
assert_eq "two committed rounds are two rows" "2" "$(rows "$sid" "$F")"
rm -f "$(clf_round_path "$P" "$sid" "$F")"
printf '6\nfp\n' > "$(ctl "$sid")/$F-terminal.txt"
rm -f "$(ctl "$sid")/$F-terminal.txt"
st reset "$sid"
assert_eq "the counter, the guard and a reset do not remove rows" "2" "$(rows "$sid" "$F")"
loop "$sid" "$F" "${LOOP_ARGS[@]}"
assert_eq "the next round adds one row" "3" "$(rows "$sid" "$F")"
assert_eq "and opens a new cycle at round 1" "1" "$(row "$sid" "$F" -1 counter_round)"
assert_eq "its route is reset" "reset" "$(row "$sid" "$F" -1 route)"
case_end

case_begin "t5-6-non-committing-exits-leave-no-row-and-no-inflight" "bin/lib/codex-review-loop/review-record.sh"
sid="r6"; F=detail-plan
loop "$sid" "$F" "${LOOP_ARGS[@]}" --round 5
assert_eq "precondition: a --round off the counter is exit 4" "4" "$L_RC"
assert_eq "exit 4 writes no row" "0" "$(rows "$sid" "$F")"
assert_eq "exit 4 leaves no inflight" "0" "$(inflights "$sid" "$F")"
export FX_HEADER="FAILED — round cap reached"
loop "$sid" "$F" "${LOOP_ARGS[@]}"
unset FX_HEADER
assert_eq "precondition: the reviewer's cap header is exit 2" "2" "$L_RC"
assert_eq "a cap exit 2 before review writes no row" "0" "$(rows "$sid" "$F")"
assert_eq "and leaves no inflight" "0" "$(inflights "$sid" "$F")"
sid="r6f"
loop "$sid" "$F" --cap 2 --max-extensions 0 --extensions-used 0
mkdir -p "$(clf_artifact_path "$P" "$sid" "$F")" "$P/$sid-$F-finalize-diagnostic.txt"
loop "$sid" "$F" --cap 2 --max-extensions 0 --extensions-used 0
assert_eq "precondition: finalize failure is exit 7" "7" "$L_RC"
assert_eq "exit 7 adds exactly one row" "2" "$(rows "$sid" "$F")"
assert_eq "the row carries exit 7" "7" "$(row "$sid" "$F" -1 exit)"
assert_eq "and the verdict FINALIZE_FAILED" "FINALIZE_FAILED" "$(row "$sid" "$F" -1 verdict)"
assert_eq "no inflight survives a committed exit" "0" "$(inflights "$sid" "$F")"
case_end

case_begin "t5-4-unconsumed-pending-halts-before-the-reviewer" "bin/lib/codex-review-loop/review-record.sh"
sid="r4"; F=detail-plan
export FX_RV=1
loop "$sid" "$F" "${LOOP_ARGS[@]}"
unset FX_RV
assert_eq "precondition: a failing reviewer is exit 3" "3" "$L_RC"
assert_eq "exit 3 stages a fallback pending" "present" "$(clf_file_state "$(side "$sid" "$F" -fallback-pending.json)")"
export FX_ROUND_LOG="$FX_TMP/r4-rounds.log"
: > "$FX_ROUND_LOG"
loop "$sid" "$F" "${LOOP_ARGS[@]}"
assert_eq "an unconsumed pending is exit 4" "4" "$L_RC"
assert_eq "the reviewer does not run" "" "$(cat "$FX_ROUND_LOG")"
assert_contains "exit 1 of 2: record the fallback verdict" "record-fallback" "$L_ERR"
assert_contains "exit 2 of 2: discard with a reason" "discard-fallback" "$L_ERR"
rr discard-fallback --session "$sid" --format "$F" --reason "fallback did not run"
assert_eq "discard-fallback succeeds" "0" "$R_RC"
assert_eq "the pending is gone" "missing" "$(clf_file_state "$(side "$sid" "$F" -fallback-pending.json)")"
assert_contains "it is kept as discarded with the reason" "fallback did not run" "$(cat "$(side "$sid" "$F" -fallback-discarded.json)" 2>/dev/null)"
loop "$sid" "$F" "${LOOP_ARGS[@]}"
unset FX_ROUND_LOG
assert_eq "the loop runs again (exit 1)" "1" "$L_RC"
assert_eq "and writes its row" "1" "$(rows "$sid" "$F")"
case_end

case_begin "t5-9-unwritable-record-halts-in-preflight" "bin/lib/codex-review-loop/review-record.sh"
sid="r9"; F=detail-plan
mkdir -p "$(rec "$sid" "$F")"
export FX_ROUND_LOG="$FX_TMP/r9-rounds.log"
: > "$FX_ROUND_LOG"
loop "$sid" "$F" "${LOOP_ARGS[@]}"
assert_eq "an unwritable record is exit 4" "4" "$L_RC"
assert_eq "the reviewer does not run" "" "$(cat "$FX_ROUND_LOG")"
assert_not_contains "and no sentinel is printed" "REVIEW_LOOP_VERDICT:" "$L_OUT"
unset FX_ROUND_LOG
case_end

# An exit 4 before the reduce commits has no verdict name and writes no row, so the round
# counter must roll back: a consumed round with no row is a record gap (D2/D2a).
counter_of() { clf_read "$(clf_round_path "$P" "$1" "$2")"; }

case_begin "a1-missing-verdict-engine-rolls-back-the-round" "bin/run-codex-review-loop"
sid="ra1"; F=detail-plan
loop "$sid" "$F" "${LOOP_ARGS[@]}"
assert_eq "precondition: round 1 continues (exit 1)" "1" "$L_RC"
assert_eq "precondition: the counter is at 1" "1" "$(counter_of "$sid" "$F")"
bin_aside review-loop-verdict
loop "$sid" "$F" "${LOOP_ARGS[@]}"
bin_back review-loop-verdict
assert_eq "a missing review-loop-verdict is exit 4" "4" "$L_RC"
assert_contains "it names the missing engine" "review-loop-verdict not found or not executable" "$L_ERR"
assert_eq "the counter rolls back to round 1" "1" "$(counter_of "$sid" "$F")"
assert_eq "no row is added" "1" "$(rows "$sid" "$F")"
assert_eq "no inflight is left" "0" "$(inflights "$sid" "$F")"
case_end

# No prior round here, so the rollback takes the other branch: the counter file is removed.
case_begin "a2-header-only-ledger-after-reduce-rolls-back-the-round" "bin/run-codex-review-loop"
sid="ra2"; F=detail-plan
ledger_rows_lost_on_reduce on
loop "$sid" "$F" "${LOOP_ARGS[@]}"
ledger_rows_lost_on_reduce off
assert_eq "a header-only ledger after reduce is exit 4" "4" "$L_RC"
assert_contains "it refuses to judge from a header-only ledger" "refusing to judge from a header-only ledger" "$L_ERR"
assert_eq "the counter round is not consumed" "absent" "$(counter_of "$sid" "$F")"
assert_eq "nor terminated (no last-round)" "absent" "$(clf_read "$(clf_last_round_path "$P" "$sid" "$F")")"
assert_eq "no row is written" "0" "$(rows "$sid" "$F")"
assert_eq "no inflight is left" "0" "$(inflights "$sid" "$F")"
case_end

finish
