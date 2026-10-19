#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/cpu-ceiling-cases.sh — CPU1-CPU3, CPU5, CPU7 (#2687 ①).
# The logical CPU count lookup, the static ceiling it puts on max jobs per host, the schema-3
# parallelism record and the recalibrate advice derived from it. CPU6 (the knee written as is)
# runs through the calibrator fixture in tests/tests/feature-1832-run-all-parallel/g-calibrator.sh.
# Relies on lanes-cases.sh (sourced earlier) for L12_HID, L_OS_NOW and dotenv_stub.

# shellcheck source=../../lib/tool-shim-path.sh
. "$AGENTS_ROOT/tests/lib/tool-shim-path.sh"

CC_HINT="RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh"
CC_OFF=AUTO_CONFIG_TEST_MAX_JOBS=off
CC_CPU='run_all_logical_cpu_count; echo "rc=$?"; echo "n=${RUN_ALL_LOGICAL_CPU_COUNT-unset}"'
CC_MAX='thl_max_jobs_per_host; echo "b=${THL_MAX_JOBS_PER_HOST-}/${THL_MAX_JOBS_PER_HOST_SOURCE-}"; echo "cap=${THL_CAP_NOTE-}"'
CC_PLAN='thl_plan 2; echo "note=${THL_NOTE-}"'
CC_LEASE='thl_init_dir; thl_run_all_lease 2 0; echo "rc=$?"; echo "note=${THL_NOTE-}"; thl_release_all'
CC_READ='run_all_cache_read "$RUN_ALL_CACHE_DIR/parallelism.conf"; echo "rc=$?"; echo "r=${RUN_ALL_CACHE_REASON-}"; echo "m=${RUN_ALL_CACHE_MAX_JOBS_PER_HOST-}"; echo "lc=${RUN_ALL_CACHE_LOGICAL_CPU_COUNT-}"; echo "mw=${RUN_ALL_CACHE_MAX_WIDTH_MEASURED-}"; echo "wl=${RUN_ALL_CACHE_WIDTH_LIMIT-}"; echo "lg=${RUN_ALL_CACHE_IS_LEGACY-}"'

# cc_cpu <n> — echoes a PATH dir whose nproc prints <n> (one dir per value, built once).
cc_cpu() {
    local d="$TMPDIR_BASE/cc-cpu-$1"
    [ -x "$d/nproc" ] || cpu_shim "$d" "$1"
    printf '%s' "$d"
}
# A PATH with no nproc and no getconf (sysctl is never in the base); NUMBER_OF_PROCESSORS=
# (empty, so invalid) is passed with it to close the last source.
CC_BARE="$(tsp_base_path "$TMPDIR_BASE/cc-bare" nproc getconf)" || CC_BARE=""
[ -n "$CC_BARE" ] && pass "CPU precondition: a PATH without nproc/getconf builds" || fail "CPU precondition: tsp_base_path failed"
CC_UNKNOWN=("PATH=$CC_BARE" "NUMBER_OF_PROCESSORS=")

# cc_rec <cache> [key=val | -key | +key=val]... — a parallelism.conf for this host. Defaults are a
# well-formed schema-3 record measured at 1024 CPUs up to that ceiling; key=val replaces a line,
# -key drops it, +key=val appends one.
cc_rec() {
    local cache="$1" a k i; shift
    local -a lines=("schema=3" "host_id=$L12_HID" "os=$L_OS_NOW" "max_jobs_per_host=5" \
        "measured_at=2026-01-01T00:00:00Z" "sample_size=3" "repeat=1" "logical_cpu_count=1024" \
        "max_width_measured=1024" "width_limit=logical-cpu-count")
    for a in "$@"; do
        case "$a" in
            -*) k="${a#-}"
                for i in "${!lines[@]}"; do [ "${lines[$i]%%=*}" = "$k" ] && unset "lines[$i]"; done ;;
            +*) lines+=("${a#+}") ;;
            *) k="${a%%=*}"
                for i in "${!lines[@]}"; do [ "${lines[$i]%%=*}" = "$k" ] && lines[i]="$a"; done ;;
        esac
    done
    rm -rf "$cache"; mkdir -p "$cache"
    printf '%s\n' "${lines[@]}" > "$cache/parallelism.conf"
}
CC_N=0
cc_dir() { CC_N=$((CC_N + 1)); printf '%s' "$TMPDIR_BASE/cc-$CC_N"; }

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

case_begin "parallelism-record-schema-3" "bin/lib/run-all-parallelism.sh"

# ── CPU5 schema 3: ten keys, per-schema allow list, schema 2 as legacy ──────
# cc_read <label> <want rc/reason> [record args...] — writes the record, reads it back.
cc_read() {
    local label="$1" want="$2" c; shift 2
    c="$(cc_dir)"; cc_rec "$c" "$@"
    lanes_drv "$c" -- "$CC_READ"
    assert_eq "CPU5 $label" "$want" "$(kv_of "$OUT" rc)/$(kv_of "$OUT" r)"
}
_c="$(cc_dir)"; cc_rec "$_c" max_jobs_per_host=12 logical_cpu_count=16 max_width_measured=12 width_limit=candidates
lanes_drv "$_c" -- "$CC_READ"
assert_eq "CPU5 schema 3 round trip: accepted" "0/" "$(kv_of "$OUT" rc)/$(kv_of "$OUT" r)"
assert_eq "CPU5 schema 3 round trip: the four new outputs" "12 16 12 candidates 0" \
    "$(kv_of "$OUT" m) $(kv_of "$OUT" lc) $(kv_of "$OUT" mw) $(kv_of "$OUT" wl) $(_lg="$(kv_of "$OUT" lg)"; printf '%s' "${_lg:-0}")"
for _k in logical_cpu_count max_width_measured width_limit; do
    cc_read "schema 3 without $_k: malformed" "1/malformed" "-$_k"
done
cc_read "logical_cpu_count=0 (unknown at measurement) is accepted" "0/" logical_cpu_count=0 width_limit=unknown-cpu-count
for _v in 1025 -1 abc '' ' 8'; do
    cc_read "logical_cpu_count=$(printf '%q' "$_v"): malformed" "1/malformed" "logical_cpu_count=$_v"
done
for _v in 0 1025 abc ''; do
    cc_read "max_width_measured=$(printf '%q' "$_v"): malformed" "1/malformed" "max_width_measured=$_v"
done
for _v in logical-cpu-count candidates sample time-limit jobs-list unknown-cpu-count; do
    cc_read "width_limit=$_v is in the enum" "0/" "width_limit=$_v"
done
CC_PWN5="$TMPDIR_BASE/cc5-pwned"
for _v in bogus Candidates '' "candidates;touch $CC_PWN5" "\$(touch $CC_PWN5)"; do
    cc_read "width_limit=$(printf '%q' "$_v"): malformed" "1/malformed" "width_limit=$_v"
done
[ ! -e "$CC_PWN5" ] && pass "CPU5 a hostile width_limit is never executed" || fail "CPU5 a hostile width_limit was executed"
cc_read "an unknown key: unknown-key" "1/unknown-key" "+future_key=1"
cc_read "a duplicated new key: duplicate-key" "1/duplicate-key" "+width_limit=candidates"
# Schema 2 (the seven keys) is legacy: accepted, flagged, and asks for recalibration.
_c="$(cc_dir)"; cc_rec "$_c" schema=2 -logical_cpu_count -max_width_measured -width_limit
lanes_drv "$_c" -- "$CC_READ"
assert_eq "CPU5 schema 2: accepted as legacy" "0/ 5 1" "$(kv_of "$OUT" rc)/$(kv_of "$OUT" r) $(kv_of "$OUT" m) $(kv_of "$OUT" lg)"
run_status "$_c"
assert_tokens "CPU5 schema 2: status line 1 asks to recalibrate" "max_jobs_per_host=5 source=measured recalibrate=legacy-record" "$(first_line "$OUT")"
cc_read "schema 2 carrying a schema-3 key: unknown-key" "1/unknown-key" schema=2 -max_width_measured -width_limit
for _s in 1 4; do
    cc_read "schema $_s: schema-mismatch" "1/schema-mismatch" "schema=$_s"
done
cc_read "schema 1 with the seven keys: schema-mismatch" "1/schema-mismatch" schema=1 -logical_cpu_count -max_width_measured -width_limit
case_ran CPU5

case_end

case_begin "recalibrate-advice" "bin/lib/test-host-lanes.sh"

# ── CPU7 recalibrate advice from the record ─────────────────────────────────
# cc_advice <label> <cpu> <want-token|-> <record args...> — status token, then the lanes note.
cc_advice() {
    local label="$1" cpu="$2" tok="$3" c note; shift 3
    c="$(cc_dir)"; cc_rec "$c" "$@"
    run_status "$c" "PATH=$(cc_cpu "$cpu"):$PATH"
    if [ "$tok" = - ]; then
        assert_tokens "CPU7 $label: no recalibrate token" "max_jobs_per_host=$CC_WANT_N source=measured" "$(first_line "$OUT")" recalibrate
    else
        assert_tokens "CPU7 $label: status line 1" "max_jobs_per_host=$CC_WANT_N source=measured recalibrate=$tok" "$(first_line "$OUT")"
    fi
    lanes_drv "$c" "PATH=$(cc_cpu "$cpu"):$PATH" -- "$CC_LEASE"
    CC_NOTE="$(kv_of "$OUT" note)"
    note="$CC_NOTE"
    if [ "$tok" = - ]; then
        case "$note" in
            *re-run*|*"wider"*|*"calibrate with"*|"") fail "CPU7 $label: the lanes note asks for a rerun — note=$(printf '%q' "$note")" ;;
            *) pass "CPU7 $label: the lanes note asks nothing" ;;
        esac
    else
        case "$note" in
            *"re-run $CC_HINT"*) pass "CPU7 $label: the lanes note carries the re-run hint" ;;
            *) fail "CPU7 $label: the lanes note lacks the re-run hint — note=$(printf '%q' "$note")" ;;
        esac
    fi
}
CC_WANT_N=16
cc_advice "jobs-list knee 16 = widest 16 < 20 CPUs: ladder-truncated" 20 ladder-truncated \
    max_jobs_per_host=16 logical_cpu_count=20 max_width_measured=16 width_limit=jobs-list
CC_WANT_N=12
cc_advice "recorded at 16 CPUs, now 20: cpu-count-changed" 20 cpu-count-changed \
    max_jobs_per_host=12 logical_cpu_count=16 max_width_measured=16 width_limit=logical-cpu-count
CC_WANT_N=20
cc_advice "knee = widest = CPU count 20: no advice" 20 - \
    max_jobs_per_host=20 logical_cpu_count=20 max_width_measured=20 width_limit=logical-cpu-count
CC_WANT_N=8
cc_advice "jobs-list knee 8 below the widest 16: not truncated" 20 - \
    max_jobs_per_host=8 logical_cpu_count=20 max_width_measured=16 width_limit=jobs-list
CC_WANT_N=12
cc_advice "candidates knee = widest 12 < 20 CPUs: note only, no ask" 20 - \
    max_jobs_per_host=12 logical_cpu_count=20 max_width_measured=12 width_limit=candidates
case "$CC_NOTE" in
    *"measured up to 12"*) pass "CPU7 candidates: the lanes note says 'measured up to 12'" ;;
    *) fail "CPU7 candidates: the lanes note lacks 'measured up to 12' — note=$(printf '%q' "$CC_NOTE")" ;;
esac
for _wl in sample time-limit; do
    cc_advice "$_wl knee = widest 12: note only" 20 - \
        max_jobs_per_host=12 logical_cpu_count=20 max_width_measured=12 "width_limit=$_wl"
    case "$CC_NOTE" in *"measured up to 12"*) pass "CPU7 $_wl: 'measured up to 12'" ;; *) fail "CPU7 $_wl: no 'measured up to 12' — note=$(printf '%q' "$CC_NOTE")" ;; esac
done
CC_WANT_N=5
cc_advice "legacy schema-2 record: legacy-record" 1024 legacy-record \
    schema=2 -logical_cpu_count -max_width_measured -width_limit
# Under off the record is never read, so it can raise no advice.
_c="$(cc_dir)"; cc_rec "$_c" schema=2 -logical_cpu_count -max_width_measured -width_limit
run_status "$_c" "$CC_OFF"
assert_tokens "CPU7 off: a legacy record raises no advice" "max_jobs_per_host=4 source=default mode=off" "$(first_line "$OUT")" recalibrate measured_on
case_ran CPU7

case_end

grp_done cpu-ceiling-cases.sh
