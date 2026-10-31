#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-lanes-share/load-shrink-cases.sh — FS14: a load scale-in
# shrinks the pool to 1 mid-run, so the later of two run-alls drops to per-run lane cap 0 and waits.
# Running jobs are never stopped, so only two things are asserted: (a) starts after a shrink
# obey the latest width, (b) once every pre-shrink job ended, the combined inflight <= pool 1.

case_begin "run-all-load-shrink" "tests/run-all.sh"

# Heartbeat 3: at 1 a loaded host misses the 2-heartbeat freshness window for the previous sample.
r_reset; TEST_MAX_JOBS_PER_HOST=4; AUTO_CONFIG_TEST_MAX_JOBS=on; TEST_LANES_HEARTBEAT=3
TEST_LANES_WAIT_CAP=60; TEST_LANES_WAIT_INTERVAL=1
# A valid schema-3 record for this host, so mode on never starts a calibration in the fixture.
FS14_HID="$(bash -c '. "$1"; run_all_host_id' _ "$PAR_LIB")"
FS14_OS="$(bash -c '. "$1"; command -v run_all_os_attr >/dev/null 2>&1 && run_all_os_attr' _ "$PAR_LIB")"
printf 'schema=3\nhost_id=%s\nos=%s\nmax_jobs_per_host=4\nmeasured_at=2026-01-01T00:00:00Z\nsample_size=3\nrepeat=1\nlogical_cpu_count=4\nmax_width_measured=4\nwidth_limit=logical-cpu-count\n' \
    "$FS14_HID" "$FS14_OS" > "$FX_CACHE_DIR/parallelism.conf"

# The format-2 probe stub: game.exe and the host busy time grow at 2 cores while the mode file
# says busy, 0 otherwise; every own root (presence record and lane owner) is listed with 0 CPU.
# 4 logical CPUs and max jobs per host 4 make reserved cores 0, so 2 external cores scale in 2.
FS14_PATH_SAVE="$FX_PATH_PREFIX"; FX_PATH_PREFIX="$CPU4_SHIM_DIR"
FS14_DIR="$FX_TMP_ROOT/fs14"; mkdir -p "$FS14_DIR"
export FS14_MODE_FILE="$FS14_DIR/mode" FS14_ACC_FILE="$FS14_DIR/acc" FS14_CACHE="$FX_CACHE_DIR"
printf 'idle\n' > "$FS14_MODE_FILE"
FS14_PROBE="$FS14_DIR/probe.sh"
cat > "$FS14_PROBE" <<'PROBE'
#!/usr/bin/env bash
mode="$(cat "$FS14_MODE_FILE" 2>/dev/null)"
now="$(date +%s%3N)"
pw=""; pb=0
read -r pw pb < "$FS14_ACC_FILE" 2>/dev/null
[ -n "$pw" ] || { pw="$now"; pb=1000000; }
rate=0; [ "$mode" = busy ] && rate=2
busy=$((pb + rate * (now - pw)))
printf '%s %s\n' "$now" "$busy" > "$FS14_ACC_FILE"
printf 'wall_ms=%s\nsnapshot=2\nhost_busy_ms=%s\nhost_cpus=4\n' "$now" "$busy"
printf '7100 1 %s 4096 game.exe\n' "$((busy - 1000000))"
seen=" "
for f in "$FS14_CACHE"/runs/run.*/owner "$FS14_CACHE"/slots/lane.*/owner; do
    p="$(sed -n 's/^pid=//p' "$f" 2>/dev/null)"
    [ -n "$p" ] || continue
    for q in "$p" "$(cat "/proc/$p/winpid" 2>/dev/null)"; do
        [ -n "$q" ] || continue
        case "$seen" in *" $q "*) continue ;; esac
        seen="$seen$q "
        printf '%s 1 0 1024 bash\n' "$q"
    done
done
exit 0
PROBE
chmod +x "$FS14_PROBE"
export TEST_LANES_LOAD_PROBE_CMD="$FS14_PROBE"

FS14_LOG="$FX_TMP_ROOT/fs14.log"; rm -f "$FS14_LOG"
# Run A's 3s tests: with thirty 1s tests it would end before the scale-in engages.
FS14A="$(fs_root 30 a "$FS14_LOG" 3)"
FS14B="$(fs_root 30 b "$FS14_LOG" 1)"
FS14_EA="$FX_TMP_ROOT/fs14a.err"; FS14_EB="$FX_TMP_ROOT/fs14b.err"
fx_exec_bg "$FS14A" "$FX_TMP_ROOT/fs14a.out" "$FS14_EA" --all; FS14_PA="$FX_BG_PID"
fx_wait_file 20 "$FS14A/pids/a1.self"
fx_exec_bg "$FS14B" "$FX_TMP_ROOT/fs14b.out" "$FS14_EB" --all; FS14_PB="$FX_BG_PID"
fx_wait_file 30 "$FS14B/pids/b1.self"
printf 'busy\n' > "$FS14_MODE_FILE"
FS14_SHRUNK=0
if wait_grep 40 "$FS14_EA" "load scale-in 2" && wait_grep 20 "$FS14_EB" "load scale-in 2"; then
    FS14_SHRUNK=1
    pass "FS14 both runs report the load scale-in width change"
else
    fail "FS14 no 'load scale-in 2' width line in both runs within 60s (not implemented?)" \
        "a=$(printf '%q' "$(grep 'lanes' "$FS14_EA" 2>/dev/null)") b=$(printf '%q' "$(grep 'lanes' "$FS14_EB" 2>/dev/null)")"
fi
FS14_TSEEN="$(fx_now_ms)"
sleep 6
FS14_TRESTORE="$(fx_now_ms)"
printf 'idle\n' > "$FS14_MODE_FILE"
fx_wait_gone 150 "$FS14_PA" "$FS14_PB" || { fx_kill_tree "$FS14_PA"; fx_kill_tree "$FS14_PB"; }
wait "$FS14_PA"; _ra=$?
wait "$FS14_PB"; _rb=$?
assert_eq "FS14 run A completes (rc 0)" "0" "$_ra"
assert_eq "FS14 run B resumes after the restore and completes (rc 0)" "0" "$_rb"
assert_eq "FS14 all 60 tests started" "60" "$(fx_peak_starts "$FS14_LOG")"

# (a) every start after the first scale-in line has j <= the latest width and inflight <= j.
fs14_starts_ok() {
    awk '
        /load scale-in/ { if (!done) on = 1 }
        match($0, /lanes: width [0-9]+ -> [0-9]+/) { s = substr($0, RSTART, RLENGTH); sub(/^lanes: width /, "", s)
            a = s; sub(/ -> .*/, "", a); sub(/.*-> /, "", s); w = s + 0
            # The first regrow ends the shrunk window: later starts belong to the restore (c).
            if (on && w > a + 0) { on = 0; done = 1 } }
        on && match($0, /start .* \(j=[0-9]+ inflight=[0-9]+\)/) {
            s = substr($0, RSTART, RLENGTH); sub(/.*\(j=/, "", s); j = s + 0
            sub(/^[0-9]+ inflight=/, "", s); f = s + 0; n++
            if (j > w || f > j) bad = bad " j=" j "/w=" w "/in=" f }
        END { if (bad != "") { print "bad" bad; exit 1 } print "ok " n + 0 }' "$1"
}
# The restore: some width line after the scale-in grows the width again (b > a).
fs14_regrew() {
    awk '/load scale-in/ { on = 1; next }
        on && match($0, /lanes: width [0-9]+ -> [0-9]+/) {
            s = substr($0, RSTART, RLENGTH); sub(/^lanes: width /, "", s)
            a = s; sub(/ -> .*/, "", a); b = s; sub(/.*-> /, "", b)
            if (b + 0 > a + 0) { print "grew " a "->" b; found = 1; exit } }
        END { if (!found) exit 1 }' "$1"
}
if [ "$FS14_SHRUNK" -eq 1 ]; then
    _nwin=0
    for _r in A B; do
        [ "$_r" = A ] && _f="$FS14_EA" || _f="$FS14_EB"
        _v="$(fs14_starts_ok "$_f")" && pass "FS14 (a) run $_r: starts in the shrunk window obey the latest width ($_v)" \
            || fail "FS14 (a) run $_r: a start exceeded the latest width" "$_v"
        case "$_v" in "ok "[0-9]*) _nwin=$((_nwin + ${_v#ok })) ;; esac
    done
    # Positive control: (a) is vacuous unless some start fell inside the shrunk window.
    [ "$_nwin" -gt 0 ] && pass "FS14 (a) positive control: $_nwin starts inside the shrunk window" \
        || fail "FS14 (a) no start inside the shrunk window; (a) checked nothing"
    # (b) jobs logged up to 1s after the shrink was seen count as pre-shrink (start-log latency margin).
    read -r _drain _nonempty _max < <(awk -v ts="$((FS14_TSEEN + 1000))" -v tr="$FS14_TRESTORE" '
        { sg = substr($1, 1, 1); if (sg == "+") st[$3] = $2; else en[$3] = $2 }
        function act(x,   id, n) { n = 0; for (id in st) if (st[id] <= x && (!(id in en) || en[id] > x)) n++; return n }
        END { d = ts; for (id in st) if (st[id] < ts) { e = (id in en) ? en[id] : 9e15; if (e > d) d = e }
              m = act(d); for (id in st) if (st[id] > d && st[id] <= tr) { a = act(st[id]); if (a > m) m = a }
              printf "%d %d %d\n", d, (d < tr) ? 1 : 0, m }' "$FS14_LOG")
    assert_eq "FS14 (b) positive control: the pre-shrink jobs drained before the restore" "1" "${_nonempty:-0}"
    [ "${_max:-9}" -le 1 ] && pass "FS14 (b) after the drain the combined inflight stays within pool 1 (max ${_max})" \
        || fail "FS14 (b) combined inflight ${_max:-?} exceeds the shrunk pool 1 after the drain"
    # (c) the restore: a width grows back, and work actually runs wider than pool 1 afterwards.
    _g="$(fs14_regrew "$FS14_EA" || fs14_regrew "$FS14_EB")" \
        && pass "FS14 (c) a run regrows its width after the load restore ($_g)" \
        || fail "FS14 (c) no width line grows back after the load restore"
    _post="$(awk -v tr="$FS14_TRESTORE" '
        { sg = substr($1, 1, 1); if (sg == "+") st[$3] = $2; else en[$3] = $2 }
        END { m = 0; for (x in st) if (st[x] > tr) { n = 0
                  for (id in st) if (st[id] <= st[x] && (!(id in en) || en[id] > st[x])) n++
                  if (n > m) m = n }
              print m }' "$FS14_LOG")"
    [ "${_post:-0}" -ge 2 ] && pass "FS14 (c) after the restore the combined inflight exceeds pool 1 (max ${_post})" \
        || fail "FS14 (c) combined inflight after the restore stayed at ${_post:-?} (width not restored)"
fi
assert_eq "FS14 no lane left" "" "$(lane_names "$FX_CACHE_DIR")"
assert_eq "FS14 no presence record left" "" "$(run_names "$FX_CACHE_DIR")"
case_ran FS14

unset TEST_LANES_LOAD_PROBE_CMD FS14_MODE_FILE FS14_ACC_FILE FS14_CACHE
FX_PATH_PREFIX="$FS14_PATH_SAVE"
rm -f "$FX_CACHE_DIR/parallelism.conf"
r_reset
case_end

grp_done load-shrink-cases.sh
