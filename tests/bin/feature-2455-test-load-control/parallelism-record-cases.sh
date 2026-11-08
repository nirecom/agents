#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/parallelism-record-cases.sh — CPU5, CPU7 (#2687 ①).
# The schema-3 parallelism record and the recalibrate advice derived from it. Split from
# cpu-ceiling-cases.sh so the two halves run as separate run-all entries.
# Relies on _lanes-fixture.sh and _cpu-fixture.sh.

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

grp_done parallelism-record-cases.sh
