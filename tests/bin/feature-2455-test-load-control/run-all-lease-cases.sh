#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/run-all-lease-cases.sh — R1-R13.
# Reuses the feature-1832 run-all fixture (a copied runner outside the live tree).
# fx_init is deliberately NOT called: it installs its own EXIT trap and would
# replace the dispatcher's; the two fixture roots are pinned by hand instead.

case_begin "run-all-lease" "tests/run-all.sh"

# shellcheck source=../../tests/feature-1832-run-all-parallel/_lib.sh
. "$AGENTS_ROOT/tests/tests/feature-1832-run-all-parallel/_lib.sh"
FX_TMP_ROOT="$TMPDIR_BASE/fx"
FX_CACHE_DIR="$FX_TMP_ROOT/run-all-cache"
fx_drop_ambient_controls
# fx_drop_ambient_controls also dropped the dispatcher's resolver pin; restore it so
# neither the runner nor run_ft ever reads the developer's real .env.
export RUN_ALL_CONFIG_VAR_CMD="$NO_CONFIG_VAR_CMD"
# fx_init would export this too: the copied runner reads the live tree's registry through it.
export RUN_ALL_REGISTRY_LIB="$FX_REPO_ROOT/bin/lib/test-language-registry.sh"
mkdir -p "$FX_CACHE_DIR"
R_LANE_VARS="TEST_LANES TEST_MAX_JOBS_PER_HOST TEST_MAX_JOBS_PER_RUN TEST_LANES_HELD TEST_LANES_TTL TEST_LANES_HEARTBEAT TEST_LANES_WAIT_INTERVAL TEST_LANES_WAIT_CAP"
# r_lanes_line — the runner's `lanes:` progress line, prefix stripped (empty if none).
r_lanes_line() { sed -n 's/^\[run-all\] lanes: //p' "$R_ERR" | head -n 1; }

# r_reset — drop every lane control and empty the shared slots/ between cases.
# Controls are plain (unexported) shell vars: fx_control_args forwards them to
# the runner explicitly and nothing else inherits them.
r_reset() {
    # shellcheck disable=SC2086
    unset $R_LANE_VARS FX_WITH_LANES
    rm -rf "$FX_CACHE_DIR/slots"
}

# r_root <n-peak-dummies> [dummy-opts] — echoes a fixture root with lanes.
r_root() {
    local n="$1" root i; shift
    root="$(FX_WITH_LANES="${FX_WITH_LANES:-1}" fx_new_root)"
    for ((i = 1; i <= n; i++)); do fx_add_dummy "$root" "p$i" "$@"; done
    echo "$root"
}
R_OUT="$FX_TMP_ROOT/r.out"
R_ERR="$FX_TMP_ROOT/r.err"
r_has_lanes_line() { grep -q '^\[run-all\] lanes: ' "$R_ERR"; }
# r_no_leftover <label> — neither a held lane nor a reclaim grave remains.
r_no_leftover() {
    assert_eq "$1: no lane left" "" "$(lane_names "$FX_CACHE_DIR")"
    assert_eq "$1: no .grave.* left" "0" "$(grave_count "$FX_CACHE_DIR")"
}

# ── R1 the lease caps -j at N-1 ─────────────────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_WAIT_CAP=5; TEST_LANES_WAIT_INTERVAL=1
R1="$(r_root 6 --peak --sleep 1)"
fx_exec "$R1" 120 "$R_OUT" "$R_ERR" -j 8 --all; _rc=$?
assert_eq "R1 run exits 0" "0" "$_rc"
r_has_lanes_line && pass "R1 stderr carries a '[run-all] lanes:' line" || fail "R1 no lanes: line on stderr"
[[ "$(r_lanes_line)" =~ ^jobs\ 2\ of\ requested\ [0-9]+\ \(max\ jobs\ per\ host\ 3,\ source\ env\;\ lanes\ 1\ 2\)$ ]] \
    && pass "R1 lanes: line is 'jobs <granted> of requested <n> (max jobs per host <H>, source <s>; lanes <i...>)'" \
    || fail "R1 lanes: line format — got $(printf '%q' "$(r_lanes_line)")"
assert_eq "R1 N=3, -j 8: peak concurrency is N-1 = 2" "2" "$(fx_peak_of "$(fx_peak_log "$R1")")"
case_ran R1

# ── R2 --print-plan leases nothing; jobs= is min(requested, H-1) ────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3
R2="$(r_root 2)"
fx_exec "$R2" 60 "$R_OUT" "$R_ERR" --print-plan --all; _rc=$?
assert_eq "R2 --print-plan exits 0" "0" "$_rc"
assert_eq "R2 --print-plan creates no lane" "" "$(lane_names "$FX_CACHE_DIR")"
# Eight tests and -j 8 make the requested width 8 whether or not it is clamped to the test count.
R2W="$(r_root 8)"
r2_plan() {  # r2_plan <label> <want-jobs> <want-plan-note>
    fx_exec "$R2W" 60 "$R_OUT" "$R_ERR" --print-plan -j 8 --all; _rc=$?
    assert_eq "R2 $1: --print-plan exits 0" "0" "$_rc"
    assert_eq "R2 $1: jobs= is $2" "jobs=$2" "$(grep '^jobs=' "$R_OUT")"
    grep -qF -- "plan: $3" "$R_ERR" && pass "R2 $1: stderr carries 'plan: $3'" || fail "R2 $1: stderr lacks 'plan: $3' — err=$(printf '%q' "$(cat "$R_ERR")")"
    assert_eq "R2 $1: --print-plan creates no lane" "" "$(lane_names "$FX_CACHE_DIR")"
}
r_reset; TEST_MAX_JOBS_PER_HOST=3
r2_plan "H=3 -j 8" 2 "jobs 2 of requested 8 (max jobs per host 3, source env; a live lease may grant fewer)"
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES=off
r2_plan "TEST_LANES=off" 8 "not applied (TEST_LANES=off); jobs 8 as requested"
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_HELD=123
r2_plan "nested holder" 8 "not applied (nested under a lane holder); jobs 8 as requested"
case_ran R2

# ── R3 lanes are released on every exit path ────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_HEARTBEAT=1
R3="$(r_root 2)"
fx_exec "$R3" 60 "$R_OUT" "$R_ERR" -j 2 --all; _rc=$?
assert_eq "R3 normal exit: rc 0" "0" "$_rc"
r_no_leftover "R3 normal exit"
R3F="$(r_root 1 --exit 1)"
fx_exec "$R3F" 60 "$R_OUT" "$R_ERR" --all; _rc=$?
assert_eq "R3 FAIL exit: rc 1" "1" "$_rc"
r_no_leftover "R3 FAIL exit"
R3I="$(r_root 1 --sleep 30)"
fx_exec_bg "$R3I" "$R_OUT" "$R_ERR" --all
if fx_wait_file 20 "$R3I/pids/p1.self"; then
    [ -n "$(lane_names "$FX_CACHE_DIR")" ] && pass "R3 INT: a lane is held while the run is in flight (positive control)" || fail "R3 INT: no lane held while the run is in flight"
    kill -INT "$FX_BG_PID" 2>/dev/null || true
    fx_wait_gone 20 "$FX_BG_PID" || kill -KILL "$FX_BG_PID" 2>/dev/null
    wait "$FX_BG_PID" 2>/dev/null
    r_no_leftover "R3 INT after the interrupt"
else
    fx_kill_tree "$FX_BG_PID"; wait "$FX_BG_PID" 2>/dev/null
    fail "R3 INT: the run never started its test, interrupt path unverifiable"
fi
for _p in $(fx_recorded_pids "$R3I"); do fx_kill_tree "$_p"; done
sleep 2
assert_eq "R3 still no lane 2s later (no heartbeat re-created one)" "" "$(lane_names "$FX_CACHE_DIR")"
case_ran R3

# ── R4 full lanes: exit 4 without a contract ────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_WAIT_CAP=2; TEST_LANES_WAIT_INTERVAL=1
mk_slot "$FX_CACHE_DIR" 1 "$$"; mk_slot "$FX_CACHE_DIR" 2 "$$"
R4="$(r_root 1)"
fx_exec "$R4" 60 "$R_OUT" "$R_ERR" --all; _rc=$?
assert_eq "R4 lanes 1..N-1 live: run-all exits 4" "4" "$_rc"
grep -q 'RUN_CONTRACT:' "$R_OUT" && fail "R4 stdout carries a RUN_CONTRACT line at exit 4" || pass "R4 no RUN_CONTRACT line at exit 4"
grep -q 'Results:' "$R_OUT" && fail "R4 stdout carries a Results line at exit 4" || pass "R4 no Results line at exit 4"
# Same cause text as the find-tests exit-4 line (L4), emitted once — not per retry or per trap.
assert_eq "R4 stderr names the wait cap exactly once" "1" "$(grep -c 'no test lane freed within' "$R_ERR")"
case_ran R4

# ── R5 children see TEST_LANES_HELD ─────────────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=2
R5="$(r_root 0)"
printf '#!/usr/bin/env bash\n# Tests: tests/run-all.sh\n# Tags: fixture, scope:issue-specific\nprintf "%%s\\n" "${TEST_LANES_HELD-unset}" > "%s/held.txt"\nexit 0\n' "$R5" > "$R5/tests/bin/held.sh"
fx_exec "$R5" 60 "$R_OUT" "$R_ERR" --all
_h="$(cat "$R5/held.txt" 2>/dev/null)"
[[ "$_h" =~ ^[0-9]+$ ]] && pass "R5 child tests inherit TEST_LANES_HELD=<holder pid>" || fail "R5 child saw TEST_LANES_HELD=[$_h]"
case_ran R5

# ── R6 the heartbeat advances during a long test ────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=2; TEST_LANES_HEARTBEAT=1
R6="$(r_root 0)"
printf '#!/usr/bin/env bash\n# Tests: tests/run-all.sh\n# Tags: fixture, scope:issue-specific\nf="$RUN_ALL_CACHE_DIR/slots/lane.1/hb"\na="$(cat "$f" 2>/dev/null)"; sleep 3; b="$(cat "$f" 2>/dev/null)"\nprintf "%%s %%s\\n" "$a" "$b" > "%s/hb.txt"\nexit 0\n' "$R6" > "$R6/tests/bin/hb.sh"
fx_exec "$R6" 60 "$R_OUT" "$R_ERR" --all
read -r _a _b < "$R6/hb.txt" 2>/dev/null || { _a=""; _b=""; }
if [[ "$_a" =~ ^[0-9]+$ ]] && [[ "$_b" =~ ^[0-9]+$ ]] && [ "$_b" -gt "$_a" ]; then
    pass "R6 hb advanced during a 3s test ($_a -> $_b)"
else
    fail "R6 hb did not advance (before=[$_a] after=[$_b])"
fi
case_ran R6

# ── R7 --deadline truncates the lane wait ───────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_WAIT_INTERVAL=1
mk_slot "$FX_CACHE_DIR" 1 "$$"; mk_slot "$FX_CACHE_DIR" 2 "$$"
R7="$(r_root 1)"
_s=$SECONDS
fx_exec "$R7" 60 "$R_OUT" "$R_ERR" --deadline 3 --all; _rc=$?
_el=$((SECONDS - _s))
assert_eq "R7 --deadline 3 with full lanes: exit 4" "4" "$_rc"
if [ "$_rc" -eq 4 ] && [ "$_el" -ge 2 ] && [ "$_el" -le 10 ]; then
    pass "R7 the wait was cut at the deadline (${_el}s)"
else
    fail "R7 wait not bounded by --deadline 3 (rc=$_rc elapsed ${_el}s, want rc 4 after 2..10s)"
fi
case_ran R7

# ── R8 the calibrator opts out of lanes ─────────────────────────────────────
grep -qF 'export TEST_LANES=off' "$CALIBRATOR" && pass "R8 calibrator exports TEST_LANES=off" || fail "R8 bin/calibrate-test-parallelism.sh lacks 'export TEST_LANES=off'"
case_ran R8

# ── R9 no lanes lib: unchanged -j ───────────────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3
R9="$(FX_WITH_LANES=0 r_root 6 --peak --sleep 1)"
fx_exec "$R9" 120 "$R_OUT" "$R_ERR" -j 8 --all; _rc=$?
assert_eq "R9 run without the lanes lib exits 0" "0" "$_rc"
r_has_lanes_line && fail "R9 a lanes: line appeared without the lanes lib" || pass "R9 no lanes: line without the lanes lib"
_pk="$(fx_peak_of "$(fx_peak_log "$R9")")"
[ "$_pk" -ge 3 ] && pass "R9 -j is not capped without the lanes lib (peak $_pk >= 3)" || fail "R9 peak $_pk < 3 — -j was capped without the lanes lib"
case_ran R9

# ── R10 lane N is reserved for find-tests ───────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_WAIT_CAP=6; TEST_LANES_WAIT_INTERVAL=1
mk_slot "$FX_CACHE_DIR" 1 "$$"; mk_slot "$FX_CACHE_DIR" 2 "$$"
R10="$(r_root 1)"
R10_OUT="$FX_TMP_ROOT/r10.out"; R10_ERR="$FX_TMP_ROOT/r10.err"
fx_exec_bg "$R10" "$R10_OUT" "$R10_ERR" --all
_bg="$FX_BG_PID"
sleep 2
[ -e "$FX_CACHE_DIR/slots/lane.3" ] && fail "R10 the waiting run-all took the reserved lane.3" || pass "R10 the waiting run-all leaves lane.3 free"
R10R="$(mk_repo)"; add_tf "$R10R" bin/a.sh "src/x.js"; commit_all "$R10R" c
run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$FX_CACHE_DIR" TEST_MAX_JOBS_PER_HOST=3 TEST_LANES_WAIT_INTERVAL=1 TEST_LANES_WAIT_CAP=3 -- --root "$R10R" --sources src/x.js
assert_eq "R10 find-tests takes lane.3 and succeeds meanwhile" "0" "$RC"
fx_wait_gone 30 "$_bg" || fx_kill_tree "$_bg"
wait "$_bg" 2>/dev/null; _rc=$?
assert_eq "R10 the second run-all exits 4 at its cap (never used lane.3)" "4" "$_rc"
r_reset; TEST_MAX_JOBS_PER_HOST=1; TEST_LANES_WAIT_CAP=3
R10B="$(r_root 1)"
fx_exec "$R10B" 60 "$R_OUT" "$R_ERR" --all; _rc=$?
assert_eq "R10 N=1: run-all runs on lane.1 (rc 0)" "0" "$_rc"
r_has_lanes_line && pass "R10 N=1: the run was leased (lanes: line)" || fail "R10 N=1: no lanes: line — lane.1 not leased"
[[ "$(r_lanes_line)" =~ ^jobs\ 1\ of\ requested\ [0-9]+\ \(max\ jobs\ per\ host\ 1,\ source\ env\;\ lanes\ 1\)$ ]] \
    && pass "R10 N=1: lanes: line reports lane 1 of max jobs per host 1" \
    || fail "R10 N=1: lanes: line format — got $(printf '%q' "$(r_lanes_line)")"
case_ran R10

# ── R11 TEST_LANES=off and a nested holder: a not-applied notice, -j untouched ─
for _mode in off held; do
    r_reset; TEST_MAX_JOBS_PER_HOST=3
    if [ "$_mode" = off ]; then TEST_LANES=off; _why="TEST_LANES=off"; else TEST_LANES_HELD=123; _why="nested under a lane holder"; fi
    R11="$(r_root 6 --peak --sleep 1)"
    fx_exec "$R11" 120 "$R_OUT" "$R_ERR" -j 8 --all; _rc=$?
    assert_eq "R11 $_mode: run exits 0" "0" "$_rc"
    [[ "$(r_lanes_line)" =~ ^not\ applied\ \($_why\)\;\ jobs\ [0-9]+\ as\ requested$ ]] \
        && pass "R11 $_mode: lanes: line says 'not applied ($_why); jobs <n> as requested'" \
        || fail "R11 $_mode: lanes: not-applied notice — got $(printf '%q' "$(r_lanes_line)")"
    _pk="$(fx_peak_of "$(fx_peak_log "$R11")")"
    [ "$_pk" -ge 3 ] && pass "R11 $_mode: -j 8 is not capped at N-1 (peak $_pk >= 3)" || fail "R11 $_mode: peak $_pk < 3 — -j was capped"
    assert_eq "R11 $_mode: no lane created" "" "$(lane_names "$FX_CACHE_DIR")"
done
case_ran R11

# ── R12 partial grant: lane.1 busy, N=4 -j 8 runs on the two free lanes ─────
r_reset; TEST_MAX_JOBS_PER_HOST=4; TEST_LANES_WAIT_CAP=3; TEST_LANES_WAIT_INTERVAL=1
mk_slot "$FX_CACHE_DIR" 1 "$$"
R12="$(r_root 6 --peak --sleep 1)"
fx_exec "$R12" 120 "$R_OUT" "$R_ERR" -j 8 --all; _rc=$?
assert_eq "R12 run starts on a partial grant and exits 0" "0" "$_rc"
r_has_lanes_line && pass "R12 stderr carries a lanes: line" || fail "R12 no lanes: line — the run was not leased"
[[ "$(r_lanes_line)" =~ ^jobs\ 2\ of\ requested\ [0-9]+\ \(max\ jobs\ per\ host\ 4,\ source\ env\;\ lanes\ 2\ 3\)$ ]] \
    && pass "R12 lanes: line reports the partial grant on lanes 2 3" \
    || fail "R12 lanes: line format — got $(printf '%q' "$(r_lanes_line)")"
assert_eq "R12 N=4 with lane.1 busy: peak concurrency is the 2 granted lanes" "2" "$(fx_peak_of "$(fx_peak_log "$R12")")"
assert_eq "R12 the busy lane.1 is untouched and nothing else is left" "lane.1" "$(lane_names "$FX_CACHE_DIR")"
case_ran R12

# ── R13 a record from another OS version: the lanes: line carries the advice ─
r_reset
R13_HID="$(bash -c '. "$1"; run_all_host_id' _ "$PAR_LIB")"
R13_NOW="$(bash -c '. "$1"; command -v run_all_os_attr >/dev/null 2>&1 && run_all_os_attr' _ "$PAR_LIB")"
R13_OLD="${R13_NOW%%/*}"; R13_OLD="${R13_OLD:-Unknown}/0.0.0-r13"
printf 'schema=2\nhost_id=%s\nos=%s\nmax_jobs_per_host=3\nmeasured_at=2026-01-01T00:00:00Z\nsample_size=3\nrepeat=1\n' \
    "$R13_HID" "$R13_OLD" > "$FX_CACHE_DIR/parallelism.conf"
R13="$(r_root 1)"
fx_exec "$R13" 60 "$R_OUT" "$R_ERR" -j 2 --all; _rc=$?
assert_eq "R13 run exits 0" "0" "$_rc"
case "$(r_lanes_line)" in
    "jobs 1 of requested "[12]" (max jobs per host 3, source measured; lanes 1"*)
        pass "R13 the measured record sets the limit (max jobs per host 3, source measured)" ;;
    *) fail "R13 lanes: line does not report the measured limit — got $(printf '%q' "$(r_lanes_line)")" ;;
esac
grep -qF -- "; measured on $R13_OLD, now $R13_NOW; re-run RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh" "$R_ERR" \
    && [ -n "$R13_NOW" ] && pass "R13 the lanes: line carries the OS-version advice" \
    || fail "R13 no OS-version advice — now=[$R13_NOW] lanes=$(printf '%q' "$(r_lanes_line)")"
rm -f "$FX_CACHE_DIR/parallelism.conf"
case_ran R13

r_reset
case_end

grp_done run-all-lease-cases.sh
