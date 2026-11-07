#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/cpu-ceiling-cases.sh — CPU1-CPU3 (#2687 ①).
# The logical CPU count lookup and the static ceiling it puts on max jobs per host.
# CPU5/CPU7 (the schema-3 record and its advice) live in parallelism-record-cases.sh; CPU6
# (the knee written as is) runs through the calibrator fixture in
# tests/tests/feature-1832-run-all-parallel/g-calibrator.sh.
# Relies on _lanes-fixture.sh (dotenv_stub) and _cpu-fixture.sh (cc_* helpers).

case_begin "logical-cpu-count" "bin/lib/run-all-parallelism.sh"

# ── CPU1 lookup order nproc > getconf > sysctl > NUMBER_OF_PROCESSORS ───────
CC_E="$TMPDIR_BASE/cc-empty"; mkdir -p "$CC_E"
lanes_drv "$CC_E" "PATH=$(cc_cpu 8):$PATH" -- "$CC_CPU"
assert_eq "CPU1 nproc 8 -> RUN_ALL_LOGICAL_CPU_COUNT=8" "8" "$(kv_of "$OUT" n)"
CC_GC="$TMPDIR_BASE/cc-getconf"; mkdir -p "$CC_GC"
printf '#!%s\n[ "$1" = _NPROCESSORS_ONLN ] && { echo 6; exit 0; }\nexit 1\n' "$(type -P bash)" > "$CC_GC/getconf"
chmod +x "$CC_GC/getconf"
lanes_drv "$CC_E" "PATH=$CC_GC:$CC_BARE" "NUMBER_OF_PROCESSORS=12" -- "$CC_CPU"
assert_eq "CPU1 no nproc: getconf _NPROCESSORS_ONLN 6 is used before NUMBER_OF_PROCESSORS" "6" "$(kv_of "$OUT" n)"
lanes_drv "$CC_E" "PATH=$CC_BARE" "NUMBER_OF_PROCESSORS=12" -- "$CC_CPU"
assert_eq "CPU1 no nproc/getconf: NUMBER_OF_PROCESSORS=12 is the last fallback" "12" "$(kv_of "$OUT" n)"
lanes_drv "$CC_E" "${CC_UNKNOWN[@]}" -- "$CC_CPU"
assert_eq "CPU1 every source absent: the count is empty (unknown)" "" "$(kv_of "$OUT" n)"
no_shell_error "$ERR" && pass "CPU1 every source absent: no shell error" || fail "CPU1 every source absent: stderr=$(printf '%q' "$ERR")"
# Out-of-range and hostile answers are skipped, never evaluated: the next source decides.
CC_PWN="$TMPDIR_BASE/cc-pwned"
for _v in 0 1025 2000 -3 abc '8 8' "\$(touch $CC_PWN)" "\`touch $CC_PWN\`"; do
    _d="$TMPDIR_BASE/cc-bad-$CC_N"; CC_N=$((CC_N + 1)); cpu_shim "$_d" "$_v"
    lanes_drv "$CC_E" "PATH=$_d:$CC_BARE" "NUMBER_OF_PROCESSORS=3" -- "$CC_CPU"
    assert_eq "CPU1 nproc answer $(printf '%q' "$_v") is skipped: NUMBER_OF_PROCESSORS 3 decides" "3" "$(kv_of "$OUT" n)"
done
lanes_drv "$CC_E" "PATH=$(cc_cpu 1024):$PATH" -- "$CC_CPU"
assert_eq "CPU1 boundary: nproc 1024 is accepted" "1024" "$(kv_of "$OUT" n)"
lanes_drv "$CC_E" "PATH=$(cc_cpu 1):$PATH" -- "$CC_CPU"
assert_eq "CPU1 boundary: nproc 1 is accepted" "1" "$(kv_of "$OUT" n)"
[ ! -e "$CC_PWN" ] && pass "CPU1 a hostile nproc answer is never executed" || fail "CPU1 a hostile nproc answer was executed"
case_ran CPU1

case_end

case_begin "logical-cpu-ceiling" "bin/lib/test-host-lanes.sh"

# ── CPU2 max jobs per host is capped at the logical CPU count ───────────────
_c="$(cc_dir)"; cc_rec "$_c" max_jobs_per_host=16 logical_cpu_count=16 max_width_measured=16
lanes_drv "$_c" "PATH=$(cc_cpu 8):$PATH" -- "$CC_MAX"
assert_eq "CPU2 measured 16 at 8 CPUs: capped to 8, source stays measured" "8/measured" "$(kv_of "$OUT" b)"
assert_eq "CPU2 measured 16 at 8 CPUs: THL_CAP_NOTE" "capped at logical CPU count 8" "$(kv_of "$OUT" cap)"
lanes_drv "$_c" "PATH=$(cc_cpu 8):$PATH" -- "$CC_PLAN"
case "$(kv_of "$OUT" note)" in
    "jobs 2 of requested 2 (max jobs per host 8, source measured"*"capped at logical CPU count 8"*) pass "CPU2 the plan note carries the cap" ;;
    *) fail "CPU2 the plan note lacks the cap — note=$(printf '%q' "$(kv_of "$OUT" note)")" ;;
esac
lanes_drv "$_c" "PATH=$(cc_cpu 8):$PATH" -- "$CC_LEASE"
case "$(kv_of "$OUT" note)" in
    *"capped at logical CPU count 8"*) pass "CPU2 the lanes note carries the cap" ;;
    *) fail "CPU2 the lanes note lacks the cap — note=$(printf '%q' "$(kv_of "$OUT" note)")" ;;
esac
run_status "$_c" "PATH=$(cc_cpu 8):$PATH"
assert_tokens "CPU2 status line 1 names the cap" "max_jobs_per_host=8 source=measured capped=logical-cpu-count" "$(first_line "$OUT")" logical_cpus
# A pin is capped in both modes; on mode takes min(pin, base) first.
_e="$(cc_dir)"; mkdir -p "$_e"
lanes_drv "$_e" "PATH=$(cc_cpu 20):$PATH" "$CC_OFF" TEST_MAX_JOBS_PER_HOST=32 -- "$CC_MAX"
assert_eq "CPU2 off: env pin 32 at 20 CPUs -> 20/env" "20/env" "$(kv_of "$OUT" b)"
assert_eq "CPU2 off: env pin 32 at 20 CPUs: THL_CAP_NOTE" "capped at logical CPU count 20" "$(kv_of "$OUT" cap)"
_c="$(cc_dir)"; cc_rec "$_c" max_jobs_per_host=40 logical_cpu_count=40 max_width_measured=40
lanes_drv "$_c" "PATH=$(cc_cpu 20):$PATH" AUTO_CONFIG_TEST_MAX_JOBS=on TEST_MAX_JOBS_PER_HOST=32 -- "$CC_MAX"
assert_eq "CPU2 on: min(pin 32, record 40) = 32 at 20 CPUs -> 20/env" "20/env" "$(kv_of "$OUT" b)"
assert_eq "CPU2 on: THL_CAP_NOTE" "capped at logical CPU count 20" "$(kv_of "$OUT" cap)"
dotenv_stub TEST_MAX_JOBS_PER_HOST 32
lanes_drv "$_e" "PATH=$(cc_cpu 20):$PATH" "$CC_OFF" "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB" -- "$CC_MAX"
assert_eq "CPU2 off: .env pin 32 at 20 CPUs -> 20/dotenv" "20/dotenv" "$(kv_of "$OUT" b)"
lanes_drv "$_e" "PATH=$(cc_cpu 20):$PATH" "$CC_OFF" TEST_MAX_JOBS_PER_HOST=7 -- "$CC_MAX"
assert_eq "CPU2 pin 7 at 20 CPUs stays 7 (never rounded)" "7/env" "$(kv_of "$OUT" b)"
assert_eq "CPU2 pin 7 at 20 CPUs: no cap note" "" "$(kv_of "$OUT" cap)"
for _p in 8 1024; do
    lanes_drv "$_e" "PATH=$(cc_cpu "$_p"):$PATH" "$CC_OFF" "TEST_MAX_JOBS_PER_HOST=$_p" -- "$CC_MAX"
    assert_eq "CPU2 pin $_p at $_p CPUs: equal is not over the ceiling" "$_p/env/" "$(kv_of "$OUT" b)/$(kv_of "$OUT" cap)"
done
run_status "$_e" "PATH=$(cc_cpu 20):$PATH" "$CC_OFF" TEST_MAX_JOBS_PER_HOST=7
assert_tokens "CPU2 pin under the ceiling: status line 1 has no cap token" "max_jobs_per_host=7 source=env mode=off" "$(first_line "$OUT")" capped logical_cpus
case_ran CPU2

# ── CPU3 unknown logical CPU count: not capped, said so ─────────────────────
lanes_drv "$_e" "${CC_UNKNOWN[@]}" "$CC_OFF" TEST_MAX_JOBS_PER_HOST=32 -- "$CC_MAX"
assert_eq "CPU3 unknown count: pin 32 is not capped" "32/env" "$(kv_of "$OUT" b)"
assert_eq "CPU3 unknown count: THL_CAP_NOTE" "logical CPU count unknown; not capped" "$(kv_of "$OUT" cap)"
lanes_drv "$_e" "${CC_UNKNOWN[@]}" "$CC_OFF" TEST_MAX_JOBS_PER_HOST=32 -- "$CC_PLAN"
case "$(kv_of "$OUT" note)" in
    *"logical CPU count unknown; not capped"*) pass "CPU3 the plan note says the count is unknown" ;;
    *) fail "CPU3 the plan note lacks the unknown-count phrase — note=$(printf '%q' "$(kv_of "$OUT" note)")" ;;
esac
run_status "$_e" "${CC_UNKNOWN[@]}" "$CC_OFF" TEST_MAX_JOBS_PER_HOST=32
assert_tokens "CPU3 status line 1 carries logical_cpus=unknown" "max_jobs_per_host=32 source=env logical_cpus=unknown" "$(first_line "$OUT")" capped
case_ran CPU3

case_end

grp_done cpu-ceiling-cases.sh
