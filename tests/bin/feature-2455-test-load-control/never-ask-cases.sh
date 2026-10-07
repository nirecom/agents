#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/never-ask-cases.sh — NA1-NA5 (#2079).
# The never-ask record (calibration-never-ask.conf in RUN_ALL_CACHE_DIR) drops only the
# unsolicited calibrator command from the plan/lanes notes; source and record facts stay.
# Relies on lanes-cases.sh (sourced earlier) for L12_HID, L_OS_NOW, l12_conf, first_line.

case_begin "never-ask-suppression" "bin/lib/test-host-lanes.sh"

NA_HINT="RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh"
NA_PLAN='thl_plan 2; echo "note=${THL_NOTE-}"'
NA_LEASE='thl_init_dir; thl_run_all_lease 2 0; echo "rc=$?"; echo "note=${THL_NOTE-}"; thl_release_all'
# na_rec <cache> <host_id> — a well-formed never-ask record (the shape run_all_never_ask_write emits).
na_rec() {
    mkdir -p "$1"
    printf 'schema=1\nhost_id=%s\nrecorded_at=2026-01-01T00:00:00Z\n' "$2" > "$1/calibration-never-ask.conf"
}
if [[ -n "$L12_HID" ]]; then pass "NA precondition: run_all_host_id yields a host id"; else fail "NA precondition: run_all_host_id is empty"; fi

# ── NA1 default source, record for this host: no calibrator command ─────────
NA1C="$TMPDIR_BASE/na1-cache"
na_rec "$NA1C" "$L12_HID"
lanes_drv "$NA1C" -- "$NA_PLAN"
assert_eq "NA1 plan note under never-ask keeps source and record, drops the command" \
    "jobs 2 of requested 2 (max jobs per host 4, source default, record missing; a live lease may grant fewer)" \
    "$(kv_of "$OUT" note)"
lanes_drv "$NA1C" -- "$NA_LEASE"
_note="$(kv_of "$OUT" note)"
assert_eq "NA1 lease under never-ask succeeds" "0" "$(kv_of "$OUT" rc)"
case "$_note" in
    *"calibrate with"*|*"calibrate-test-parallelism"*) fail "NA1 lanes note still names the calibrator — note=$(printf '%q' "$_note")" ;;
    "jobs 2 of requested 2 (max jobs per host 4, source default, record missing; lanes "*")") pass "NA1 lanes note keeps source/record and drops the command" ;;
    *) fail "NA1 unexpected lanes note — note=$(printf '%q' "$_note")" ;;
esac
case_ran NA1

# ── NA2 default source, record for another host: the command stays ──────────
NA2C="$TMPDIR_BASE/na2-cache"
na_rec "$NA2C" "Other|x86_64|not-this-host"
lanes_drv "$NA2C" -- "$NA_PLAN"
assert_eq "NA2 a record for another host_id suppresses nothing" \
    "jobs 2 of requested 2 (max jobs per host 4, source default, record missing; calibrate with $NA_HINT; a live lease may grant fewer)" \
    "$(kv_of "$OUT" note)"
case_ran NA2

# ── NA3 OS-mismatched record, never-ask for this host: advice without re-run ─
NA3C="$TMPDIR_BASE/na3-cache"
NA3_OLD="${L_OS_NOW%%/*}"; NA3_OLD="${NA3_OLD:-Unknown}/0.0.0-na3"
l12_conf "$NA3C" 5 "$NA3_OLD"
na_rec "$NA3C" "$L12_HID"
lanes_drv "$NA3C" -- "$NA_PLAN"
assert_eq "NA3 os differs under never-ask: the fact stays, the re-run command goes" \
    "jobs 2 of requested 2 (max jobs per host 5, source measured; a live lease may grant fewer); measured on $NA3_OLD, now $L_OS_NOW" \
    "$(kv_of "$OUT" note)"
lanes_drv "$NA3C" -- "$NA_LEASE"
_note="$(kv_of "$OUT" note)"
case "$_note" in
    *"re-run"*) fail "NA3 lanes note still carries re-run — note=$(printf '%q' "$_note")" ;;
    *"; measured on $NA3_OLD, now $L_OS_NOW") pass "NA3 lanes note ends with the OS fact only" ;;
    *) fail "NA3 lanes note lacks the OS fact — note=$(printf '%q' "$_note")" ;;
esac
case_ran NA3

# ── NA4 status line 1 is identical with and without the record ──────────────
NA4A="$TMPDIR_BASE/na4-none"; mkdir -p "$NA4A"
NA4B="$TMPDIR_BASE/na4-rec"; na_rec "$NA4B" "$L12_HID"
run_status "$NA4A"; _l_without="$(first_line "$OUT")"
run_status "$NA4B"; _l_with="$(first_line "$OUT")"
assert_eq "NA4 default: status line 1 without a record" "max_jobs_per_host=4 source=default record=missing" "$_l_without"
assert_eq "NA4 default: status line 1 unchanged by never-ask" "$_l_without" "$_l_with"
run_status "$NA3C"
assert_eq "NA4 os differs: status line 1 still names both versions under never-ask" \
    "max_jobs_per_host=5 source=measured measured_on=$NA3_OLD now=$L_OS_NOW" "$(first_line "$OUT")"
case_ran NA4

case_end

case_begin "never-ask-record-validity" "bin/lib/run-all-parallelism.sh"

# ── NA5 run_all_never_ask_active: only a well-formed record for this host is active ─
# na_active <cache> → "0" or "1" (exit status of the predicate; "lib" when the function is absent).
na_active() {
    lanes_drv "$1" -- 'if ! declare -F run_all_never_ask_active >/dev/null; then echo "st=lib"; else run_all_never_ask_active; echo "st=$?"; fi'
    kv_of "$OUT" st
}
NA5="$TMPDIR_BASE/na5"
na_rec "$NA5/ok" "$L12_HID"
assert_eq "NA5 well-formed record for this host: active" "0" "$(na_active "$NA5/ok")"
mkdir -p "$NA5/absent"
assert_eq "NA5 no record: inactive" "1" "$(na_active "$NA5/absent")"
mkdir -p "$NA5/crlf"; printf 'schema=1\r\nhost_id=%s\r\nrecorded_at=x\r\n' "$L12_HID" > "$NA5/crlf/calibration-never-ask.conf"
assert_eq "NA5 CRLF line endings are tolerated" "0" "$(na_active "$NA5/crlf")"
mkdir -p "$NA5/unknown"; printf 'schema=9\nfuture_key=1\nhost_id=%s\n' "$L12_HID" > "$NA5/unknown/calibration-never-ask.conf"
assert_eq "NA5 unknown keys and schema= are ignored" "0" "$(na_active "$NA5/unknown")"
mkdir -p "$NA5/dup"; printf 'host_id=%s\nhost_id=%s\n' "$L12_HID" "$L12_HID" > "$NA5/dup/calibration-never-ask.conf"
assert_eq "NA5 duplicate host_id lines: inactive" "1" "$(na_active "$NA5/dup")"
mkdir -p "$NA5/empty"; printf 'schema=1\nhost_id=\n' > "$NA5/empty/calibration-never-ask.conf"
assert_eq "NA5 empty host_id: inactive" "1" "$(na_active "$NA5/empty")"
mkdir -p "$NA5/nohost"; printf 'schema=1\nrecorded_at=x\n' > "$NA5/nohost/calibration-never-ask.conf"
assert_eq "NA5 no host_id line: inactive" "1" "$(na_active "$NA5/nohost")"
mkdir -p "$NA5/long-id"; printf 'host_id=%s\n' "$(printf 'h%.0s' $(seq 1 201))" > "$NA5/long-id/calibration-never-ask.conf"
assert_eq "NA5 host_id over 200 chars: inactive" "1" "$(na_active "$NA5/long-id")"
mkdir -p "$NA5/many"; { printf 'host_id=%s\n' "$L12_HID"; for _i in 1 2 3 4 5 6 7 8; do printf 'pad%s=1\n' "$_i"; done; } > "$NA5/many/calibration-never-ask.conf"
assert_eq "NA5 more than 8 lines: inactive" "1" "$(na_active "$NA5/many")"
mkdir -p "$NA5/eight"; { printf 'host_id=%s\n' "$L12_HID"; for _i in 1 2 3 4 5 6 7; do printf 'pad%s=1\n' "$_i"; done; } > "$NA5/eight/calibration-never-ask.conf"
assert_eq "NA5 exactly 8 lines: active" "0" "$(na_active "$NA5/eight")"
mkdir -p "$NA5/wide"; { printf 'host_id=%s\n' "$L12_HID"; printf 'pad=%s\n' "$(printf 'x%.0s' $(seq 1 600))"; } > "$NA5/wide/calibration-never-ask.conf"
assert_eq "NA5 a line over the byte cap: inactive" "1" "$(na_active "$NA5/wide")"
# A hostile host_id is compared, never executed.
NA5_PWN="$TMPDIR_BASE/na5-pwned"
mkdir -p "$NA5/pwn"; printf 'host_id=$(touch %s)`touch %s`\n' "$NA5_PWN" "$NA5_PWN" > "$NA5/pwn/calibration-never-ask.conf"
assert_eq "NA5 hostile host_id: inactive" "1" "$(na_active "$NA5/pwn")"
[[ ! -e "$NA5_PWN" ]] && pass "NA5 hostile host_id is never executed" || fail "NA5 hostile host_id was executed"
case_ran NA5

case_end

grp_done never-ask-cases.sh
