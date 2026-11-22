#!/usr/bin/env bash
# Tests: bin/lib/codex-review-loop/review-record.sh, bin/run-codex-review-loop
# Tags: feature-2478, review-record, codex-review-loop, cc-fallback, legacy-pending, static, scope:issue-specific, TL2
#
# #2478 T7: a fallback pending / discarded file left by the retired stage / record route is
# deleted at preflight with a one-line notice; counter and rows stay untouched and the review
# goes on as the next round. A file that cannot be deleted halts (exit 4). Static: no file of
# bin / hooks / skills names the retired route, and the loop's exit-3 sites keep one helper.
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

# legacy_case <sid> <suffix> — round 1 by codex, a legacy file, then the next review.
legacy_case() {
    local sid="$1" F=detail-plan file base
    seed_sid "$sid"
    st seed "$sid"
    loop "$sid" "$F" "${LOOP_ARGS[@]}"
    assert_eq "$2: round 1 (precondition)" "1" "$L_RC"
    file="$(side "$sid" "$F" "$2")"
    base="$(basename "$file")"
    printf '{"format":"%s","counter_round":2}\n' "$F" > "$file"
    loop "$sid" "$F" "${LOOP_ARGS[@]}"
    assert_contains "$2: the notice names the file" "review-rounds: discarded a legacy CC-fallback pending (" "$L_ERR"
    assert_contains "$2: the notice carries the file name" "$base" "$L_ERR"
    assert_contains "$2: the notice says the round was never counted" \
        "); its round was never counted — re-run the review" "$L_ERR"
    assert_eq "$2: the legacy file is deleted" "missing" "$(clf_file_state "$file")"
    assert_eq "$2: the review goes on as round 2" "2" "$(row "$sid" "$F" -1 counter_round)"
    assert_eq "$2: one row per review, none for the legacy file" "2" "$(rows "$sid" "$F")"
    assert_eq "$2: the counter is the review's round" "2" "$(counter "$sid" "$F" round-number)"
}

case_begin "legacy-pending-is-discarded-with-a-notice" "bin/lib/codex-review-loop/review-record.sh"
legacy_case f7p -fallback-pending.json
case_end

case_begin "legacy-discarded-file-is-discarded-with-a-notice" "bin/lib/codex-review-loop/review-record.sh"
legacy_case f7d -fallback-discarded.json
case_end

case_begin "legacy-pending-that-cannot-be-deleted-halts" "bin/lib/codex-review-loop/review-record.sh"
sid=f7x; F=detail-plan
seed_sid "$sid"
st seed "$sid"
loop "$sid" "$F" "${LOOP_ARGS[@]}"
assert_eq "round 1 (precondition)" "1" "$L_RC"
mkdir -p "$(pend "$sid" "$F")/keep"
loop "$sid" "$F" "${LOOP_ARGS[@]}"
assert_eq "an undeletable legacy pending is exit 4" "4" "$L_RC"
assert_eq "no row is added" "1" "$(rows "$sid" "$F")"
assert_eq "the counter stays at round 1" "1" "$(counter "$sid" "$F" round-number)"
assert_eq "no inflight is left" "0" "$(inflights "$sid" "$F")"
rm -rf "$(pend "$sid" "$F")"
case_end

# --- Static: the retired route is gone; exit 3 sites still go through one helper. ---
case_begin "retired-fallback-route-has-no-reference-left" "bin/run-codex-review-loop"
LOOP_BIN="$SCRIPT_CHECKOUT_ROOT/bin/run-codex-review-loop"
n="$(grep -c 'rr_exit_codex_unavailable' "$LOOP_BIN")"
if [ "$n" -ge 3 ]; then pass "the loop's three exit-3 sites (RV, SKIPPED, FAILED) use rr_exit_codex_unavailable"
else fail "the loop's three exit-3 sites (RV, SKIPPED, FAILED) use rr_exit_codex_unavailable" "found $n"; fi
# The store alone may name the legacy file: it is what detects and deletes it.
hits="$(grep -rlE 'stage-fallback|record-fallback|discard-fallback|fallback-pending|rwc_stage_fallback|stageFallback|recordFallback|discardFallback' \
    "$SCRIPT_CHECKOUT_ROOT/bin" "$SCRIPT_CHECKOUT_ROOT/hooks" "$SCRIPT_CHECKOUT_ROOT/skills" \
    "$SCRIPT_CHECKOUT_ROOT/agents" "$SCRIPT_CHECKOUT_ROOT/docs" 2>/dev/null \
    | grep -v '/review-rounds-store\.js$' \
    | grep -vE '/(history|CHANGELOG)\.md$|/_archived?/' | tr '\n' ' ')"
# history / changelog / archives are append-only records of the past and may name the retired route.
assert_eq "no file in bin / hooks / skills / agents / docs names the retired route" "" "$hits"
store_hits="$(grep -cE 'stageFallback|recordFallback|discardFallback' \
    "$SCRIPT_CHECKOUT_ROOT/bin/lib/codex-review-loop/review-rounds-store.js")"
assert_eq "the store keeps no stage / record / discard function" "0" "$store_hits"
case_end

finish
