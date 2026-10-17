#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-load/compute-cases.sh — the pure computation
# (_thl_load_compute <prev> <cur> <roots-file>), the roots (_thl_load_roots) and the
# snapshot seam (_thl_load_snapshot): LS8-LS11, LS13, SNAP1.

CD="$TMPDIR_BASE/compute"
mkdir -p "$CD"
printf '%s\n' "$ROOT_PID" > "$CD/roots"

# compute <prev> <cur> [NAME=VAL ...] — OUT holds the key=value lines of one computation.
compute() {
    local p="$1" c="$2"; shift 2
    load_drv "$(new_cache)" "$CD" "$@" -- "_thl_load_compute $(printf '%q' "$p") $(printf '%q' "$c") $(printf '%q' "$CD/roots")"
}

case_begin "load-compute" "bin/lib/test-host-load.sh"

# ── LS8 an external process that started and ended inside the interval ─────
printf 'wall_ms=100000\nhost_busy_ms=1000000\n%s 1 500\n7100 1 900\n' "$ROOT_PID" > "$CD/ls8.prev"
printf 'wall_ms=102000\nhost_busy_ms=1006000\n%s 1 500\n7100 1 900\n' "$ROOT_PID" > "$CD/ls8.cur"
compute "$CD/ls8.prev" "$CD/ls8.cur"
assert_eq "LS8 driver loads the load lib (rc 0)" "0" "$RC"
assert_eq "LS8 state=ok" "ok" "$(kv_of "$OUT" state)"
assert_eq "LS8 host counter present: host_counter=system" "system" "$(kv_of "$OUT" host_counter)"
assert_near "LS8 the host counter keeps the vanished process's 3 cores" 300 "$(kv_of "$OUT" external_centicores)"
sed 's/^host_busy_ms=.*/host_busy_ms=unavailable/' "$CD/ls8.prev" > "$CD/ls8u.prev"
sed 's/^host_busy_ms=.*/host_busy_ms=unavailable/' "$CD/ls8.cur" > "$CD/ls8u.cur"
compute "$CD/ls8u.prev" "$CD/ls8u.cur"
assert_eq "LS8 counter unavailable: host_counter=process-sum" "process-sum" "$(kv_of "$OUT" host_counter)"
assert_near "LS8 process-sum misses the vanished process (the fallback's fixed limit)" 0 "$(kv_of "$OUT" external_centicores)" 2
case_ran LS8

# ── LS9 the process-sum counting rules ──────────────────────────────────────
# A +1000, B vanished (0), N new (whole 6000), pid 0 excluded, C went backwards (0)
# -> 7000 ms over 2000 ms = 350.
printf 'wall_ms=200000\nhost_busy_ms=unavailable\n%s 1 500\n0 0 100000\n7301 1 1000\n7302 1 5000\n7304 1 3000\n' "$ROOT_PID" > "$CD/ls9.prev"
printf 'wall_ms=202000\nhost_busy_ms=unavailable\n%s 1 500\n0 0 900000\n7301 1 2000\n7303 1 6000\n7304 1 1000\n' "$ROOT_PID" > "$CD/ls9.cur"
compute "$CD/ls9.prev" "$CD/ls9.cur"
assert_eq "LS9 host_counter=process-sum" "process-sum" "$(kv_of "$OUT" host_counter)"
assert_near "LS9 new pid whole, vanished 0, pid 0 out, negative 0" 350 "$(kv_of "$OUT" external_centicores)" 2
case_ran LS9

# ── LS10 host busy clipped at logical CPU count x wall ──────────────────────
printf 'wall_ms=300000\nhost_busy_ms=1000000\n%s 1 500\n' "$ROOT_PID" > "$CD/ls10.prev"
printf 'wall_ms=302000\nhost_busy_ms=1020000\n%s 1 500\n' "$ROOT_PID" > "$CD/ls10.cur"
compute "$CD/ls10.prev" "$CD/ls10.cur" "PATH=$CPU4:$PATH"
assert_near "LS10 10 cores of host busy on 4 logical CPUs clip to 400" 400 "$(kv_of "$OUT" external_centicores)" 2
case_ran LS10

# ── LS11 Windows counters: busy = dTs x cpus - dIdle (100 ns units) ─────────
# dTs 20,000,000 x 4 - dIdle 60,000,000 = 20,000,000 x 100ns = 2000 ms over 2000 ms = 100.
printf 'wall_ms=400000\nhost_idle_100ns=500000000\nhost_ts_100ns=1000000000\nhost_cpus=4\n%s 1 500\n' "$ROOT_PID" > "$CD/ls11.prev"
printf 'wall_ms=402000\nhost_idle_100ns=560000000\nhost_ts_100ns=1020000000\nhost_cpus=4\n%s 1 500\n' "$ROOT_PID" > "$CD/ls11.cur"
compute "$CD/ls11.prev" "$CD/ls11.cur"
assert_eq "LS11 the three Windows keys count as the host counter" "system" "$(kv_of "$OUT" host_counter)"
assert_near "LS11 one busy core from the Windows counters" 100 "$(kv_of "$OUT" external_centicores)" 2
grep -v '^host_cpus=' "$CD/ls11.cur" > "$CD/ls11m.cur"
compute "$CD/ls11.prev" "$CD/ls11m.cur"
assert_eq "LS11 a missing counter line falls back to process-sum" "process-sum" "$(kv_of "$OUT" host_counter)"
assert_near "LS11 fallback: no process moved, so 0" 0 "$(kv_of "$OUT" external_centicores)" 2
case_ran LS11

case_end

case_begin "load-roots" "bin/lib/test-host-load.sh"

# ── LS13 roots: live same-env owners of lanes and presence records ──────────
C="$(new_cache)"
mk_slot "$C" 1 "$LIVE_SLEEP"
mk_slot "$C" 2 "$DEAD_PID"
mk_slot "$C" 3 "$LIVE_SLEEP2" "other-env"
mk_presence "$C" "$LIVE_SLEEP2.$(now_epoch).1301" "$LIVE_SLEEP2" "$(now_epoch)"
load_drv "$C" "$CD" -- '_thl_load_roots'
LS13_ROOTS=" $(printf '%s' "$OUT" | tr '\n' ' ') "
ROOT_PID2="$LIVE_SLEEP2"
[ -r "/proc/$LIVE_SLEEP2/winpid" ] && ROOT_PID2="$(cat "/proc/$LIVE_SLEEP2/winpid")"
case "$LS13_ROOTS" in *" $ROOT_PID "*) pass "LS13 a live lane owner is a root" ;;
    *) fail "LS13 live lane owner missing from the roots" "roots=[$LS13_ROOTS] rc=$RC err=$(printf '%q' "$ERR")" ;; esac
case "$LS13_ROOTS" in *" $ROOT_PID2 "*) pass "LS13 a live presence-record owner is a root" ;;
    *) fail "LS13 live presence owner missing from the roots" "roots=[$LS13_ROOTS]" ;; esac
case "$LS13_ROOTS" in *" $DEAD_PID "*) fail "LS13 a dead owner was kept as a root" ;; *) pass "LS13 a dead owner is dropped" ;; esac
if [ -r "/proc/$LIVE_SLEEP/winpid" ]; then
    case "$LS13_ROOTS" in *" $LIVE_SLEEP "*) [ "$LIVE_SLEEP" != "$ROOT_PID" ] \
        && fail "LS13 the Cygwin pid was kept instead of its Windows pid" || pass "LS13 Windows pid equals the Cygwin pid" ;;
        *) pass "LS13 the root is reported as its Windows pid ($ROOT_PID)" ;; esac
else
    skip "LS13 /proc/<pid>/winpid absent: the Windows pid conversion is not exercised here"
fi
case_ran LS13

case_end

case_begin "load-snapshot-seam" "bin/lib/test-host-load-probe.sh"

# ── SNAP1 the seam's output is the snapshot; the real probe yields the normal form ─
S="$(new_snaps)"
gen_snaps "$S" own0 0
load_drv "$(new_cache)" "$S" -- "_thl_load_snapshot $(printf '%q' "$CD/snap1.out"); echo \"rc=\$?\""
assert_eq "SNAP1 seam: _thl_load_snapshot copies the TEST_LANES_LOAD_PROBE_CMD output" \
    "$(cat "$S/snap.1")" "$(cat "$CD/snap1.out" 2>/dev/null)"
rm -f "$CD/snap1.real"
load_drv "$(new_cache)" "$S" TEST_LANES_LOAD_PROBE_CMD= -- "_thl_load_snapshot $(printf '%q' "$CD/snap1.real")"
SNAP1_HEAD="$(sed -n '1p' "$CD/snap1.real" 2>/dev/null)"
SNAP1_HOST="$(sed -n '2,4p' "$CD/snap1.real" 2>/dev/null | grep -cE '^(host_busy_ms=([0-9]+|unavailable)|host_idle_100ns=[0-9]+|host_ts_100ns=[0-9]+|host_cpus=[0-9]+)$')"
SNAP1_PROCS="$(grep -cE '^[0-9]+ [0-9]+ [0-9]+$' "$CD/snap1.real" 2>/dev/null)"
[[ $SNAP1_HEAD =~ ^wall_ms=[0-9]+$ ]] && pass "SNAP1 real probe: line 1 is wall_ms=<n>" \
    || fail "SNAP1 real probe: line 1 is not wall_ms=<n>" "head=$(printf '%q' "$SNAP1_HEAD") rc=$RC err=$(printf '%q' "$ERR")"
[ "${SNAP1_HOST:-0}" -ge 1 ] && pass "SNAP1 real probe: a host counter line follows" || fail "SNAP1 real probe: no host counter line"
[ "${SNAP1_PROCS:-0}" -ge 1 ] && pass "SNAP1 real probe: process lines <pid> <ppid> <cpu_ms> ($SNAP1_PROCS)" \
    || fail "SNAP1 real probe: no process line"
# L3 gap: the `%.0f` print of host_busy_ms / per-pid cpu_ms past 2^31 only matters under mawk.
# Because: the fixture cannot force mawk portably, and the awk reads /proc/stat by a fixed path.

case_end

grp_done compute-cases.sh
