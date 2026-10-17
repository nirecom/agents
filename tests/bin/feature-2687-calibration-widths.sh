#!/usr/bin/env bash
# tests/bin/feature-2687-calibration-widths.sh
# Tests: bin/calibrate-test-parallelism.sh, bin/calibrate-test-parallelism/sample.sh, bin/calibrate-test-parallelism/aggregate.sh, bin/lib/run-all-parallelism.sh
# Tags: TL2, scope:issue-specific, calibrator, parallel, cpu-count
# Serial: each case runs the calibrator end to end against a stub measurer
# #2687 stage 1 + 5: CPU-derived widths (CPU4), narrowing (CPU8), dry-run estimate, schema 3.
# TL3 gap (what this test does NOT catch):
# - real Windows PowerShell counters and real external load during a real calibration run
# - real nproc / getconf / NUMBER_OF_PROCESSORS on each host OS; every count here is a shim
# Mitigation: WORKFLOW_USER_VERIFIED preflight calibration on this host.

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_ROOT/tests/lib/harness.sh"
# shellcheck source=../tests/feature-1832-run-all-parallel/_cal-fixture.sh
. "$AGENTS_ROOT/tests/tests/feature-1832-run-all-parallel/_cal-fixture.sh"
cf_init
# Top-level pins (cf_init pinned the same values inside a function; repeat them here).
export WORKFLOW_STATE_DIR="$CF_T/workflow"
export WORKFLOW_PLANS_DIR="$CF_T/plans"
unset CLAUDE_CODE_SESSION_ID
CF_PATH_PREFIX="$(cf_cpu_shim 20)"

conf_value() { sed -n "s/^$2=//p" "$1/parallelism.conf" 2>/dev/null | head -n 1; }
conf_keys() { sed -n 's/^\([a-z_]*\)=.*/\1/p' "$1/parallelism.conf" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'; }
both() { printf '%s\n%s\n' "$CF_OUT" "$CF_ERR"; }
has() { both | grep -qF -- "$1"; }
ck_has() { if has "$2"; then pass "$1"; else fail "$1" "missing [$2] rc=$CF_RC out=$(printf '%q' "$CF_OUT") err=$(printf '%q' "$CF_ERR")"; fi; }
ck_lacks() { if has "$2"; then fail "$1" "unexpected [$2] err=$(printf '%q' "$CF_ERR")"; else pass "$1"; fi; }

# widths_of <logical-cpu-count> — RUN_ALL_CALIBRATION_WIDTHS from the lib (exit 93: not implemented).
widths_of() {
    bash -c '. "$1" >/dev/null 2>&1
        declare -F run_all_calibration_widths >/dev/null 2>&1 || exit 93
        run_all_calibration_widths "$2" 2>/dev/null; printf "%s" "$RUN_ALL_CALIBRATION_WIDTHS"' _ "$CF_LIB_PAR" "$1"
}

# corpus <n-bin> <n-hooks> <secs> — a fresh suite + real area with ledger durations (SK / RK).
corpus() {
    SK="$(cf_new_suite)"; RK="$(cf_new_real)"
    [ "$1" -gt 0 ] && cf_populate "$SK" "$RK" bin/a "$1" "$3"
    [ "$2" -gt 0 ] && cf_populate "$SK" "$RK" hooks/b "$2" "$3"
    return 0
}

# ── CPU4 the width list derived from the logical CPU count ──────────────────
case_begin "calibration-widths-derived" "bin/lib/run-all-parallelism.sh"
# Table: <logical-cpu-count ("" = unknown)>|<expected widths>|<note>
CPU4_TABLE=(
    "20|4 6 8 12 16 20|"
    "17|4 6 8 12 17|16 is within a quarter of 17, dropped"
    "8|4 6 8|"
    "3|1 2 3|below 4: every width up to the count"
    "1|1|"
    "2|1 2|"
    "4|4|no base width below the count"
    "5|4 5|gap 1 is not below a quarter of 4"
    "64|4 6 8 12 16 24 32 48 64|"
    "|4 6 8 12 16|unknown: the former list"
)
for _row in "${CPU4_TABLE[@]}"; do
    IFS='|' read -r _n _want _note <<< "$_row"
    ck "CPU4 ${_n:-unknown} -> $_want${_note:+ ($_note)}" "$_want" "$(widths_of "$_n")"
done
case_end

case_begin "calibration-widths-dry-run" "bin/calibrate-test-parallelism.sh"
corpus 38 37 6
cf_run "$SK" "$RK" - --dry-run
ck "CPU4 dry-run exits 0" "0" "$CF_RC"
ck_has "CPU4 dry-run with 20 logical CPUs plans the derived widths" "plan: widths 4 6 8 12 16 20;"
EST="$(both | sed -n 's/^plan: estimate_total_s=\([0-9][0-9]*\)$/\1/p' | head -n 1)"
TOT="$(both | sed -n 's/^plan: estimate ~[0-9]*s per ladder pass, ~\([0-9]*\)s in total.*/\1/p' | head -n 1)"
[[ $EST =~ ^[0-9]+$ ]] && pass "DRY1 dry-run prints plan: estimate_total_s=<n> ($EST)" \
    || fail "DRY1 no 'plan: estimate_total_s=<n>' line" "out=$(printf '%q' "$CF_OUT")"
ck "DRY1 no probe needed: estimate_total_s equals the ladder total" "$TOT" "$EST"
# Independent figure: sample 60 x band midpoint 8 s = 480 s; per pass 120+80+60+40+30+24 = 354;
# warmup 1 + repeat 3 -> 1416 s.
ck "DRY1 estimate_total_s matches the fixture's independent total" "1416" "$EST"
ck_has "DRY1 the existing plan text stays" "plan: nothing was measured and nothing was written"
cf_run "$SK" "$RK" - --dry-run --jobs-list "4 32"
ck "CPU4 --jobs-list wider than the 20 logical CPUs exits 2" "2" "$CF_RC"
CF_PATH_PREFIX_SAVE="$CF_PATH_PREFIX"; CF_PATH_PREFIX="$(cf_cpu_shim unknown)"
cf_run "$SK" "$RK" - --dry-run --jobs-list "4 32"
ck "CPU4 logical CPU count unknown: a wide --jobs-list is not refused" "0" "$CF_RC"
CF_PATH_PREFIX="$CF_PATH_PREFIX_SAVE"
corpus 20 20 6
cf_run "$SK" "$RK" - --dry-run
ck_has "DRY1 dry-run narrows by the same rule: 40 candidates -> widths 4 6 8 12" "plan: widths 4 6 8 12;"
EST="$(both | sed -n 's/^plan: estimate_total_s=\([0-9][0-9]*\)$/\1/p' | head -n 1)"
[[ $EST =~ ^[0-9]+$ ]] && pass "DRY1 narrowed dry-run still prints estimate_total_s ($EST)" \
    || fail "DRY1 narrowed dry-run: no estimate_total_s line" "out=$(printf '%q' "$CF_OUT")"
# Independent figure: sample 3 x 12 = 36 x band midpoint 8 s = 288 s; per pass 72+48+36+24 = 180;
# warmup 1 + repeat 3 -> 720 s.
ck "DRY1 narrowed estimate_total_s matches the fixture's independent total" "720" "$EST"
# With a probe: 70 recorded + 10 unrecorded. Required 60 + 15 = 75, shortfall 5, probe targets
# min(8 x 5, 10) = 10 -> ceil(10 / 4) = 3 rounds x deadline (default band 5:10, 10 + 2) s = 36 s;
# 70 >= 60 keeps every width, so the ladder stays 1416 s -> 1452 s.
corpus 35 35 6
for _i in 01 02 03 04 05 06 07 08 09 10; do cf_add "$SK" "bin/u$_i"; done
cf_run "$SK" "$RK" - --dry-run
ck_has "DRY1 probe dry-run plans the probe rounds" "at most 3 rounds (~36s)"
EST="$(both | sed -n 's/^plan: estimate_total_s=\([0-9][0-9]*\)$/\1/p' | head -n 1)"
ck "DRY1 probe estimate_total_s adds the probe rounds to the ladder total" "1452" "$EST"
case_end

# ── CPU8 automatic narrowing ────────────────────────────────────────────────
case_begin "calibration-narrowing" "bin/calibrate-test-parallelism/sample.sh"
corpus 20 20 6
st="$(cf_stub "4:9000 6:6000 8:4500 12:3000")"; : > "$st/noseg"
cf_run "$SK" "$RK" "$st" --repeat 3 --warmup 0
ck "CPU8 40 candidates, 20 CPUs: calibration succeeds after narrowing" "0" "$CF_RC"
ck_has "CPU8 the narrowing line names the reason" "calibrate: widths narrowed from 20 to 12 (candidates)"
ck "CPU8 max_width_measured=12" "12" "$(conf_value "$RK" max_width_measured)"
ck "CPU8 width_limit=candidates" "candidates" "$(conf_value "$RK" width_limit)"
ck "CPU8 no run at a dropped width" "" "$(awk '$3 > 12' "$st/calls.log" 2>/dev/null)"
ck_has "CPU8 knee at the narrowed top: the corpus hint" "the corpus supported widths up to 12"
ck_lacks "CPU8 narrowed knee: no manual --jobs-list advice" "rerun with a wider --jobs-list"
SK40="$SK"; RK40="$RK"

corpus 5 5 6
st="$(cf_stub)"; : > "$st/noseg"
cf_run "$SK" "$RK" "$st" --repeat 3 --warmup 0
ck "CPU8 10 candidates: too-few-candidates even at one width" "0" "$(cf_inconclusive too-few-candidates; echo $?)"
ck_has "CPU8 the inconclusive message says how far it narrowed" "narrowed from 20 to 4"
ck "CPU8 too-few-candidates writes no record" "absent" "$([ -e "$RK/parallelism.conf" ] && echo present || echo absent)"

st="$(cf_stub)"; : > "$st/noseg"; rm -f "$RK40/parallelism.conf"
cf_run "$SK40" "$RK40" "$st" --repeat 3 --warmup 0 --jobs-list "4 6 8 12 16 20"
ck "CPU8 explicit --jobs-list is never narrowed: too-few-candidates" "0" "$(cf_inconclusive too-few-candidates; echo $?)"
ck_lacks "CPU8 explicit --jobs-list: no narrowing line" "narrowed"

# 75 x 30 s, one pass: widths to 20 estimate 1329 s, to 16 990 s, to 12 675 s against 900 s.
# The estimate binds; the stub's real wall time (4 calls) stays far below the limit.
corpus 38 37 30
st="$(cf_stub)"; : > "$st/noseg"
CF_TIMEOUT=300 cf_run "$SK" "$RK" "$st" --band 1:40 --time-limit 15 --repeat 1 --warmup 0
ck "CPU8 time limit 15 min: succeeds after narrowing" "0" "$CF_RC"
ck_has "CPU8 the time limit narrows 20 -> 12" "calibrate: widths narrowed from 20 to 12 (time-limit)"
ck "CPU8 time limit: max_width_measured=12" "12" "$(conf_value "$RK" max_width_measured)"
ck "CPU8 time limit: width_limit=time-limit" "time-limit" "$(conf_value "$RK" width_limit)"
ck "CPU8 time limit: no run at a dropped width" "" "$(awk '$3 > 12' "$st/calls.log" 2>/dev/null)"

# Sample-dominated: candidate 0 (bin/a01, 40 s) is always in the sample (j = 0), the other 60
# are 12 s. Sum = 40 + (3W-1)*12 vs 40*W: width 8 gives 316 < 320, width 6 gives 244 >= 240.
# 61 candidates satisfy the candidate rule at 20, so only the sample rule narrows 20 -> 6.
SK="$(cf_new_suite)"; RK="$(cf_new_real)"
cf_populate "$SK" "$RK" bin/a 1 40
cf_populate "$SK" "$RK" hooks/b 60 12
st="$(cf_stub)"; : > "$st/noseg"
CF_TIMEOUT=300 cf_run "$SK" "$RK" "$st" --band 1:40 --time-limit 120 --repeat 1 --warmup 0
ck "CPU8 one dominant test: succeeds after narrowing" "0" "$CF_RC"
ck_has "CPU8 the sample rule narrows 20 -> 6" "calibrate: widths narrowed from 20 to 6 (sample)"
ck "CPU8 sample: max_width_measured=6" "6" "$(conf_value "$RK" max_width_measured)"
ck "CPU8 sample: width_limit=sample" "sample" "$(conf_value "$RK" width_limit)"
ck "CPU8 sample: the record's sample_size is recomputed (3 x 6)" "18" "$(conf_value "$RK" sample_size)"
ck "CPU8 sample: no run at a dropped width" "" "$(awk '$3 > 6' "$st/calls.log" 2>/dev/null)"
ck "CPU8 sample: one measured run per narrowed width (4 6)" "2" "$(cf_calls "$st")"
ck "CPU8 sample: every measured run gets the recomputed 18-test sample" "" \
    "$(awk '$6 != 18' "$st/calls.log" 2>/dev/null)"
case_end

# ── PUB schema 3 publish ────────────────────────────────────────────────────
case_begin "calibration-publish-schema3" "bin/calibrate-test-parallelism/aggregate.sh"
KEYS10="host_id logical_cpu_count max_jobs_per_host max_width_measured measured_at os repeat sample_size schema width_limit"
corpus 38 37 6
st="$(cf_stub "4:20000 6:14000 8:10000 12:7000 16:5000 20:3000")"; : > "$st/noseg"
cf_run "$SK" "$RK" "$st" --repeat 3 --warmup 0
ck "PUB 75 candidates: calibration exits 0" "0" "$CF_RC"
ck "PUB schema=3" "3" "$(conf_value "$RK" schema)"
ck "PUB exactly the ten schema-3 keys" "$KEYS10" "$(conf_keys "$RK")"
ck "PUB logical_cpu_count=20" "20" "$(conf_value "$RK" logical_cpu_count)"
ck "PUB max_jobs_per_host is the knee as selected" "$(cf_selected)" "$(conf_value "$RK" max_jobs_per_host)"
ck "PUB not narrowed: max_width_measured=20" "20" "$(conf_value "$RK" max_width_measured)"
ck "PUB width_limit=logical-cpu-count" "logical-cpu-count" "$(conf_value "$RK" width_limit)"
ck_lacks "PUB no narrowing line when the corpus fills the widest width" "widths narrowed"
ck_has "PUB knee at the logical CPU count: the ceiling note" "the knee reached the logical CPU count"
ck_lacks "PUB knee at the ceiling: no rerun advice" "rerun with a wider --jobs-list"

rm -f "$RK40/parallelism.conf"
st="$(cf_stub "4:9000 6:6000 8:3000")"; : > "$st/noseg"
cf_run "$SK40" "$RK40" "$st" --repeat 3 --warmup 0 --jobs-list "4 6 8"
ck "PUB explicit --jobs-list: exits 0" "0" "$CF_RC"
ck "PUB explicit --jobs-list: width_limit=jobs-list" "jobs-list" "$(conf_value "$RK40" width_limit)"
ck "PUB explicit --jobs-list: max_width_measured=8" "8" "$(conf_value "$RK40" max_width_measured)"
ck_has "PUB knee at an explicit top: the rerun advice stays" "rerun with a wider --jobs-list"
case_end

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
