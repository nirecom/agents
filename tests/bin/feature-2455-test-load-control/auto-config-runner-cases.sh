#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/auto-config-runner-cases.sh — AC7 (#2687 ②).
# Lanes not applied plus an unlimited max jobs per run: the runner bounds -j by the lane
# pool. Split from auto-config-cases.sh because it needs the runner fixture.
# Relies on _runner-fixture.sh (r_reset, r_root, R_OUT, R_ERR, fx_exec, fx_peak_of, fx_peak_log).

case_begin "auto-config-runner" "tests/run-all.sh"

# ── AC7 lanes not applied + max jobs per run unlimited -> the lane pool ─────
AC7W="$(r_root 6 --peak --sleep 1)"
AC7_NOTE="(max jobs per run unlimited, bounded by the run-all lane pool)"
# ac7_plan <label> -- <runner args...> — --print-plan with H=3 and no TEST_MAX_JOBS_PER_RUN.
ac7_plan() {
    local label="$1" want="$2"; shift 2
    fx_exec "$AC7W" 60 "$R_OUT" "$R_ERR" --print-plan "$@" --all; _rc=$?
    assert_eq "AC7 $label: --print-plan exits 0" "0" "$_rc"
    assert_eq "AC7 $label: jobs=$want" "jobs=$want" "$(grep '^jobs=' "$R_OUT")"
}
for _mode in on off; do
    r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES=off; AUTO_CONFIG_TEST_MAX_JOBS="$_mode"
    ac7_plan "TEST_LANES=off, $_mode" 2
    grep -qF -- "jobs 2 $AC7_NOTE" "$R_ERR" && pass "AC7 TEST_LANES=off, $_mode: the plan says 'jobs 2 $AC7_NOTE'" \
        || fail "AC7 TEST_LANES=off, $_mode: the bounded note is missing — err=$(printf '%q' "$(cat "$R_ERR")")"
    grep -qF -- "max jobs per run: unlimited (default)" "$R_ERR" && pass "AC7 $_mode: max jobs per run is unlimited (default)" \
        || fail "AC7 $_mode: no 'max jobs per run: unlimited (default)' — err=$(printf '%q' "$(cat "$R_ERR")")"
done
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_HELD=123
ac7_plan "nested holder" 2
grep -qF -- "jobs 2 $AC7_NOTE" "$R_ERR" && pass "AC7 nested: the plan says 'jobs 2 $AC7_NOTE'" \
    || fail "AC7 nested: the bounded note is missing — err=$(printf '%q' "$(cat "$R_ERR")")"
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES=off
ac7_plan "explicit -j 5 stays 5" 5 -j 5
grep -qF -- "not applied (TEST_LANES=off); jobs 5 as requested" "$R_ERR" && pass "AC7 explicit -j 5: 'jobs 5 as requested'" \
    || fail "AC7 explicit -j 5: note — err=$(printf '%q' "$(cat "$R_ERR")")"
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES=off
fx_exec "$AC7W" 120 "$R_OUT" "$R_ERR" --all; _rc=$?
assert_eq "AC7 TEST_LANES=off run exits 0" "0" "$_rc"
_pk="$(fx_peak_of "$(fx_peak_log "$AC7W")")"
[[ "$_pk" =~ ^[12]$ ]] && pass "AC7 TEST_LANES=off run: peak $_pk <= the lane pool 2" || fail "AC7 TEST_LANES=off run: peak [$_pk] over the lane pool 2"
r_reset
case_ran AC7

case_end

grp_done auto-config-runner-cases.sh
