#!/usr/bin/env bash
# Tests: bin/run-codex-review-loop, bin/lib/codex-review-loop/review-record.sh
# Tags: feature-2938, review-record, codex-review-loop, unrecorded, accept-gap, extensions, scope:issue-specific, TL2, dup-group-keep:time-hard-limit
#
# #2938 T5-10, T5-11: a failed append is exit 4 with no sentinel, parks the row in
# -unrecorded.jsonl and commits the counter; a later run or hand-over replays it, or
# accept-gap lets the loop pass; a leftover inflight halts preflight until accept-gap.
# T5-7: the loop derives EXTENSIONS_USED from the record (AUTO_EXTEND rows of the cycle),
# overriding a differing caller value; an underivable count spends the budget.
# TL3 gap: a real codex CLI round is not run; the reviewer is the stub of tests/bin/feature-2937-review-loop/fixture.sh.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"

F=detail-plan
LOOP_ARGS=(--cap 3 --max-extensions 0 --extensions-used 0)
unrec() { side "$1" "$2" -unrecorded.jsonl; }
# broken <sid> <fmt> — one loop whose reviewer moves the record aside (earlier rows are kept,
# D2a) and puts a directory in its place mid-run. mend <sid> <fmt> undoes it.
broken() {
    local r; r="$(rec "$1" "$2")"
    printf -v FX_MID 'mv %q %q 2>/dev/null; mkdir -p %q' "$r" "$r.aside" "$r"
    export FX_MID
    loop "$1" "$2" "${LOOP_ARGS[@]}"
    unset FX_MID
}
mend() {
    local r; r="$(rec "$1" "$2")"
    rmdir "$r"
    mv "$r.aside" "$r" 2>/dev/null || true
}
now_iso() { node -e 'process.stdout.write(new Date().toISOString())'; }

case_begin "t5-10-failed-append-parks-the-row-and-replays-it" "bin/lib/codex-review-loop/review-record.sh"
broken g10 "$F"
assert_eq "a failed append is exit 4" "4" "$L_RC"
assert_not_contains "with no sentinel" "REVIEW_LOOP_VERDICT:" "$L_OUT"
assert_eq "the row is parked in the first sid's control dir" "present" "$(clf_file_state "$(unrec g10 "$F")")"
assert_eq "the counter still commits the round" "1" "$(head -n 1 "$(clf_round_path "$P" g10 "$F")" 2>/dev/null | tr -d '\r')"
mend g10 "$F"
loop g10 "$F" "${LOOP_ARGS[@]}"
assert_eq "after the fix the loop runs round 2" "1" "$L_RC"
assert_eq "the record holds the replayed row and the new one" "2" "$(rows g10 "$F")"
assert_eq "the replayed row is round 1" "1" "$(row g10 "$F" 1 counter_round)"
assert_eq "the parked rows are consumed" "missing" "$(clf_file_state "$(unrec g10 "$F")")"
case_end

case_begin "t5-10-hand-over-generation-replays-the-row" "bin/lib/codex-review-loop/review-record.sh"
st seed g10a
broken g10a "$F"
assert_eq "precondition: exit 4 on generation A" "4" "$L_RC"
mend g10a "$F"
st seed g10b
st handover g10b g10a
loop g10b "$F" "${LOOP_ARGS[@]}"
assert_ne "generation B runs" "4" "$L_RC"
assert_eq "B replays A's parked row into the first sid's record" "2" "$(rows g10a "$F")"
assert_eq "the parked rows are consumed" "missing" "$(clf_file_state "$(unrec g10a "$F")")"
case_end

case_begin "t5-10-accept-gap-lets-the-loop-pass" "bin/lib/codex-review-loop/review-record.sh"
broken g10g "$F"
assert_eq "precondition: exit 4" "4" "$L_RC"
loop g10g "$F" "${LOOP_ARGS[@]}"
assert_eq "while the record stays unwritable the loop halts" "4" "$L_RC"
rr accept-gap --session g10g --format "$F" --reason "record was replaced by a directory"
assert_eq "accept-gap succeeds" "0" "$R_RC"
assert_eq "it moves the parked rows away" "missing" "$(clf_file_state "$(unrec g10g "$F")")"
assert_contains "into -gap-accepted.jsonl with the reason" "record was replaced by a directory" "$(cat "$(side g10g "$F" -gap-accepted.jsonl)" 2>/dev/null)"
mend g10g "$F"
loop g10g "$F" "${LOOP_ARGS[@]}"
assert_eq "the loop then passes" "1" "$L_RC"
case_end

case_begin "t5-10-replayed-row-keeps-its-confirm-time-fields" "bin/lib/codex-review-loop/review-record.sh"
st seed g10c
loop g10c "$F" "${LOOP_ARGS[@]}"
assert_eq "precondition: r1 continues" "1" "$L_RC"
head_before="$(st head g10c)"
broken g10c "$F"
assert_eq "precondition: r2 append fails" "4" "$L_RC"
t_confirmed="$(now_iso)"
st reset g10c
audit_block g10c TR2
mend g10c "$F"
loop g10c "$F" "${LOOP_ARGS[@]}"
assert_eq "the replayed row is the second row" "2" "$(row g10c "$F" 2 counter_round)"
r="$(row g10c "$F" 2 route)"
assert_ne "its route is not the later reset" "reset" "$r"
assert_ne "nor the later audit block" "audit-block" "$r"
assert_eq "its loop_cycle is the confirm-time cycle" "$(row g10c "$F" 1 loop_cycle)" "$(row g10c "$F" 2 loop_cycle)"
assert_eq "its state_sid is the confirming sid" "g10c" "$(row g10c "$F" 2 state_sid)"
assert_eq "its event_seq is the head at confirm time" "$head_before" "$(row g10c "$F" 2 event_seq)"
at="$(row g10c "$F" 2 at)"
if [ -n "$at" ] && [[ ! "$at" > "$t_confirmed" ]]; then pass "its at is the confirm time, not the replay time"
else fail "its at is the confirm time, not the replay time" "at=$at confirmed-before=$t_confirmed"; fi
case_end

case_begin "t5-11-leftover-inflight-halts-until-accept-gap" "bin/lib/codex-review-loop/review-record.sh"
RC="$(rec g11 "$F")"; UC="$(unrec g11 "$F")"
printf -v FX_MID 'rm -f %q %q; mkdir -p %q %q' "$RC" "$UC" "$RC" "$UC"
export FX_MID
loop g11 "$F" "${LOOP_ARGS[@]}"
unset FX_MID
assert_eq "both the record and the unrecorded file unwritable is exit 4" "4" "$L_RC"
rmdir "$RC" "$UC"
loop g11 "$F" "${LOOP_ARGS[@]}"
assert_eq "the leftover inflight halts preflight" "4" "$L_RC"
assert_contains "and names the accept-gap exit" "accept-gap" "$L_ERR"
rr accept-gap --session g11 --format "$F" --reason "control dir was unwritable"
assert_eq "accept-gap succeeds" "0" "$R_RC"
assert_eq "no inflight is left" "0" "$(inflights g11 "$F")"
assert_eq "the inflight is kept as gap-accepted" "present" "$(clf_file_state "$(side g11 "$F" -gap-accepted.jsonl)")"
loop g11 "$F" "${LOOP_ARGS[@]}"
assert_eq "the loop then passes" "1" "$L_RC"
case_end

# --- T5-7: EXTENSIONS_USED comes from the review record, not the caller. ---
MISMATCH="differs from the review record"
# go <sid> <ext> — one detail-plan round with cap 2, one extension, the caller's EXTENSIONS_USED.
go() { loop "$1" "$F" --cap 2 --max-extensions 1 --extensions-used "$2"; }
# to_cap <sid> — rounds 1 and 2; round 2 asks for the extension (exit 5).
to_cap() {
    go "$1" 0
    assert_eq "$1 r1 continues (precondition)" "1" "$L_RC"
    go "$1" 0
    assert_eq "$1 r2 at the cap auto-extends (precondition)" "5" "$L_RC"
}

case_begin "t5-7-caller-value-matching-the-record-is-silent" "bin/lib/codex-review-loop/review-record.sh"
to_cap e7a
go e7a 1
assert_eq "r3 with the spent extension is terminal" "6" "$L_RC"
assert_not_contains "no mismatch line when the caller agrees" "$MISMATCH" "$L_ERR"
case_end

case_begin "t5-7-caller-value-is-overridden-by-the-record" "bin/lib/codex-review-loop/review-record.sh"
to_cap e7b
go e7b 0
assert_eq "a caller that forgot the extension still ends at 6, not 5" "6" "$L_RC"
assert_contains "the override is named" "EXTENSIONS_USED from the caller (0) differs from the review record (1); using 1" "$L_ERR"
case_end

case_begin "t5-7-cc-fallback-row-does-not-change-the-count" "bin/lib/codex-review-loop/review-record.sh"
to_cap e7c
export FX_RV=1
go e7c 1
unset FX_RV
assert_eq "r3 codex failure is exit 3 (precondition)" "3" "$L_RC"
rr record-fallback --session e7c --format "$F" --verdict NEEDS_REVISION
assert_eq "record-fallback succeeds" "0" "$R_RC"
go e7c 1
assert_eq "the codex retry of r3 is terminal" "6" "$L_RC"
assert_not_contains "the cc-fallback row is not counted as an extension" "$MISMATCH" "$L_ERR"
case_end

case_begin "t5-7-underivable-count-spends-the-budget" "bin/lib/codex-review-loop/review-record.sh"
go e7d 0
assert_eq "e7d r1 continues (precondition)" "1" "$L_RC"
rm -f "$(rec e7d "$F")"
go e7d 0
assert_eq "without the record r2 cannot extend (6, not 5)" "6" "$L_RC"
assert_contains "and says why" "the review record cannot derive EXTENSIONS_USED for this cycle; treating the extension budget as spent" "$L_ERR"
case_end

finish
