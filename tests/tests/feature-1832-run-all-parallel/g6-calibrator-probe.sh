#!/usr/bin/env bash
# g6-calibrator-probe.sh — the calibrator measures unrecorded tests only when the ledger falls short.
# Tests: bin/calibrate-test-parallelism.sh
# Tags: tests, bin, parallel, calibrator, probe, TL2, scope:issue-specific
# WHY (#2079 S2): the ledger keeps 16 segments, so a host rarely has n + ceil(n/4) in-band
# records. The probe fills the gap by running unrecorded parallel-lane tests, minW at a time,
# with deadline hi + 2, and stops as soon as enough candidates exist. These cases pin what is
# probed, how, when it stops, and that ledger candidates always reach the sample or reserve.
# TL3 gap: the probe's wall time on the real 2-level tree is not covered; stubs stand in.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$AGENTS_DIR/tests/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/_cal-fixture.sh"
cf_init

if [ ! -f "$CF_CAL" ]; then
    fail "g6/implementation-present" "missing: bin/calibrate-test-parallelism.sh"
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

conf_absent() { if [ -e "$1/parallelism.conf" ]; then fail "$2" "a record was written"; else pass "$2"; fi; }
probe_keys() { local n; for n in $(cf_call_nums "$1" probe); do cf_keys "$1" "$n"; done; }
# field_set <stub> <phase> <col> — distinct values of one calls.log column for a phase.
field_set() { awk -v p="$2" -v c="$3" '$2 == p { print $c }' "$1/calls.log" 2>/dev/null | LC_ALL=C sort -u | tr '\n' ' '; }
J24=(--jobs-list "2 4" --repeat 1 --warmup 1)

# (1) enough ledger candidates (15 = 12 + 3) -> the probe never runs
S="$(cf_new_suite)"; R="$(cf_new_real)"
cf_populate "$S" "$R" bin/a 15 6
cf_populate "$S" "$R" hooks/p 10 6 noledger
ST="$(cf_stub)"
cf_run "$S" "$R" "$ST" "${J24[@]}"
ck "g6/enough-ledger/exit-0" "0" "$CF_RC"
ck "g6/enough-ledger/no-probe" "0:yes" "$(cf_calls "$ST" probe):$([ "$(cf_calls "$ST")" -gt 0 ] && echo yes)"

# (2)(3)(4) 12 ledger candidates: probe only unrecorded parallel tests, minW at a time
S="$(cf_new_suite)"; R="$(cf_new_real)"
cf_populate "$S" "$R" bin/a 12 6
cf_populate "$S" "$R" bin/o 1 30
cf_populate "$S" "$R" bin/s 1 6 serial
cf_populate "$S" "$R" hooks/p 10 6 noledger
cf_populate "$S" "$R" hooks/z 1 6 serial
ST="$(cf_stub)"
cf_run "$S" "$R" "$ST" "${J24[@]}"
ck "g6/shortfall/exit-0" "0" "$CF_RC"
ck "g6/shortfall/stops-when-required-reached" "2" "$(cf_calls "$ST" probe)"
ck "g6/shortfall/probe-width-is-min-width" "2 " "$(field_set "$ST" probe 3)"
ck "g6/shortfall/probe-count-is-min-width" "2 " "$(field_set "$ST" probe 6)"
ck "g6/shortfall/probe-deadline-hi-plus-2" "12 " "$(field_set "$ST" probe 4)"
PK="$(probe_keys "$ST")"
if [ -n "$PK" ] && ! printf '%s\n' "$PK" | grep -qv '^hooks/p'; then pass "g6/shortfall/only-unrecorded-parallel-probed"
else fail "g6/shortfall/only-unrecorded-parallel-probed" "probed: $(printf '%s' "$PK" | tr '\n' ' ')"; fi
FIRST_MEASURED="$(awk '$2 != "probe" { print $1; exit }' "$ST/calls.log" 2>/dev/null)"
LAST_PROBE="$(cf_call_nums "$ST" probe | tail -n 1)"
if [ -n "$FIRST_MEASURED" ] && [ -n "$LAST_PROBE" ] && [ "$LAST_PROBE" -lt "$FIRST_MEASURED" ]; then
    pass "g6/shortfall/probe-before-measurement"
else fail "g6/shortfall/probe-before-measurement" "calls: $(cut -d' ' -f1-2 "$ST/calls.log" 2>/dev/null | tr '\n' ',')"; fi

# deadline follows the band: --band 5:7 -> 9
ST="$(cf_stub)"
cf_run "$S" "$R" "$ST" --band 5:7 "${J24[@]}"
ck "g6/shortfall/deadline-follows-band" "9 " "$(field_set "$ST" probe 4)"

# (5) a dominating probe test (no record, rc=3) only drops out
S="$(cf_new_suite)"; R="$(cf_new_real)"
cf_populate "$S" "$R" bin/a 12 6
cf_populate "$S" "$R" hooks/p 10 6 noledger
ST="$(cf_stub)"
printf 'rc=3\n' > "$ST/probe.1.extra"
printf '@1\t-\n' > "$ST/probe.1.secs"
cf_run "$S" "$R" "$ST" "${J24[@]}"
ck "g6/probe-deadline/exit-0" "0" "$CF_RC"
ck "g6/probe-deadline/one-more-round" "2" "$(cf_calls "$ST" probe)"
DROPPED="$(cat "$ST/call.1.overridden" 2>/dev/null)"
HIT=0
for n in $(awk '$2 != "probe" { print $1 }' "$ST/calls.log" 2>/dev/null); do
    cf_keys "$ST" "$n" | grep -qxF "$DROPPED" && HIT=1
done
ck "g6/probe-deadline/dominating-test-not-sampled" "0:yes" "$HIT:$([ -n "$DROPPED" ] && echo yes)"

# (6) probing everything still leaves fewer than n -> too-few-candidates
S="$(cf_new_suite)"; R="$(cf_new_real)"
cf_populate "$S" "$R" bin/a 6 6
cf_populate "$S" "$R" hooks/p 4 2 noledger
ST="$(cf_stub)"
cf_run "$S" "$R" "$ST" "${J24[@]}"
if cf_inconclusive too-few-candidates; then pass "g6/too-few/token"
else fail "g6/too-few/token" "rc=$CF_RC err=$(printf '%s' "$CF_ERR" | tail -n 2)"; fi
ck "g6/too-few/probed-all" "2" "$(cf_calls "$ST" probe)"
ck "g6/too-few/no-warmup-or-measure" "0" "$(( $(cf_calls "$ST" warmup) + $(cf_calls "$ST" measure) ))"
conf_absent "$R" "g6/too-few/no-record"
if printf '%s\n' "$CF_ERR" | grep -q -- '--band' && printf '%s\n' "$CF_ERR" | grep -q -- '--jobs-list'; then
    pass "g6/too-few/advises-band-and-jobs-list"
else fail "g6/too-few/advises-band-and-jobs-list" "stderr lacks the --band / --jobs-list hint"; fi

# (7) at least n but below n + reserve -> proceeds with a smaller reserve
S="$(cf_new_suite)"; R="$(cf_new_real)"
cf_populate "$S" "$R" bin/a 12 6
cf_populate "$S" "$R" hooks/p 2 2 noledger
ST="$(cf_stub)"
cf_run "$S" "$R" "$ST" "${J24[@]}"
ck "g6/short-reserve/exit-0" "0" "$CF_RC"
ck "g6/short-reserve/probed-all" "1" "$(cf_calls "$ST" probe)"

# (8) every ledger candidate reaches the sample or the reserve
S="$(cf_new_suite)"; R="$(cf_new_real)"
cf_populate "$S" "$R" bin/a 13 6
cf_populate "$S" "$R" hooks/p 10 6 noledger
ST="$(cf_stub)"
for k in 1 2 3; do printf '@1\t40\n' > "$ST/warmup.$k.secs"; done
cf_run "$S" "$R" "$ST" "${J24[@]}"
ck "g6/ledger-first/exit-0" "0" "$CF_RC"
WK="$(for n in $(cf_call_nums "$ST" warmup); do cf_keys "$ST" "$n"; done | LC_ALL=C sort -u)"
MISSING=0
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13; do
    printf '%s\n' "$WK" | grep -qxF "bin/a$i.sh" || MISSING=$((MISSING + 1))
done
ck "g6/ledger-first/all-13-ledger-candidates-used" "0" "$MISSING"

# (9) an empty real ledger (no segment at all) -> the probe alone succeeds
S="$(cf_new_suite)"; R="$(cf_new_real)"
cf_populate "$S" - hooks/p 20 6 noledger
ST="$(cf_stub)"
cf_run "$S" "$R" "$ST" --jobs-list "1 2" --repeat 1 --warmup 1
ck "g6/empty-ledger/exit-0" "0" "$CF_RC"
ck "g6/empty-ledger/probe-rounds" "8" "$(cf_calls "$ST" probe)"
if [ -d "$R/durations" ]; then fail "g6/empty-ledger/real-area-not-written" "durations/ appeared in the real area"
else pass "g6/empty-ledger/real-area-not-written"; fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
