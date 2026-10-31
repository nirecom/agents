#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-load/compute-cases.sh — the pure computation over format-2
# snapshots (_thl_load_compute <prev> <cur> <roots-file>), the roots (_thl_load_roots) and the
# snapshot seam (_thl_load_snapshot): LS8-LS11, LS13, LS16, SNAP1, SNAP2. The external load is the
# sum of the non-internal processes' CPU deltas; the host counter only caps it.

R0="$ROOT_PID 1 500 10240 bash"

case_begin "load-compute" "bin/lib/test-host-load.sh"

# ── LS8 a process that ended inside the interval is not counted ─────────────
snap2 "$CD/ls8.prev" 100000 1000000 "$R0" "7100 1 900 4096 game.exe"
snap2 "$CD/ls8.cur" 102000 1006000 "$R0"
compute "$CD/ls8.prev" "$CD/ls8.cur"
assert_eq "LS8 driver loads the load lib (rc 0)" "0" "$RC"
assert_eq "LS8 state=ok" "ok" "$(kv_of "$OUT" state)"
assert_eq "LS8 node host counter: host_counter=node" "node" "$(kv_of "$OUT" host_counter)"
assert_near "LS8 host busy is reported (3 cores)" 300 "$(kv_of "$OUT" host_busy_centicores)" 2
assert_near "LS8 the vanished process is not external load" 0 "$(kv_of "$OUT" external_centicores)" 2
snap2 "$CD/ls8n.prev" 100000 - "$R0" "7100 1 900 4096 game.exe"
snap2 "$CD/ls8n.cur" 102000 - "$R0" "7100 1 2900 4096 game.exe"
compute "$CD/ls8n.prev" "$CD/ls8n.cur"
assert_eq "LS8 no host counter: host_counter is empty" "1" "$(has_line "$OUT" host_counter=)"
assert_near "LS8 no host counter: the process sum still measures 1 core" 100 "$(kv_of "$OUT" external_centicores)" 2
case_ran LS8

# ── LS9 the process-sum counting rules ──────────────────────────────────────
# A +1000, B vanished (0), N new (whole 6000), pid 0 excluded, C went backwards (0)
# -> 7000 ms over 2000 ms = 350.
snap2 "$CD/ls9.prev" 200000 - "$R0" "0 0 100000 0 Idle" "7301 1 1000 4096 a" "7302 1 5000 4096 b" "7304 1 3000 4096 c"
snap2 "$CD/ls9.cur" 202000 - "$R0" "0 0 900000 0 Idle" "7301 1 2000 4096 a" "7303 1 6000 4096 n" "7304 1 1000 4096 c"
compute "$CD/ls9.prev" "$CD/ls9.cur"
assert_eq "LS9 state=ok" "ok" "$(kv_of "$OUT" state)"
assert_near "LS9 new pid whole, vanished 0, pid 0 out, negative 0" 350 "$(kv_of "$OUT" external_centicores)" 2
case_ran LS9

# ── LS10 the only cap is logical CPU count x wall; host busy never clips ────
# The host counter only checks the measurement (negative -> host-counter) and feeds the
# host_busy_centicores display; external load is the process sum alone.
snap2 "$CD/ls10.prev" 300000 - "$R0" "7100 1 0 4096 game.exe"
snap2 "$CD/ls10.cur" 302000 - "$R0" "7100 1 20000 4096 game.exe"
compute "$CD/ls10.prev" "$CD/ls10.cur" "PATH=$CPU4:$PATH"
assert_near "LS10 10 cores of process time on 4 logical CPUs clip to 400" 400 "$(kv_of "$OUT" external_centicores)" 2
snap2 "$CD/ls10h.prev" 300000 1000000 "$R0" "7100 1 0 4096 game.exe"
snap2 "$CD/ls10h.cur" 302000 1002000 "$R0" "7100 1 6000 4096 game.exe"
compute "$CD/ls10h.prev" "$CD/ls10h.cur"
assert_near "LS10 3 cores of process time over 1 core of host busy stay 300 (no host clip)" 300 "$(kv_of "$OUT" external_centicores)" 2
assert_near "LS10 the host busy delta is still reported as host_busy_centicores 100" 100 "$(kv_of "$OUT" host_busy_centicores)" 2
case_ran LS10

# ── LS11 rejects: a format-1 snapshot, a host counter going backwards ───────
printf 'wall_ms=400000\nhost_busy_ms=1000000\n%s 1 500\n' "$ROOT_PID" > "$CD/ls11.prev"
printf 'wall_ms=402000\nhost_busy_ms=1002000\n%s 1 500\n' "$ROOT_PID" > "$CD/ls11.cur"
compute "$CD/ls11.prev" "$CD/ls11.cur"
assert_eq "LS11 format 1 (no snapshot=2): unmeasurable" "unmeasurable" "$(kv_of "$OUT" state)"
assert_eq "LS11 format 1: reason=snapshot" "snapshot" "$(kv_of "$OUT" reason)"
snap2 "$CD/ls11b.prev" 400000 1000000 "$R0"
snap2 "$CD/ls11b.cur" 402000 999000 "$R0"
compute "$CD/ls11b.prev" "$CD/ls11b.cur"
assert_eq "LS11 host busy went backwards: reason=host-counter" "host-counter" "$(kv_of "$OUT" reason)"
snap2 "$CD/ls11c.cur" 402000 1002000 "$ROOT_PID 1 500"
compute "$CD/ls11b.prev" "$CD/ls11c.cur"
assert_eq "LS11 a 3-field process line: reason=snapshot" "snapshot" "$(kv_of "$OUT" reason)"
case_ran LS11

# ── LS16 the memory lines: MB values, the total/scope pair, unknown ─────────
snap2 "$CD/ls16.prev" 500000 - "$R0"
snap2 "$CD/ls16.cur" 502000 - "host_mem_avail_kb=3145728" "host_mem_total_kb=8388608" "host_mem_scope=cgroup" "$R0"
compute "$CD/ls16.prev" "$CD/ls16.cur"
assert_eq "LS16 mem_avail_mb from kB" "3072" "$(kv_of "$OUT" mem_avail_mb)"
assert_eq "LS16 mem_total_mb from kB" "8192" "$(kv_of "$OUT" mem_total_mb)"
assert_eq "LS16 mem_scope passed through" "cgroup" "$(kv_of "$OUT" mem_scope)"
snap2 "$CD/ls16t.cur" 502000 - "host_mem_avail_kb=3145728" "host_mem_total_kb=8388608" "$R0"
compute "$CD/ls16.prev" "$CD/ls16t.cur"
assert_eq "LS16 total without scope: the pair counts as absent (total)" "unknown" "$(kv_of "$OUT" mem_total_mb)"
assert_eq "LS16 total without scope: the pair counts as absent (scope)" "unknown" "$(kv_of "$OUT" mem_scope)"
snap2 "$CD/ls16n.cur" 502000 - "$R0"
compute "$CD/ls16.prev" "$CD/ls16n.cur"
assert_eq "LS16 no memory lines: state still ok" "ok" "$(kv_of "$OUT" state)"
assert_eq "LS16 no memory lines: mem_avail_mb unknown" "unknown" "$(kv_of "$OUT" mem_avail_mb)"
case_ran LS16

case_end

case_begin "load-roots" "bin/lib/test-host-load.sh"

# ── LS13 roots: live same-env owners of lanes and presence records ──────────
C="$(new_cache)"
mk_slot "$C" 1 "$LIVE_SLEEP"
mk_slot "$C" 2 "$DEAD_PID"
mk_slot "$C" 3 "$LIVE_SLEEP2" "other-env"
mk_presence "$C" "$LIVE_SLEEP2.$(now_epoch).1301" "$LIVE_SLEEP2" "$(now_epoch)"
mk_slot "$C" 4 "$LIVE_SLEEP3" "other-env"
load_drv "$C" "$CD" -- '_thl_load_roots'
LS13_ROOTS=" $(printf '%s' "$OUT" | tr '\n' ' ') "
ROOT_PID2="$LIVE_SLEEP2"
[ -r "/proc/$LIVE_SLEEP2/winpid" ] && ROOT_PID2="$(cat "/proc/$LIVE_SLEEP2/winpid")"
ROOT_PID3="$LIVE_SLEEP3"
[ -r "/proc/$LIVE_SLEEP3/winpid" ] && ROOT_PID3="$(cat "/proc/$LIVE_SLEEP3/winpid")"
if kill -0 "$LIVE_SLEEP3" 2>/dev/null; then
    case "$LS13_ROOTS" in *" $ROOT_PID3 "*|*" $LIVE_SLEEP3 "*)
        fail "LS13 a live owner of an other-env lane only was kept as a root" "roots=[$LS13_ROOTS] pid=$LIVE_SLEEP3/$ROOT_PID3" ;;
        *) pass "LS13 a live owner of an other-env lane only is not a root" ;; esac
else
    fail "LS13 precondition: the other-env-only owner $LIVE_SLEEP3 is not alive"
fi
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

# ── SNAP1 the seam's output is the snapshot; the real probe yields format 2 ─
S="$(new_snaps)"
gen_snaps "$S" own0 0
load_drv "$(new_cache)" "$S" -- "_thl_load_snapshot $(printf '%q' "$CD/snap1.out"); echo \"rc=\$?\""
assert_eq "SNAP1 seam: _thl_load_snapshot accepts a format-2 snapshot (rc 0)" "0" "$(kv_of "$OUT" rc)"
assert_eq "SNAP1 seam: _thl_load_snapshot copies the TEST_LANES_LOAD_PROBE_CMD output" \
    "$(cat "$S/snap.1")" "$(cat "$CD/snap1.out" 2>/dev/null)"
rm -f "$CD/snap1.real"
load_drv "$(new_cache)" "$S" TEST_LANES_LOAD_PROBE_CMD= -- "_thl_load_snapshot $(printf '%q' "$CD/snap1.real")"
SNAP1_HEAD="$(sed -n '1,2p' "$CD/snap1.real" 2>/dev/null | tr '\n' ' ')"
SNAP1_PROCS="$(grep -cE '^[0-9]+ [0-9]+ [0-9]+ [0-9]+ [A-Za-z0-9._?-]{1,64}$' "$CD/snap1.real" 2>/dev/null)"
[[ $SNAP1_HEAD =~ ^wall_ms=[0-9]+\ snapshot=2\ $ ]] && pass "SNAP1 real probe: wall_ms=<n> then snapshot=2" \
    || fail "SNAP1 real probe: lines 1-2 are not wall_ms=<n> / snapshot=2" "head=$(printf '%q' "$SNAP1_HEAD") rc=$RC err=$(printf '%q' "$ERR")"
[ "${SNAP1_PROCS:-0}" -ge 1 ] && pass "SNAP1 real probe: process lines <pid> <ppid> <cpu_ms> <rss_kb> <name> ($SNAP1_PROCS)" \
    || fail "SNAP1 real probe: no format-2 process line"
if command -v node >/dev/null 2>&1; then
    grep -qE '^host_busy_ms=[0-9]+$' "$CD/snap1.real" 2>/dev/null && pass "SNAP1 node present: a host_busy_ms line" \
        || fail "SNAP1 node present but no host_busy_ms line"
else
    skip "SNAP1 node absent: the node host lines are not exercised here"
fi
case_ran SNAP1

# ── SNAP2 one process line outside _THL_PROBE_LINE_RE rejects the whole snapshot (rc 1) ─
# @N64@ / @N65@ = a 64 / 65-char name; @SP@ = a literal space (the table trims its fields).
SNAP2_N64="$(printf 'n%.0s' {1..64})"
SNAP2_N65="${SNAP2_N64}n"
SNAP2_DIR="$(new_snaps)"
while IFS='|' read -r SNAP2_NAME SNAP2_LINE SNAP2_WANT; do
    [[ -z "$SNAP2_NAME" || "$SNAP2_NAME" =~ ^[[:space:]]*# ]] && continue
    SNAP2_NAME="${SNAP2_NAME//[[:space:]]/}"
    SNAP2_WANT="${SNAP2_WANT//[[:space:]]/}"
    SNAP2_LINE="${SNAP2_LINE#"${SNAP2_LINE%%[![:space:]]*}"}"
    SNAP2_LINE="${SNAP2_LINE%"${SNAP2_LINE##*[![:space:]]}"}"
    SNAP2_LINE="${SNAP2_LINE//@N64@/$SNAP2_N64}"
    SNAP2_LINE="${SNAP2_LINE//@N65@/$SNAP2_N65}"
    SNAP2_LINE="${SNAP2_LINE//@SP@/ }"
    rm -f "$SNAP2_DIR/count"
    snap2 "$SNAP2_DIR/snap.1" 100000 1000000 "$R0" "$SNAP2_LINE"
    load_drv "$(new_cache)" "$SNAP2_DIR" -- "_thl_load_snapshot $(printf '%q' "$CD/snap2.out"); echo \"rc=\$?\"" </dev/null
    assert_eq "SNAP2 $SNAP2_NAME: _thl_load_snapshot rc $SNAP2_WANT" "$SNAP2_WANT" "$(kv_of "$OUT" rc)"
done <<'TABLE'
control-valid        | 7100 1 900 4096 game.exe           | 0
extra-column         | 7100 1 900 4096 game.exe extra     | 1
space-in-name        | 7100 1 900 4096 my@SP@game         | 1
missing-column       | 7100 1 900 4096                    | 1
double-space         | 7100  1 900 4096 game.exe          | 1
illegal-char-bang    | 7100 1 900 4096 game!exe           | 1
illegal-char-slash   | 7100 1 900 4096 bin/game           | 1
illegal-char-colon   | 7100 1 900 4096 C:game             | 1
question-mark-kept   | 7100 1 900 4096 g?me               | 0
name-length-1        | 7100 1 900 4096 g                  | 0
name-length-64       | 7100 1 900 4096 @N64@              | 0
name-length-65       | 7100 1 900 4096 @N65@              | 1
empty-name           | 7100 1 900 4096@SP@                | 1
non-numeric-pid      | abc 1 900 4096 game.exe            | 1
non-numeric-ppid     | 7100 x 900 4096 game.exe           | 1
decimal-cpu-ms       | 7100 1 9.5 4096 game.exe           | 1
negative-rss-kb      | 7100 1 900 -4 game.exe             | 1
TABLE
case_ran SNAP2

case_end

grp_done compute-cases.sh
