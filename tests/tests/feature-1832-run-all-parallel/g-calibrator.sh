#!/usr/bin/env bash
# tests/tests/feature-1832-run-all-parallel/g-calibrator.sh
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, calibrator, TL2, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests
# WHY (CPR-WPH): the calibrator is the sole record writer — unreachable from a normal run,
# free on inquiry sub-modes, opt-in via RUN_CALIBRATION=1. The knee is SELECTED by a fixed
# rule and the record is the reader's v2 key set (#2079 S11). Measurements go through the
# _cal-fixture.sh seam stub over a 2-level ledger corpus (#2079 S5); nothing times a real run.
# TL3 gap: whether the knee heuristic picks a genuinely good value on real hardware is not covered.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/_cal-fixture.sh"
REAL_RUN_ALL="${HOME:-/nonexistent}/.claude/run-all"
REAL_PRE=0; [ -e "$REAL_RUN_ALL" ] && REAL_PRE=1
cf_init
harness_isolate "$CF_T/iso"   # top-level pin: cf_init pins inside a function, which the guard does not read

RUNNER="$SCRIPT_CHECKOUT_ROOT/tests/run-all.sh"
EXEC_MODEL="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-run-tests/exec-model.js"
CAL_TGT="bin/calibrate-test-parallelism.sh"

contract_count() {
    printf '%s\n' "$1" | grep -cE '^[[:space:]]*RUN_CONTRACT: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+ EXECUTED=[0-9]+' || true
}
conf_value() { sed -n "s/^$2=//p" "$1/parallelism.conf" 2>/dev/null | head -n 1; }
conf_keys() { sed -n 's/^\([a-z_]*\)=.*/\1/p' "$1/parallelism.conf" 2>/dev/null | LC_ALL=C sort | tr '\n' ' '; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
cal_missing() { [ -f "$CF_CAL" ] && return 1; fail "$1" "implementation missing: $CAL_TGT"; return 0; }

# 30 in-band ledger candidates: n = 3 x 8 = 24, required 30 -> the knee ladder never probes.
SK="$(cf_new_suite)"; RK="$(cf_new_real)"
cf_populate "$SK" "$RK" bin/a 15 6
cf_populate "$SK" "$RK" hooks/b 15 6

# 1. Unreachable from a normal run
case_unreachable() {
    local hits got
    hits="$(grep -cE '(bash|sh|exec|source|^[[:space:]]*\.)[[:space:]]+[^[:space:]]*calibrate-test-parallelism\.sh' "$RUNNER" 2>/dev/null || true)"
    ck "g-cal/unreachable/runner-never-executes-it" "0" "$hits"
    if [ ! -f "$EXEC_MODEL" ]; then
        fail "g-cal/unreachable/name-is-not-a-test-command" "missing: hooks/workflow-run-tests/exec-model.js"
    else
        got="$(run_with_timeout 30 node -e '
try { const m = require(process.argv[1]);
  process.stdout.write(String(m.isTestCommand("bash bin/calibrate-test-parallelism.sh --dry-run")));
} catch (e) { process.stdout.write("ERR"); }' "$(np "$EXEC_MODEL")" 2>/dev/null)"
        ck "g-cal/unreachable/name-is-not-a-test-command" "false" "$got"
    fi
}

# 2. Inquiry sub-modes cost nothing and write nothing
case_inquiry() {
    local mode n st
    for mode in --help --dry-run; do
        n="${mode#--}"
        cal_missing "g-cal/inquiry/$n-exit-zero" && continue
        rm -f "$RK/parallelism.conf"
        st="$(cf_stub)"
        CF_NO_OPTIN=1 cf_run "$SK" "$RK" "$st" "$mode"
        ck "g-cal/inquiry/$n-exit-zero" "0" "$CF_RC"
        if [ -e "$RK/parallelism.conf" ]; then fail "g-cal/inquiry/$n-writes-no-record" "$mode wrote a record"
        else pass "g-cal/inquiry/$n-writes-no-record"; fi
        ck "g-cal/inquiry/$n-no-seam-call" "0" "$(cf_calls "$st")"
        ck "g-cal/inquiry/$n-no-contract-shape" "0" "$(contract_count "$CF_OUT$CF_ERR")"
    done
    if ! cal_missing "g-cal/inquiry/print-without-record-is-nonzero"; then
        rm -f "$RK/parallelism.conf"
        CF_NO_OPTIN=1 cf_run "$SK" "$RK" - --print
        if [ "$CF_RC" -ne 0 ]; then pass "g-cal/inquiry/print-without-record-is-nonzero"
        else fail "g-cal/inquiry/print-without-record-is-nonzero" "want non-zero, got 0"; fi
    fi
}

# 3. A real measurement is opt-in
case_opt_in() {
    local st
    if ! cal_missing "g-cal/optin/without-flag-exits-77"; then
        rm -f "$RK/parallelism.conf"
        st="$(cf_stub)"
        CF_NO_OPTIN=1 cf_run "$SK" "$RK" "$st" --jobs-list "1 2" --repeat 3 --warmup 0
        ck "g-cal/optin/without-flag-exits-77" "77" "$CF_RC"
        ck "g-cal/optin/without-flag-no-seam-call" "0" "$(cf_calls "$st")"
        if [ -e "$RK/parallelism.conf" ]; then fail "g-cal/optin/without-flag-writes-no-record" "a record was written without RUN_CALIBRATION=1"
        else pass "g-cal/optin/without-flag-writes-no-record"; fi
    fi
}

# 4. Synthetic curves — knee = smallest w with 100*min_median >= 95*median(w); rc=1 is unstable.
case_knee_curves() {
    local name spec want_rc want_jobs st
    while IFS='|' read -r name spec want_rc want_jobs; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        spec="$(trim "$spec")"; want_rc="$(trim "$want_rc")"; want_jobs="$(trim "$want_jobs")"
        cal_missing "g-cal/knee/$name/exit-code" && continue
        rm -f "$RK/parallelism.conf"
        st="$(cf_stub "$spec")"; : > "$st/noseg"
        cf_run "$SK" "$RK" "$st" --jobs-list "1 2 4 8" --repeat 3 --warmup 0
        ck "g-cal/knee/$name/exit-code" "$want_rc" "$CF_RC"
        ck "g-cal/knee/$name/twelve-measure-calls-no-probe" "0:12" "$(cf_calls "$st" probe):$(cf_calls "$st" measure)"
        if [ "$want_jobs" = "none" ]; then
            if [ -e "$RK/parallelism.conf" ]; then fail "g-cal/knee/$name/selected" "stability gate did not fire: a record was written"
            else pass "g-cal/knee/$name/selected"; fi
            case "$CF_ERR" in
                *unstable*|*stability*|*variance*) pass "g-cal/knee/$name/explains-itself" ;;
                *) fail "g-cal/knee/$name/explains-itself" "stderr must state why no record was written" ;;
            esac
        else
            ck "g-cal/knee/$name/selected" "$want_jobs" "$(cf_selected)"
        fi
    done <<'TABLE'
# name                 | width:ms,ms,ms per repeat (jobs-list 1 2 4 8, repeat 3)                | rc | jobs
clean-knee             | 1:8000,8000,8000 2:4000,4000,4000 4:2000,2000,2000 8:1950,1950,1950   | 0  | 4
saturation             | 1:1000,1000,1000 2:1000,1000,1000 4:1000,1000,1000 8:1000,1000,1000   | 0  | 1
tie-smaller-width-wins | 1:2000,2000,2000 2:1000,1000,1000 4:990,990,990 8:5000,5000,5000      | 0  | 2
exactly-95-percent     | 1:2000,2000,2000 2:1000,1000,1000 4:950,950,950 8:950,950,950         | 0  | 2
peak-then-decline      | 1:4000,4000,4000 2:1000,1000,1000 4:2000,2000,2000 8:8000,8000,8000   | 0  | 2
noisy-under-gate       | 1:1000,1400,1200 2:500,600,550 4:480,500,490 8:470,500,480            | 0  | 4
noisy-over-gate        | 1:1000,1600,1000 2:500,500,500 4:480,480,480 8:470,470,470            | 1  | none
TABLE
}

# 5. Warmup discard and order-crossing traversal
case_protocol() {
    local st w1 w2 w3
    if ! cal_missing "g-cal/protocol/warmup-exit-zero"; then
        # A 5000 ms warmup per width would trip the 1.5x gate if counted; discarded, width 2 wins.
        st="$(cf_stub "1:5000,1000,1000,1000 2:5000,500,500,500")"; : > "$st/noseg"
        cf_run "$SK" "$RK" "$st" --sample 4 --jobs-list "1 2" --repeat 3 --warmup 1
        ck "g-cal/protocol/warmup-exit-zero" "0" "$CF_RC"
        ck "g-cal/protocol/warmup-excluded-from-selection" "2" "$(cf_selected)"
        ck "g-cal/protocol/measurement-call-count" "8" "$(cf_calls "$st")"
        ck "g-cal/protocol/sample-4-per-call" "4 " "$(awk '{ print $6 }' "$st/calls.log" 2>/dev/null | LC_ALL=C sort -u | tr '\n' ' ')"
        # Pure drift, no width effect: a single-order traversal would select 1; crossing gives 2.
        st="$(cf_stub_drift 1000 20)"
        cf_run "$SK" "$RK" "$st" --sample 8 --jobs-list "1 2 4 8" --repeat 3 --warmup 0
        w1="$(awk '$1 >= 1 && $1 <= 4 { print $3 }' "$st/calls.log" 2>/dev/null | tr '\n' ' ')"
        w2="$(awk '$1 >= 5 && $1 <= 8 { print $3 }' "$st/calls.log" 2>/dev/null | tr '\n' ' ')"
        w3="$(awk '$1 >= 9 && $1 <= 12 { print $3 }' "$st/calls.log" 2>/dev/null | tr '\n' ' ')"
        if [ -n "$w1" ] && { [ "$w1" != "$w2" ] || [ "$w2" != "$w3" ]; }; then
            pass "g-cal/protocol/order-crossing-traversal-varies"
        else fail "g-cal/protocol/order-crossing-traversal-varies" "every repeat traversed: $(printf '%q' "$w1")"; fi
        ck "g-cal/protocol/order-crossing-neutralizes-drift" "2" "$(cf_selected)"
    fi
}

# 6. record_*: the published record is the reader's v2 key set (#2079 S11)
V2_KEYS="host_id max_jobs_per_host measured_at os repeat sample_size schema "
lib_eval() { env "TESTS_DIR=$SK" bash -c '. "$1" >/dev/null 2>&1 || exit 9; shift; "$@"' _ "$CF_LIB_PAR" "$@" 2>/dev/null; }
record_published() {
    local st v schema_want os_want before after
    cal_missing "g-cal/record/exit-zero" && return
    rm -f "$RK/parallelism.conf"
    st="$(cf_stub "1:8000 2:4000 4:2000 8:1950")"; : > "$st/noseg"
    cf_run "$SK" "$RK" "$st" --jobs-list "1 2 4 8" --repeat 3 --warmup 0
    ck "g-cal/record/exit-zero" "0" "$CF_RC"
    ck "g-cal/record/no-contract-shape" "0" "$(contract_count "$CF_OUT$CF_ERR")"
    if [ ! -e "$RK/parallelism.conf" ]; then fail "g-cal/record/written" "no record in the pinned RUN_ALL_CACHE_DIR"; return; fi
    pass "g-cal/record/written"
    ck "g-cal/record/v2-seven-keys" "$V2_KEYS" "$(conf_keys "$RK")"
    schema_want="$(bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${RUN_ALL_CACHE_SCHEMA:-}"' _ "$CF_LIB_PAR" 2>/dev/null)"
    ck "g-cal/record/schema-is-lib-ssot" "$schema_want" "$(conf_value "$RK" schema)"
    ck "g-cal/record/schema-is-2" "2" "$(conf_value "$RK" schema)"
    ck "g-cal/record/max-jobs-per-host-is-knee" "4" "$(conf_value "$RK" max_jobs_per_host)"
    ck "g-cal/record/agrees-with-final-line" "$(cf_selected)" "$(conf_value "$RK" max_jobs_per_host)"
    os_want="$(lib_eval run_all_os_attr)"
    if [ -n "$os_want" ]; then ck "g-cal/record/os-is-current-attr" "$os_want" "$(conf_value "$RK" os)"
    else fail "g-cal/record/os-is-current-attr" "run_all_os_attr is unavailable in $CF_LIB_PAR"; fi
    v="$(conf_value "$RK" measured_at)"
    if [ -n "$v" ] && [ "${#v}" -le 24 ] && case "$v" in *[!0-9TZ:+-]*) false ;; *) true ;; esac; then
        pass "g-cal/record/measured-at-charset"
    else fail "g-cal/record/measured-at-charset" "measured_at=$(printf '%q' "$v")"; fi
    v="$(conf_value "$RK" host_id)"
    if [ -n "$v" ] && [ "${#v}" -le 200 ] && case "$v" in *[!A-Za-z0-9._\|-]*) false ;; *) true ;; esac; then
        pass "g-cal/record/host-id-charset"
    else fail "g-cal/record/host-id-charset" "host_id fails the reader's char class"; fi
    if lib_eval run_all_cache_read "$RK/parallelism.conf" >/dev/null; then pass "g-cal/record/reader-accepts"
    else fail "g-cal/record/reader-accepts" "run_all_cache_read rejected the published record"; fi
    before="$(cat "$RK/parallelism.conf")"
    CF_NO_OPTIN=1 cf_run "$SK" "$RK" - --print
    after="$(cat "$RK/parallelism.conf")"
    ck "g-cal/record/print-exit-zero" "0" "$CF_RC"
    if printf '%s\n' "$CF_OUT" | grep -qx 'max_jobs_per_host=4'; then pass "g-cal/record/print-shows-max-jobs-per-host"
    else fail "g-cal/record/print-shows-max-jobs-per-host" "--print: $(printf '%s' "$CF_OUT" | tr '\n' ' ')"; fi
    if [ -n "$os_want" ] && printf '%s\n' "$CF_OUT" | grep -qxF "os=$os_want"; then pass "g-cal/record/print-shows-os"
    else fail "g-cal/record/print-shows-os" "--print lacks os=$os_want"; fi
    ck "g-cal/record/print-leaves-record-byte-identical" "$before" "$after"
}

# 7. The developer's real cache dir was never touched
case_real_home_untouched() {
    local now=0; [ -e "$REAL_RUN_ALL" ] && now=1
    ck "g-cal/isolation/real-home-run-all-untouched" "$REAL_PRE" "$now"
}

case_unreachable
case_inquiry
case_opt_in
case_knee_curves
case_protocol
record_published
case_real_home_untouched

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
