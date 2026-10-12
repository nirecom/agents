#!/usr/bin/env bash
# g7-calibrator-exit77.sh — a measurement whose run-all ended 77 (nothing ran, all SKIP) still counts.
# Tests: bin/calibrate-test-parallelism.sh
# Tags: tests, bin, parallel, calibrator, exit-77, TL2, scope:issue-specific
# WHY (#2501 C1): run-all now exits 77 when no test passed; the elapsed time of such a run
# is still a valid timing sample, so measure.sh accepts rc 77 instead of calling it run-failed.
# TL3 gap: a real host's all-skip corpus is not measured; the seam stub and a tiny suite stand in.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/_cal-fixture.sh"
cf_init

MEASURE_MOD="$CF_REPO/bin/calibrate-test-parallelism/measure.sh"
if [ ! -f "$CF_CAL" ]; then
    fail "g7/implementation-present" "missing: bin/calibrate-test-parallelism.sh"
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

corpus() {
    local s r
    s="$(cf_new_suite)"; r="$(cf_new_real)"
    cf_populate "$s" "$r" bin/a "$1" 6
    printf '%s %s' "$s" "$r"
}
ARGS=(--jobs-list "1 2" --repeat 1 --warmup 1)

# (1) the seam reports rc 77 on a warmup and on a measure call -> the calibration succeeds
for ph in warmup measure; do
    read -r S R <<< "$(corpus 8)"
    ST="$(cf_stub)"; printf 'rc=77\n' > "$ST/$ph.1.extra"
    cf_run "$S" "$R" "$ST" "${ARGS[@]}"
    ck "g7/seam-rc-77/$ph/exit-0" "0" "$CF_RC"
    if printf '%s\n' "$CF_ERR" | grep -q 'run-failed'; then
        fail "g7/seam-rc-77/$ph/not-run-failed" "err=$(printf '%s' "$CF_ERR" | tail -n 2)"
    else pass "g7/seam-rc-77/$ph/not-run-failed"; fi
done

# (2) control: an exit code outside the accepted set is still run-failed
read -r S R <<< "$(corpus 8)"
ST="$(cf_stub)"; printf 'rc=76\n' > "$ST/warmup.1.extra"
cf_run "$S" "$R" "$ST" "${ARGS[@]}"
if cf_inconclusive run-failed; then pass "g7/control/rc-76-run-failed"
else fail "g7/control/rc-76-run-failed" "rc=$CF_RC err=$(printf '%s' "$CF_ERR" | tail -n 2)"; fi

# (3) one child run through the REAL runner over an all-skip list reports rc 77
child() {
    ( SCRIPT_CHECKOUT_ROOT="$CF_REPO"; RUNNER="$CF_REPO/tests/run-all.sh"; TEST_LANES=off
      export RUNNER TEST_LANES
      . "$CF_LIB_PAR" >/dev/null 2>&1; . "$CF_LIB_DUR" >/dev/null 2>&1
      . "$MEASURE_MOD" >/dev/null 2>&1 || exit 9
      cal_child_run "$@" ) >/dev/null 2>&1
}
CS="$(cf_new_suite)"; CR="$(cf_new_real)"
cf_ledger_raw "$CR" "$CS" /dev/null
for n in s1 s2; do
    printf '#!/usr/bin/env bash\n# Tests: tests/run-all.sh\necho "SKIP: fixture"\nexit 77\n' > "$CS/bin/$n.sh"
done
printf '%s\n' "$CS/bin/s1.sh" "$CS/bin/s2.sh" > "$CF_T/child77.list"
if [ ! -f "$MEASURE_MOD" ]; then
    fail "g7/child-run/module-present" "missing: bin/calibrate-test-parallelism/measure.sh"
else
    RUN_ALL_CACHE_DIR="$CR" TESTS_DIR="$CS" child 2 "$CF_T/child77.list" 30 measure "$CF_T/child77.rep"
    ck "g7/child-run/all-skip/rc-77" "rc=77" "$(grep '^rc=' "$CF_T/child77.rep" 2>/dev/null)"
    if grep -qE '^ms=[0-9]+$' "$CF_T/child77.rep" 2>/dev/null; then pass "g7/child-run/all-skip/ms"
    else fail "g7/child-run/all-skip/ms" "no ms= line"; fi
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
