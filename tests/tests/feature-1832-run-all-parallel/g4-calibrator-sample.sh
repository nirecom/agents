#!/usr/bin/env bash
# g4-calibrator-sample.sh — the calibrator draws its sample from the duration ledger.
# Tests: bin/calibrate-test-parallelism.sh
# Tags: tests, bin, parallel, calibrator, sample, TL2, scope:issue-specific
# WHY (#2079 S2/S5): the old scan read only flat <TESTS_DIR>/*.sh and found 0 tests in the real
# 2-level tree. Sampling now comes from the run-all plan plus ledger seconds in a band, so
# these cases pin candidate selection, sample size n = 3 x max width, the reserve
# n + ceil(n/4), determinism, the feasibility gate, and the --dry-run report.
# TL3 gap: the band's 20% hit-rate on a real host is not covered; seam stubs replace real runs.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/_cal-fixture.sh"
cf_init

if [ ! -f "$CF_CAL" ]; then
    fail "g4/implementation-present" "missing: bin/calibrate-test-parallelism.sh"
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

all_keys() { cat "$1"/call.*.keys 2>/dev/null; return 0; }
conf_absent() {
    if [ -e "$1/parallelism.conf" ]; then fail "$2" "a record was written"; else pass "$2"; fi
}

# ---------------------------------------------------------------------------
# (1)(2)(3) 2-level corpus; serial and out-of-band tests never chosen; n = 3 x maxW
# ---------------------------------------------------------------------------
S1="$(cf_new_suite)"; R1="$(cf_new_real)"
cf_populate "$S1" "$R1" bin/a 4 6
cf_populate "$S1" "$R1" hooks/b 4 6
cf_populate "$S1" "$R1" bin/s 1 6 serial
cf_populate "$S1" "$R1" bin/lo 1 2
cf_populate "$S1" "$R1" bin/hi 1 30
ST1="$(cf_stub)"
cf_run "$S1" "$R1" "$ST1" --jobs-list "1 2" --repeat 1 --warmup 1
ck "g4/corpus/exit-0" "0" "$CF_RC"
ck "g4/corpus/first-call-is-warmup" "warmup" "$(cf_call_field "$ST1" 1 2)"
ck "g4/corpus/sample-is-3x-max-width" "6" "$(cf_call_field "$ST1" 1 6)"
ck "g4/corpus/8-candidates-no-probe" "0:yes" "$(cf_calls "$ST1" probe):$([ "$(cf_calls "$ST1")" -gt 0 ] && echo yes)"
K1="$(all_keys "$ST1")"
for x in bin/s01 bin/lo01 bin/hi01; do
    k="$(cf_key_of "$S1" "$x")"
    if [ -n "$K1" ] && ! printf '%s\n' "$K1" | grep -qxF "$k"; then
        pass "g4/excluded-never-sampled/$x"
    else
        fail "g4/excluded-never-sampled/$x" "$k reached the seam (or the seam saw no test at all)"
    fi
done
if cf_keys "$ST1" 1 | grep -q '^bin/' && cf_keys "$ST1" 1 | grep -q '^hooks/'; then
    pass "g4/two-level-corpus-both-categories"
else
    fail "g4/two-level-corpus-both-categories" "call 1 keys: $(cf_keys "$ST1" 1 | tr '\n' ' ')"
fi
if printf '%s\n' "$CF_OUT" "$CF_ERR" | grep -qE '^calibrate: selected max jobs per host [0-9]+ \(sample 6 tests; widths 1 2\)$'; then
    pass "g4/final-line-format"
else
    fail "g4/final-line-format" "rc=$CF_RC err=$(printf '%s' "$CF_ERR" | tail -n 3)"
fi

# (3) reserve boundary: required = n + ceil(n/4) = 8 for "1 2"; 7 candidates must probe.
S2="$(cf_new_suite)"; R2="$(cf_new_real)"
cf_populate "$S2" "$R2" bin/a 7 6
cf_populate "$S2" "$R2" hooks/p 10 6 noledger
ST2="$(cf_stub)"
cf_run "$S2" "$R2" "$ST2" --jobs-list "1 2" --repeat 1 --warmup 1
ck "g4/required-boundary/7-of-8-exit-0" "0" "$CF_RC"
if [ "$(cf_calls "$ST2" probe)" -ge 1 ]; then pass "g4/required-boundary/7-of-8-probes"
else fail "g4/required-boundary/7-of-8-probes" "no probe call with 7 candidates for required 8"; fi

# "2 4": n = 12, required = 15.
S3="$(cf_new_suite)"; R3="$(cf_new_real)"
cf_populate "$S3" "$R3" bin/a 8 6
cf_populate "$S3" "$R3" hooks/b 7 6
cf_populate "$S3" "$R3" hooks/p 10 6 noledger
ST3="$(cf_stub)"
cf_run "$S3" "$R3" "$ST3" --jobs-list "2 4" --repeat 1 --warmup 1
ck "g4/required-boundary/15-of-15-exit-0" "0" "$CF_RC"
ck "g4/required-boundary/15-of-15-no-probe" "0:yes" "$(cf_calls "$ST3" probe):$([ "$(cf_calls "$ST3")" -gt 0 ] && echo yes)"
ck "g4/required-boundary/15-of-15-sample-12" "12" "$(cf_call_field "$ST3" 1 6)"

S4="$(cf_new_suite)"; R4="$(cf_new_real)"
cf_populate "$S4" "$R4" bin/a 7 6
cf_populate "$S4" "$R4" hooks/b 7 6
cf_populate "$S4" "$R4" hooks/p 10 6 noledger
ST4="$(cf_stub)"
cf_run "$S4" "$R4" "$ST4" --jobs-list "2 4" --repeat 1 --warmup 1
ck "g4/required-boundary/14-of-15-exit-0" "0" "$CF_RC"
if [ "$(cf_calls "$ST4" probe)" -ge 1 ]; then pass "g4/required-boundary/14-of-15-probes"
else fail "g4/required-boundary/14-of-15-probes" "no probe call with 14 candidates for required 15"; fi

# ---------------------------------------------------------------------------
# (4) same input, same sample
# ---------------------------------------------------------------------------
ST3b="$(cf_stub)"
cf_run "$S3" "$R3" "$ST3b" --jobs-list "2 4" --repeat 1 --warmup 1
A="$(cf_keys "$ST3" 1)"; B="$(cf_keys "$ST3b" 1)"
if [ -n "$A" ] && [ "$A" = "$B" ]; then pass "g4/deterministic-sample"
else fail "g4/deterministic-sample" "first=$(printf '%s' "$A" | tr '\n' ' ') second=$(printf '%s' "$B" | tr '\n' ' ')"; fi

# ---------------------------------------------------------------------------
# (5) feasibility: one 10 s test dominates 5 x 1 s at max width 2 -> infeasible-sample
# ---------------------------------------------------------------------------
S5="$(cf_new_suite)"; R5="$(cf_new_real)"
cf_populate "$S5" "$R5" bin/q 7 1
cf_populate "$S5" "$R5" hooks/big 1 10
ST5="$(cf_stub)"
cf_run "$S5" "$R5" "$ST5" --band 1:10 --jobs-list "1 2" --repeat 1 --warmup 1
if cf_inconclusive infeasible-sample; then pass "g4/infeasible/exit-5-token"
else fail "g4/infeasible/exit-5-token" "rc=$CF_RC err=$(printf '%s' "$CF_ERR" | tail -n 2)"; fi
ck "g4/infeasible/no-warmup-or-measure-call" "0" "$(( $(cf_calls "$ST5" warmup) + $(cf_calls "$ST5" measure) ))"
conf_absent "$R5" "g4/infeasible/no-record"

# ---------------------------------------------------------------------------
# --sample below the max width is a usage error; equal to it is accepted
# ---------------------------------------------------------------------------
ST6="$(cf_stub)"
cf_run "$S1" "$R1" "$ST6" --sample 1 --jobs-list "1 2" --repeat 1 --warmup 1
ck "g4/sample-below-max-width/exit-2" "2" "$CF_RC"
ck "g4/sample-below-max-width/no-seam-call" "0" "$(cf_calls "$ST6")"
if printf '%s\n' "$CF_ERR" | grep -qi 'sample'; then pass "g4/sample-below-max-width/names-sample"
else fail "g4/sample-below-max-width/names-sample" "usage error does not name --sample: $CF_ERR"; fi
ST7="$(cf_stub)"
cf_run "$S1" "$R1" "$ST7" --sample 2 --jobs-list "1 2" --repeat 1 --warmup 1
ck "g4/sample-equal-max-width/exit-0" "0" "$CF_RC"
ck "g4/sample-equal-max-width/list-2" "2" "$(cf_call_field "$ST7" 1 6)"

# ---------------------------------------------------------------------------
# (6)(7) --dry-run reports the plan and never calls the seam; default ladder
# ---------------------------------------------------------------------------
S8="$(cf_new_suite)"; R8="$(cf_new_real)"
cf_populate "$S8" "$R8" bin/a 5 6
cf_populate "$S8" "$R8" hooks/p 6 6 noledger
ST8="$(cf_stub)"
CF_NO_OPTIN=1 cf_run "$S8" "$R8" "$ST8" --dry-run --jobs-list "1 2"
ck "g4/dry-run/exit-0" "0" "$CF_RC"
ck "g4/dry-run/no-seam-call" "0" "$(cf_calls "$ST8")"
DR="$(printf '%s\n%s\n' "$CF_OUT" "$CF_ERR")"
for pat in 'candidates?[^0-9]*5' 'short(fall)?[^0-9]*3' 'probe' 'time[ _-]?limit[^0-9]*90'; do
    if printf '%s\n' "$DR" | grep -qiE "$pat"; then pass "g4/dry-run/reports/$pat"
    else fail "g4/dry-run/reports/$pat" "dry-run output lacks /$pat/"; fi
done
conf_absent "$R8" "g4/dry-run/no-record"
CF_NO_OPTIN=1 cf_run "$S8" "$R8" "$ST8" --dry-run
ck "g4/default-ladder/exit-0" "0" "$CF_RC"
if printf '%s\n%s\n' "$CF_OUT" "$CF_ERR" | grep -q '4 6 8 12 16'; then pass "g4/default-ladder/shown"
else fail "g4/default-ladder/shown" "dry-run without --jobs-list does not show 4 6 8 12 16"; fi
ck "g4/default-ladder/no-seam-call" "0" "$(cf_calls "$ST8")"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
