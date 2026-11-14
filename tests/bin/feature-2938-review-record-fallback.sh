#!/usr/bin/env bash
# Tests: bin/run-codex-review-loop, bin/lib/codex-review-loop/review-record.sh, skills/review-tests/scripts/run-codex-review-loop.sh, bin/lib/codex-review-loop/prestaged-pass.sh
# Tags: feature-2938, review-record, codex-review-loop, cc-fallback, prestaged, static, scope:issue-specific, TL2, round-rollback
#
# #2938 T5-2/3/5, T4-10: every exit 3 (reviewer failure, SKIPPED / FAILED header, review-tests
# skip) stages a fallback pending that record-fallback turns into one cc-fallback row, and no
# exit 3 site is bare; security-code's prestaged ADVANCE writes its own row. T5-8/13: a prestaged
# pass derives EXTENSIONS_USED at its round; the older-input concerns block is display only.
# TL3 gap: a real codex CLI round is not run; the reviewer is the stub of tests/bin/feature-2937-review-loop/fixture.sh.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"

LOOP_ARGS=(--cap 3 --max-extensions 0 --extensions-used 0)
pend() { side "$1" "$2" -fallback-pending.json; }
# counter <sid> <fmt> <name> — a round file of the control dir (round-number / last-round), or 'absent'.
counter() {
    local f
    f="$(ctl "$1")/$2-$3.txt"
    if [ -f "$f" ]; then tr -d '\r\n' < "$f"; else printf 'absent'; fi
}

# --- Exit 3 stages a fallback pending; record-fallback turns it into a row. ---
case_begin "t5-2-outline-exit3-then-record-fallback-keeps-the-round" "bin/lib/codex-review-loop/review-record.sh"
sid="f2"; F=outline-plan
st seed "$sid"
for i in 1 2; do
    export FX_RV=1
    loop "$sid" "$F" "${LOOP_ARGS[@]}"
    unset FX_RV
    assert_eq "exit 3 #$i (precondition)" "3" "$L_RC"
    assert_eq "exit 3 #$i writes no row" "$((i - 1))" "$(rows "$sid" "$F")"
    assert_eq "exit 3 #$i stages a pending" "present" "$(clf_file_state "$(pend "$sid" "$F")")"
    rr record-fallback --session "$sid" --format "$F" --verdict MISSING_ALTERNATIVE
    assert_eq "record-fallback #$i succeeds" "0" "$R_RC"
    assert_eq "it consumes the pending" "missing" "$(clf_file_state "$(pend "$sid" "$F")")"
    assert_eq "one cc-fallback row #$i" "$i" "$(rows "$sid" "$F")"
    assert_eq "row #$i: source" "cc-fallback" "$(row "$sid" "$F" -1 source)"
    assert_eq "row #$i: exit is null" "null" "$(row "$sid" "$F" -1 exit)"
    assert_eq "row #$i: the verdict as passed" "MISSING_ALTERNATIVE" "$(row "$sid" "$F" -1 verdict)"
    assert_eq "row #$i: the exit-3 round (the counter rolled back)" "1" "$(row "$sid" "$F" -1 counter_round)"
done
loop "$sid" "$F" "${LOOP_ARGS[@]}"
assert_eq "the codex retry runs round 1 again (exit 1)" "1" "$L_RC"
assert_eq "it writes a third row" "3" "$(rows "$sid" "$F")"
assert_eq "with the same counter_round" "1" "$(row "$sid" "$F" -1 counter_round)"
assert_eq "the same cycle" "1" "$(row "$sid" "$F" -1 loop_cycle)"
assert_eq "and the next row_no" "3" "$(row "$sid" "$F" -1 row_no)"
case_end

# The reviewer can run and still report no review: a SKIPPED or a FAILED status header.
# Both are exit 3 of the loop, so both must stage the pending before the wrapper returns.
case_begin "t4-10-skipped-and-failed-headers-stage-the-fallback" "bin/run-codex-review-loop"
for hdr in "SKIPPED — codex CLI not installed" "FAILED — codex timed out"; do
    kind="${hdr%% *}"
    sid="fh-$(printf '%s' "$kind" | tr 'A-Z' 'a-z')"; F=detail-plan
    seed_sid "$sid"
    st seed "$sid"
    export FX_HEADER="$hdr"
    wrap make-detail-plan "$sid"
    unset FX_HEADER
    assert_eq "$kind header: the wrapper exits 3" "3" "$W_RC"
    assert_contains "$kind header: the reviewer's explanation reaches the author" "## Codex Review: $kind" "$W_OUT"
    assert_eq "$kind header: no row yet" "0" "$(rows "$sid" "$F")"
    assert_eq "$kind header: a fallback pending is staged" "present" "$(clf_file_state "$(pend "$sid" "$F")")"
    rr record-fallback --session "$sid" --format "$F" --verdict NEEDS_REVISION
    assert_eq "$kind header: record-fallback succeeds" "0" "$R_RC"
    assert_eq "$kind header: it writes one row" "1" "$(rows "$sid" "$F")"
    assert_eq "$kind header: a cc-fallback row" "cc-fallback" "$(row "$sid" "$F" 1 source)"
    assert_eq "$kind header: at the exit-3 round" "1" "$(row "$sid" "$F" 1 counter_round)"
done
case_end

case_begin "t5-3-review-tests-skip-stages-a-fallback" "skills/review-tests/scripts/run-codex-review-loop.sh"
OUT="$FX_TMP/outside"
mkdir -p "$OUT"
seed_sid f3a
wrap review-tests f3a "$OUT"
assert_eq "outside a repository with no state the wrapper skips (exit 3)" "3" "$W_RC"
assert_eq "the skip stages a pending" "present" "$(clf_file_state "$(pend f3a test-review)")"
rr record-fallback --session f3a --format test-review --verdict NEEDS_REVISION
assert_eq "record-fallback succeeds" "0" "$R_RC"
assert_eq "one row" "1" "$(rows f3a test-review)"
assert_eq "a cc-fallback row" "cc-fallback" "$(row f3a test-review 1 source)"
assert_eq "with no fingerprint" "null" "$(row f3a test-review 1 fingerprint)"
assert_eq "numbered 1 (no rows before)" "1" "$(row f3a test-review 1 counter_round)"

seed_sid f3b
wrap review-tests f3b "$OUT"
before="$(clf_digest "$(pend f3b test-review)")"
wrap review-tests f3b "$OUT"
assert_eq "an unconsumed pending stops the skip (exit 4)" "4" "$W_RC"
assert_contains "exit 1 of 2: record the fallback verdict" "record-fallback" "$W_ERR"
assert_contains "exit 2 of 2: discard with a reason" "discard-fallback" "$W_ERR"
assert_eq "the existing pending is not overwritten" "$before" "$(clf_digest "$(pend f3b test-review)")"
assert_ne "and it was there" "absent" "$before"

seed_sid f3c
mkdir -p "$(pend f3c test-review)"
wrap review-tests f3c "$OUT"
assert_eq "a pending that cannot be written is exit 4, not 3" "4" "$W_RC"
case_end

# --- Static: no exit 3 site skips its staging helper (rr_exit_codex_unavailable / rwc_stage_fallback). ---
WRAPPERS=(make-outline-plan make-detail-plan review-plan-security review-code-security review-tests)
# A non-comment exit 3 with no staging helper on it or in the 3 lines before it.
BARE_AWK='{ b[NR] = $0 } /^[[:space:]]*#/ { next } /(^|[^0-9A-Za-z_])exit 3([^0-9]|$)/ { ok = 0; for (i = NR; i >= NR - 3 && i >= 1; i--) if (b[i] ~ /rr_exit_codex_unavailable|rwc_stage_fallback/) ok = 1; if (!ok) printf "%s ", NR }'

# expect_none <label> <file> — PASS when <file> has no bare exit 3.
expect_none() {
    local hits
    hits="$(awk "$BARE_AWK" "$2")"
    if [ -z "$hits" ]; then pass "$1"; else fail "$1" "bare exit 3 at line(s) $hits"; fi
}

case_begin "t4-10-every-exit-3-stages-the-fallback-first" "bin/run-codex-review-loop"
LOOP_BIN="$SCRIPT_CHECKOUT_ROOT/bin/run-codex-review-loop"
expect_none "the loop has no exit 3 without rr_exit_codex_unavailable" "$LOOP_BIN"
n="$(grep -c 'rr_exit_codex_unavailable' "$LOOP_BIN")"
if [ "$n" -ge 3 ]; then pass "the loop stages at its three exit-3 sites (RV, SKIPPED, FAILED)"
else fail "the loop stages at its three exit-3 sites (RV, SKIPPED, FAILED)" "found $n"; fi
for w in "${WRAPPERS[@]}"; do
    expect_none "$w wrapper: no exit 3 without a staging helper" "$SCRIPT_CHECKOUT_ROOT/skills/$w/scripts/run-codex-review-loop.sh"
done
case_end

case_begin "t4-10-review-tests-skip-stages-the-fallback" "skills/review-tests/scripts/run-codex-review-loop.sh"
if grep -q 'rwc_stage_fallback' "$SCRIPT_CHECKOUT_ROOT/skills/review-tests/scripts/run-codex-review-loop.sh"; then
    pass "the review-tests skip calls rwc_stage_fallback"
else
    fail "the review-tests skip calls rwc_stage_fallback"
fi
case_end

# --- Prestaged (security-scanner) passes of security-code. ---
SC=security-code
EXT=(--cap 2 --max-extensions 1)

case_begin "t5-5-security-code-prestaged-advance-writes-its-row" "bin/lib/codex-review-loop/prestaged-pass.sh"
sid="f5"; F=$SC
export FX_RV=1
loop "$sid" "$F" --cap 2 --max-extensions 1 --extensions-used 0
unset FX_RV
assert_eq "precondition: exit 3" "3" "$L_RC"
assert_eq "security-code exit 3 writes no row" "0" "$(rows "$sid" "$F")"
assert_eq "and stages no pending (the fallback re-enters the wrapper)" "missing" "$(clf_file_state "$(pend "$sid" "$F")")"
REP="$FX_TMP/f5-scanner.txt"
delta "$REP" HIGH "[HIGH] C1 | reviewed.txt#5 | correctness | unchecked input reaches the shell"
prestaged "$sid" "$REP" --cap 2 --max-extensions 1 --extensions-used 0
assert_eq "precondition: the prestaged ADVANCE continues (exit 1)" "1" "$L_RC"
assert_eq "the ADVANCE writes one row" "1" "$(rows "$sid" "$F")"
assert_eq "as cc-fallback" "cc-fallback" "$(row "$sid" "$F" 1 source)"
assert_eq "with the wrapper's exit" "1" "$(row "$sid" "$F" 1 exit)"
assert_eq "at round 1" "1" "$(row "$sid" "$F" 1 counter_round)"
assert_eq "no pending" "missing" "$(clf_file_state "$(pend "$sid" "$F")")"
case_end

PREP="$FX_TMP/scanner.txt"
delta "$PREP" HIGH "[HIGH] C1 | reviewed.txt#5 | correctness | unchecked input reaches the shell"

# A prestaged ADVANCE that halts (exit 4) before its reduce commits must give its round back.
case_begin "b1-prestaged-advance-missing-verdict-engine-rolls-back" "bin/lib/codex-review-loop/prestaged-pass.sh"
sid="fb1"; F=$SC
loop "$sid" "$F" "${EXT[@]}" --extensions-used 0
assert_eq "precondition: the codex round 1 continues (exit 1)" "1" "$L_RC"
bin_aside review-loop-verdict
prestaged "$sid" "$PREP" "${EXT[@]}" --extensions-used 0
bin_back review-loop-verdict
assert_eq "a missing review-loop-verdict is exit 4" "4" "$L_RC"
assert_contains "it names the missing engine" "review-loop-verdict not found or not executable" "$L_ERR"
assert_eq "the counter rolls back to round 1" "1" "$(counter "$sid" "$F" round-number)"
assert_eq "no row is added" "1" "$(rows "$sid" "$F")"
assert_eq "no inflight is left" "0" "$(inflights "$sid" "$F")"
case_end

# No prior round: the allocated round 1 is given back by removing the counter file.
case_begin "b2-prestaged-advance-inconsistent-ledger-rolls-back" "bin/lib/codex-review-loop/prestaged-pass.sh"
sid="fb2"; F=$SC
ledger_rows_lost_on_reduce on
prestaged "$sid" "$PREP" "${EXT[@]}" --extensions-used 0
ledger_rows_lost_on_reduce off
assert_eq "a tally with concerns over a concern-less ledger is exit 4" "4" "$L_RC"
assert_contains "it refuses to judge from an inconsistent ledger" "refusing to judge from an inconsistent ledger" "$L_ERR"
assert_eq "the counter round is not consumed" "absent" "$(counter "$sid" "$F" round-number)"
assert_eq "nor terminated (no last-round)" "absent" "$(counter "$sid" "$F" last-round)"
assert_eq "no row is written" "0" "$(rows "$sid" "$F")"
assert_eq "no inflight is left" "0" "$(inflights "$sid" "$F")"
case_end

# B2's counterpart: a clean report leaves the ledger header-only legitimately, so the round is judged.
case_begin "c1-prestaged-advance-empty-report-header-only-ledger-passes" "bin/lib/codex-review-loop/prestaged-pass.sh"
sid="fc1"; F=$SC
CLEAN="$FX_TMP/clean-scanner.txt"
delta "$CLEAN" HIGH
rm -f "$FX_TMP/reduced-ledger.txt"
ledger_on_reduce snapshot
prestaged "$sid" "$CLEAN" "${EXT[@]}" --extensions-used 0
ledger_on_reduce off
assert_eq "precondition: the reduce left a ledger" "present" "$(clf_file_state "$FX_TMP/reduced-ledger.txt")"
assert_eq "precondition: the reduced ledger holds no concern rows" "0" "$(grep -cE '^C[0-9]+\|' "$FX_TMP/reduced-ledger.txt" 2>/dev/null || true)"
assert_eq "a clean prestaged ADVANCE passes (exit 0)" "0" "$L_RC"
assert_not_contains "it does not refuse to judge" "refusing to judge" "$L_ERR"
assert_eq "it writes exactly one row" "1" "$(rows "$sid" "$F")"
assert_eq "for round 1" "1" "$(row "$sid" "$F" 1 counter_round)"
assert_eq "no inflight is left" "0" "$(inflights "$sid" "$F")"
case_end

case_begin "t5-8-prestaged-advance-derives-at-its-round" "bin/lib/codex-review-loop/prestaged-pass.sh"
loop p8 "$SC" "${EXT[@]}" --extensions-used 0
assert_eq "r1 continues (precondition)" "1" "$L_RC"
loop p8 "$SC" "${EXT[@]}" --extensions-used 0
assert_eq "r2 auto-extends (precondition)" "5" "$L_RC"
export FX_RV=1
loop p8 "$SC" "${EXT[@]}" --extensions-used 1
unset FX_RV
assert_eq "r3 codex failure is exit 3 (precondition)" "3" "$L_RC"
prestaged p8 "$PREP" "${EXT[@]}" --extensions-used 0
assert_ne "the prestaged r3 does not extend again" "5" "$L_RC"
assert_contains "the caller's 0 is overridden by the record's 1" "EXTENSIONS_USED from the caller (0) differs from the review record (1); using 1" "$L_ERR"
case_end

case_begin "t5-8-join-derives-at-the-joined-round" "bin/lib/codex-review-loop/prestaged-pass.sh"
loop p8j "$SC" "${EXT[@]}" --extensions-used 0
assert_eq "r1 continues (precondition)" "1" "$L_RC"
export FX_RV=1
loop p8j "$SC" "${EXT[@]}" --extensions-used 0
unset FX_RV
assert_eq "r2 codex failure is exit 3 (precondition)" "3" "$L_RC"
prestaged p8j "$PREP" "${EXT[@]}" --extensions-used 1 --round 2
assert_contains "round 2 has no extension in the record" "EXTENSIONS_USED from the caller (1) differs from the review record (0); using 0" "$L_ERR"
case_end

# --- The older-input concerns block. ---
OLDER="### Older-input concerns (raised against an earlier input)"
PLAN_ARGS=(--cap 3 --max-extensions 0 --extensions-used 0)

# D8 lists only concerns still open whose last round ran on another input. A plan round is
# complete, so it resolves what it does not re-raise; the re-raised one is on the new input.
case_begin "t5-13-older-input-block-omits-resolved-and-re-raised-plan-format" "bin/run-codex-review-loop"
reply p13 detail-plan 1 "NEEDS_REVISION" "1. [HIGH] an unchecked input reaches the shell" "2. [HIGH] the lock is never released"
reply p13 detail-plan 2 "NEEDS_REVISION" "C2: still open — the lock is never released"
loop p13 detail-plan "${PLAN_ARGS[@]}" --input-fingerprint a
assert_eq "r1 continues (precondition)" "1" "$L_RC"
loop p13 detail-plan "${PLAN_ARGS[@]}" --input-fingerprint b
assert_eq "r2 continues (precondition)" "1" "$L_RC"
assert_not_contains "no block: C1 was resolved and C2 was re-raised against the new input" "$OLDER" "$L_OUT"
case_end

# security-code needs the scanner each round, so a codex-only round 2 leaves C1 open at round 1.
# sc13 <sid> <round body> <fingerprint> — one codex-only security-code round.
sc13() {
    export FX_SC_BODY="$2"
    loop "$1" "$SC" --cap 3 --max-extensions 0 --extensions-used 0 --input-fingerprint "$3"
    unset FX_SC_BODY
}
B1="$FX_TMP/p13-r1.txt"; B2="$FX_TMP/p13-r2.txt"
delta "$B1" HIGH "- [HIGH] - | reviewed.txt#5 | correctness | unchecked input reaches the shell" "- [HIGH] - | reviewed.txt#8 | correctness | the lock is never released"
delta "$B2" HIGH "- [HIGH] C2 | reviewed.txt#8 | correctness | the lock is never released"

case_begin "t5-13-older-input-concerns-block-security-code" "bin/run-codex-review-loop"
sc13 p13s "$B1" a
assert_eq "r1 continues (precondition)" "1" "$L_RC"
sc13 p13s "$B2" b
assert_contains "the block is printed after an input change" "$OLDER" "$L_OUT"
assert_contains "it lists the concern not re-raised, with its round" "- C1 (round 1)" "$L_OUT"
assert_not_contains "the re-raised concern is not listed" "- C2 (round" "$L_OUT"
assert_eq "the label never says stale" "0" "$(printf '%s\n' "$L_OUT" | grep -F 'Older-input' | grep -ci stale)"
case_end

# The block is display only: a twin session with the same replies but an unchanged input
# prints no block, and the two must agree on the exit, the round counter and the record.
case_begin "t5-13-older-input-block-changes-no-decision" "bin/run-codex-review-loop"
for s in p13c p13n; do
    sc13 "$s" "$B1" a
    assert_eq "$s r1 continues (precondition)" "1" "$L_RC"
done
sc13 p13c "$B2" b
C_RC="$L_RC"; C_OUT="$L_OUT"
sc13 p13n "$B2" a
assert_contains "precondition: the changed-input run prints the block" "$OLDER" "$C_OUT"
assert_not_contains "precondition: the unchanged-input run prints none" "$OLDER" "$L_OUT"
assert_eq "the block does not change the exit" "$L_RC" "$C_RC"
assert_eq "nor the round counter" "$(counter p13n "$SC" round-number)" "$(counter p13c "$SC" round-number)"
assert_eq "nor the last round" "$(counter p13n "$SC" last-round)" "$(counter p13c "$SC" last-round)"
assert_eq "nor the number of record rows" "$(rows p13n "$SC")" "$(rows p13c "$SC")"
assert_eq "and both recorded the second round" "2" "$(rows p13c "$SC")"
case_end

finish
