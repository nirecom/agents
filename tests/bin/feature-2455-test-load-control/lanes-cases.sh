#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/lanes-cases.sh — L1-L18, LS1-LS5.
# Drives bin/lib/test-host-lanes.sh through its public API (lanes_drv) and the
# two CLIs. Every wait is shortened to interval 1s / cap 3s unless stated.

case_begin "host-lanes" "bin/lib/test-host-lanes.sh"

LIVE_PID="$$"
# Snippet shared by the lease cases: print the result and the held lanes.
LEASE_SNIP='thl_init_dir; thl_find_tests_lease; rc=$?; echo "rc=$rc"; echo "drvpid=$$"; echo "held=${TEST_LANES_HELD-}"'

# ── L1 acquire writes owner + hb; release empties slots/ ────────────────────
L1C="$TMPDIR_BASE/l1-cache"
lanes_drv "$L1C" TEST_MAX_JOBS_PER_HOST=2 -- "$LEASE_SNIP"'
for d in "$THL_CACHE_ROOT"/slots/lane.*; do echo "lane=${d##*/}"; sed "s/^/owner:/" "$d/owner"; echo "hb=$(cat "$d/hb")"; done
thl_release_all; n=0; for d in "$THL_CACHE_ROOT"/slots/lane.* "$THL_CACHE_ROOT"/slots/.grave.*; do [ -e "$d" ] && n=$((n+1)); done; echo "after=$n"'
_pid="$(kv_of "$OUT" drvpid)"
assert_eq "L1 find-tests lease returns 0" "0" "$(kv_of "$OUT" rc)"
assert_eq "L1 find-tests takes the last lane first (budget 2)" "lane.2" "$(kv_of "$OUT" lane)"
assert_eq "L1 owner pid= is the holder" "${_pid:-<no-driver-pid>}" "$(kv_of "$OUT" owner:pid)"
assert_eq "L1 owner env= is \$OSTYPE" "$OSTYPE" "$(kv_of "$OUT" owner:env)"
assert_eq "L1 owner kind=find-tests" "find-tests" "$(kv_of "$OUT" owner:kind)"
[[ "$(kv_of "$OUT" owner:start)" =~ ^[0-9]+$ ]] && pass "L1 owner start= is an epoch" || fail "L1 owner start= missing or not numeric"
[[ "$(kv_of "$OUT" owner:token)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && pass "L1 owner token=<pid>.<epoch>.<rand>" || fail "L1 owner token= missing or malformed: $(kv_of "$OUT" owner:token)"
[[ "$(kv_of "$OUT" hb)" =~ ^[0-9]+$ ]] && pass "L1 hb holds an epoch" || fail "L1 hb missing or not numeric"
[[ "$(kv_of "$OUT" held)" =~ ^[0-9]+$ ]] && pass "L1 TEST_LANES_HELD exported as the holder pid" || fail "L1 TEST_LANES_HELD not exported: [$(kv_of "$OUT" held)]"
assert_eq "L1 thl_release_all leaves slots/ empty (no lane.*, no .grave.*)" "0" "$(kv_of "$OUT" after)"
case_ran L1

# ── L2 dead pid in the same env is reclaimed ────────────────────────────────
L2C="$TMPDIR_BASE/l2-cache"
for _i in 1 2 3; do mk_slot "$L2C" "$_i" "$(dead_pid)"; done
lanes_drv "$L2C" TEST_MAX_JOBS_PER_HOST=3 -- "$LEASE_SNIP"
assert_eq "L2 all lanes held by dead same-env pids: acquire succeeds" "0" "$(kv_of "$OUT" rc)"
case_ran L2

# ── L3 live pid past the TTL is reclaimed ───────────────────────────────────
L3C="$TMPDIR_BASE/l3-cache"
mk_slot "$L3C" 1 "$LIVE_PID" "$OSTYPE" run-all "$(( $(now_epoch) - 610 ))"
lanes_drv "$L3C" TEST_MAX_JOBS_PER_HOST=1 -- "$LEASE_SNIP"
assert_eq "L3 live pid with hb older than TTL(600)+10: reclaimed" "0" "$(kv_of "$OUT" rc)"
case_ran L3

# ── L4 live, fresh lanes are never reclaimed: wait cap -> 4 ─────────────────
L4C="$TMPDIR_BASE/l4-cache"
mk_slot "$L4C" 1 "$LIVE_PID"; mk_slot "$L4C" 2 "$LIVE_PID"
lanes_drv "$L4C" TEST_MAX_JOBS_PER_HOST=2 -- "$LEASE_SNIP"
assert_eq "L4 every lane live and fresh: lease returns 4 at the cap" "4" "$(kv_of "$OUT" rc)"
if printf '%s' "$ERR" | grep -q 'test-lanes-status'; then
    pass "L4 the wait notice points at test-lanes-status"
else
    fail "L4 stderr lacks the test-lanes-status hint: $(printf '%q' "$ERR")"
fi
L4R="$(mk_repo)"; add_tf "$L4R" bin/a.sh "src/x.js"; commit_all "$L4R" c
run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$L4C" TEST_MAX_JOBS_PER_HOST=2 TEST_LANES_WAIT_INTERVAL=1 TEST_LANES_WAIT_CAP=3 -- --root "$L4R" --sources src/x.js
assert_eq "L4 find-tests CLI exits 4 when no lane frees" "4" "$RC"
assert_eq "L4 find-tests CLI prints nothing on stdout at exit 4" "" "$OUT"
if printf '%s' "$ERR" | grep -q 'no test lane freed within'; then
    pass "L4 find-tests CLI names the wait cap on stderr"
else
    fail "L4 find-tests CLI stderr lacks 'no test lane freed within': $(printf '%q' "$ERR")"
fi
[ -d "$L4C/slots/lane.1" ] && [ -d "$L4C/slots/lane.2" ] && pass "L4 the live lanes survived" || fail "L4 a live, fresh lane was reclaimed"
case_ran L4

# ── L5 another env: only the hb TTL counts ──────────────────────────────────
L5C="$TMPDIR_BASE/l5-cache"
mk_slot "$L5C" 1 "$(dead_pid)" other-env
lanes_drv "$L5C" TEST_MAX_JOBS_PER_HOST=1 -- "$LEASE_SNIP"
assert_eq "L5 other env, dead pid, fresh hb: not reclaimed (rc 4)" "4" "$(kv_of "$OUT" rc)"
rm -rf "$L5C/slots"
mk_slot "$L5C" 1 "$(dead_pid)" other-env run-all "$(( $(now_epoch) - 700 ))"
lanes_drv "$L5C" TEST_MAX_JOBS_PER_HOST=1 -- "$LEASE_SNIP"
assert_eq "L5 other env, stale hb: reclaimed (rc 0)" "0" "$(kv_of "$OUT" rc)"
case_ran L5

# ── L6 ownerless slot: time-based grace ─────────────────────────────────────
L6C="$TMPDIR_BASE/l6-cache"
mk_slot "$L6C" 1 ""
run_status "$L6C" TEST_MAX_JOBS_PER_HOST=1
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'ownerless'; then
    pass "L6 test-lanes-status reports the bare lane as ownerless"
else
    fail "L6 status CLI did not report ownerless — rc=$RC out=$(printf '%q' "$OUT")"
fi
lanes_drv "$L6C" TEST_MAX_JOBS_PER_HOST=1 TEST_LANES_WAIT_CAP=6 -- 's=$SECONDS; '"$LEASE_SNIP"'; echo "el=$((SECONDS - s))"'
assert_eq "L6 ownerless slot is reclaimed within the cap" "0" "$(kv_of "$OUT" rc)"
_el="$(kv_of "$OUT" el)"
if [[ "$_el" =~ ^[0-9]+$ ]] && [ "$_el" -ge 1 ]; then
    pass "L6 reclaim waited out the ownerless grace (elapsed ${_el}s >= 1)"
else
    fail "L6 ownerless slot reclaimed without the grace (elapsed=[$_el])"
fi
case_ran L6

# ── L7 nested holder takes no slot ──────────────────────────────────────────
L7C="$TMPDIR_BASE/l7-cache"
lanes_drv "$L7C" TEST_MAX_JOBS_PER_HOST=2 TEST_LANES_HELD=123 -- "$LEASE_SNIP"
assert_eq "L7 TEST_LANES_HELD=123: lease succeeds" "0" "$(kv_of "$OUT" rc)"
assert_eq "L7 TEST_LANES_HELD=123: no lane is created" "" "$(lane_names "$L7C")"
case_ran L7

# ── L8 TEST_LANES=off creates nothing ───────────────────────────────────────
L8C="$TMPDIR_BASE/l8-cache"
lanes_drv "$L8C" TEST_MAX_JOBS_PER_HOST=2 TEST_LANES=off -- "$LEASE_SNIP"
assert_eq "L8 TEST_LANES=off: lease succeeds" "0" "$(kv_of "$OUT" rc)"
[ ! -e "$L8C/slots" ] && pass "L8 TEST_LANES=off: no slots/ directory" || fail "L8 TEST_LANES=off still created slots/"
L8C2="$TMPDIR_BASE/l8-cache-cli"
run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$L8C2" TEST_LANES=off TEST_MAX_JOBS_PER_HOST=2 -- --root "$L4R" --sources src/x.js
[ "$RC" -eq 0 ] && [ ! -e "$L8C2/slots" ] && pass "L8 find-tests with TEST_LANES=off: rc 0, no slots/" || fail "L8 find-tests with TEST_LANES=off — rc=$RC slots=$([ -e "$L8C2/slots" ] && echo yes || echo no)"
case_ran L8

# ── L9 release never deletes a slot whose token is someone else's ───────────
L9C="$TMPDIR_BASE/l9-cache"
lanes_drv "$L9C" TEST_MAX_JOBS_PER_HOST=1 -- "$LEASE_SNIP"'
d="$THL_CACHE_ROOT/slots/lane.1"
[ -f "$d/owner" ] && sed "s/^token=.*/token=1.1.1/" "$d/owner" > "$d/owner.new" && mv -f "$d/owner.new" "$d/owner"
thl_release_all; [ -d "$d" ] && echo "survived=yes" || echo "survived=no"'
assert_eq "L9 lease precondition" "0" "$(kv_of "$OUT" rc)"
assert_eq "L9 a foreign-token slot survives thl_release_all" "yes" "$(kv_of "$OUT" survived)"
case_ran L9

# ── L10 find-tests scans from the top lane ──────────────────────────────────
L10C="$TMPDIR_BASE/l10-cache"
lanes_drv "$L10C" TEST_MAX_JOBS_PER_HOST=3 -- "$LEASE_SNIP"'; for d in "$THL_CACHE_ROOT"/slots/lane.*; do echo "lane=${d##*/}"; done'
assert_eq "L10 N=3: find-tests takes lane.3" "lane.3" "$(kv_of "$OUT" lane)"
case_ran L10

# ── L11 the heartbeat only refreshes a slot it still owns ───────────────────
L11C="$TMPDIR_BASE/l11-cache"
lanes_drv "$L11C" TEST_MAX_JOBS_PER_HOST=3 TEST_LANES_HEARTBEAT=1 -- 'thl_init_dir; thl_run_all_lease 2 0; echo "rc=$?"
d="$THL_CACHE_ROOT/slots/lane.1"
printf "1000\n" > "$d/hb"; sleep 3; echo "hb_own=$(cat "$d/hb")"
sed "s/^token=.*/token=1.1.1/" "$d/owner" > "$d/owner.new"; mv -f "$d/owner.new" "$d/owner"
printf "1000\n" > "$d/hb"; sleep 3; echo "hb_foreign=$(cat "$d/hb")"
thl_release_all'
assert_eq "L11 run-all lease precondition" "0" "$(kv_of "$OUT" rc)"
_hb="$(kv_of "$OUT" hb_own)"
if [[ "$_hb" =~ ^[0-9]+$ ]] && [ "$_hb" -gt 1000 ]; then
    pass "L11 positive control: the heartbeat refreshes an owned slot"
else
    fail "L11 heartbeat did not refresh an owned slot (hb=[$_hb])"
fi
assert_eq "L11 the heartbeat leaves a slot with a foreign token alone" "1000" "$(kv_of "$OUT" hb_foreign)"
case_ran L11

# ── L12 find-tests and run-all agree on max_jobs_per_host, per source ───────
L12T="$TMPDIR_BASE/l12-tests"
mkdir -p "$L12T"
for _i in 1 2 3; do printf '#!/usr/bin/env bash\n' > "$L12T/t$_i.sh"; done
L12_HID="$(bash -c '. "$1"; run_all_host_id' _ "$PAR_LIB")"
# The current OS attribute, from the real lib (empty while run_all_os_attr is absent).
L_OS_NOW="$(bash -c '. "$1"; command -v run_all_os_attr >/dev/null 2>&1 && run_all_os_attr' _ "$PAR_LIB")"
L12_SNIP='thl_max_jobs_per_host; echo "b=${THL_MAX_JOBS_PER_HOST-}/${THL_MAX_JOBS_PER_HOST_SOURCE-}"'
l12_conf() {  # l12_conf <cache> <max> [os] — a v2 measured record for this host
    mkdir -p "$1"
    printf 'schema=2\nhost_id=%s\nos=%s\nmax_jobs_per_host=%s\nmeasured_at=2026-01-01T00:00:00Z\nsample_size=3\nrepeat=1\n' \
        "$L12_HID" "${3:-$L_OS_NOW}" "$2" > "$1/parallelism.conf"
}
# dotenv_stub <name> <value> — sets DOTENV_STUB to a resolver that prints <value>
# for <name> only and leaves <stub>.called behind whenever it is launched.
DOTENV_N=0
dotenv_stub() {
    DOTENV_N=$((DOTENV_N + 1))
    DOTENV_STUB="$TMPDIR_BASE/dotenv-stub-$DOTENV_N.sh"
    printf '#!/usr/bin/env bash\n: > %q\nfor a in "$@"; do [ "$a" = %q ] && { printf "%%s\\n" %q; exit 0; }; done\nexit 0\n' \
        "$DOTENV_STUB.called" "$1" "$2" > "$DOTENV_STUB"
    chmod +x "$DOTENV_STUB"
}
l12_case() {  # l12_case <label> <cache> <want-N> <want-source> [NAME=VAL...]
    local label="$1" cache="$2" wn="$3" ws="$4"; shift 4
    local a b
    lanes_drv "$cache" "$@" -- "$L12_SNIP"
    a="$(kv_of "$OUT" b)"
    lanes_drv "$cache" "TESTS_DIR=$L12T" "$@" -- "$L12_SNIP"
    b="$(kv_of "$OUT" b)"
    assert_eq "L12 $label: find-tests side (no TESTS_DIR)" "$wn/$ws" "$a"
    assert_eq "L12 $label: run-all side (TESTS_DIR exported)" "$wn/$ws" "$b"
}
l12_conf "$TMPDIR_BASE/l12-b" 5
dotenv_stub TEST_MAX_JOBS_PER_HOST 6; L12_STUB_FIRST="$DOTENV_STUB"
l12_case "env 7 beats .env 6 and record 5" "$TMPDIR_BASE/l12-b" 7 env TEST_MAX_JOBS_PER_HOST=7 "RUN_ALL_CONFIG_VAR_CMD=$L12_STUB_FIRST"
[ ! -e "$L12_STUB_FIRST.called" ] && pass "L12 a valid env value launches no .env resolver" || fail "L12 the .env resolver was launched although the env value is valid"
l12_case "env" "$TMPDIR_BASE/l12-a" 7 env TEST_MAX_JOBS_PER_HOST=7
dotenv_stub TEST_MAX_JOBS_PER_HOST 6
l12_case ".env stub" "$TMPDIR_BASE/l12-e" 6 dotenv "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB"
[ -e "$DOTENV_STUB.called" ] && pass "L12 the .env resolver stub was launched (positive control)" || fail "L12 RUN_ALL_CONFIG_VAR_CMD stub never launched"
l12_case ".env 6 beats record 5" "$TMPDIR_BASE/l12-b" 6 dotenv "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB"
l12_case "v2 measured record" "$TMPDIR_BASE/l12-b" 5 measured
l12_case "no record" "$TMPDIR_BASE/l12-d" 4 default
case_ran L12

# ── L13 the find-tests CLI releases its lane on every exit path ─────────────
L13C="$TMPDIR_BASE/l13-cache"
run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$L13C" TEST_MAX_JOBS_PER_HOST=2 -- --root "$L4R" --sources src/x.js
assert_eq "L13 rc0 path: find-tests exits 0" "0" "$RC"
[ -d "$L13C/slots" ] && pass "L13 rc0 path: slots/ exists (a lane was leased)" || fail "L13 rc0 path: no slots/ — the CLI never leased a lane"
assert_eq "L13 rc0 path: no lane.* left after exit" "" "$(lane_names "$L13C")"
assert_eq "L13 rc0 path: no .grave.* left after exit" "0" "$(grave_count "$L13C")"

L13F="$TMPDIR_BASE/l13-full-cache"
mk_slot "$L13F" 1 "$LIVE_PID" "$OSTYPE" run-all "" "1.1.11"
mk_slot "$L13F" 2 "$LIVE_PID" "$OSTYPE" run-all "" "1.1.12"
run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$L13F" TEST_MAX_JOBS_PER_HOST=2 TEST_LANES_WAIT_INTERVAL=1 TEST_LANES_WAIT_CAP=2 -- --root "$L4R" --sources src/x.js
assert_eq "L13 exit-4 path: find-tests exits 4" "4" "$RC"
assert_eq "L13 exit-4 path: only the two pre-held entries remain under slots/" "2" "$(slot_entries "$L13F")"
assert_eq "L13 exit-4 path: lane.1 still carries its holder's token" "1.1.11" "$(owner_token "$L13F" 1)"
assert_eq "L13 exit-4 path: lane.2 still carries its holder's token" "1.1.12" "$(owner_token "$L13F" 2)"

# INT path: a git shim parks the CLI inside the corpus-key `git status` (after the
# lease), so the interrupt lands while a lane is held.
L13G="$TMPDIR_BASE/l13-slowgit"
L13I="$TMPDIR_BASE/l13-int-cache"
mkdir -p "$L13G"
printf '#!%s\nfor a in "$@"; do [ "$a" = status ] && { : > %q; exec sleep 30; }; done\nexec %q "$@"\n' \
    "$(type -P bash)" "$L13G/ready" "$(type -P git)" > "$L13G/git"
chmod +x "$L13G/git"
set -m
(
    cd "$NEUTRAL_DIR" || exit 2
    exec env "PATH=$L13G:$PATH" "RUN_ALL_CACHE_DIR=$L13I" TEST_MAX_JOBS_PER_HOST=2 \
        bash "$HELPER" --root "$L4R" --sources src/x.js
) >"$TMPDIR_BASE/l13-int.out" 2>"$TMPDIR_BASE/l13-int.err" </dev/null &
L13_BG=$!
set +m
_w=0
while [ ! -e "$L13G/ready" ] && [ "$_w" -lt 20 ] && kill -0 "$L13_BG" 2>/dev/null; do sleep 1; _w=$((_w + 1)); done
if [ -e "$L13G/ready" ]; then
    [ -n "$(lane_names "$L13I")" ] && pass "L13 INT path: a lane is held while the CLI runs (positive control)" || fail "L13 INT path: no lane held while the CLI runs"
    kill -INT -- "-$L13_BG" 2>/dev/null || kill -INT "$L13_BG" 2>/dev/null
    _w=0
    while kill -0 "$L13_BG" 2>/dev/null && [ "$_w" -lt 20 ]; do sleep 1; _w=$((_w + 1)); done
    kill -KILL -- "-$L13_BG" 2>/dev/null
    wait "$L13_BG" 2>/dev/null; _rc=$?
    assert_eq "L13 INT path: find-tests exits 130" "130" "$_rc"
    assert_eq "L13 INT path: no lane.* left after the interrupt" "" "$(lane_names "$L13I")"
    assert_eq "L13 INT path: no .grave.* left after the interrupt" "0" "$(grave_count "$L13I")"
else
    kill -KILL -- "-$L13_BG" 2>/dev/null || kill -KILL "$L13_BG" 2>/dev/null
    wait "$L13_BG" 2>/dev/null
    fail "L13 INT path: the CLI never reached the corpus-key git status while holding a lane (not implemented)"
fi
case_ran L13

# ── L14 an invalid limit skips its layer with one fixed notice ──────────────
L14N="$TMPDIR_BASE/l14-nocache"
L14K="$TMPDIR_BASE/l14-cal"
L14M="$TMPDIR_BASE/l14-pwned"
l12_conf "$L14K" 5
L14_RUNALL='thl_init_dir; thl_run_all_lease 2 0; echo "rc=$?"; thl_release_all'
# l14_notice <label> <raw-value> <want-lines> — stderr carries exactly <want-lines>
# notice lines, none of which echoes a raw value of 3+ characters back.
l14_notice() {
    local n
    n="$(printf '%s\n' "$ERR" | grep -c . || true)"
    if ! no_shell_error "$ERR"; then
        fail "L14 $1: shell error instead of a notice: $(printf '%q' "$ERR")"
    elif [ "$n" != "$3" ]; then
        fail "L14 $1: want $3 notice line(s) on stderr, got $n: $(printf '%q' "$ERR")"
    elif [ "$3" = 1 ] && [ "${#2}" -ge 3 ] && printf '%s' "$ERR" | grep -qF -- "$2"; then
        fail "L14 $1: the notice echoes the raw value: $(printf '%q' "$ERR")"
    else
        pass "L14 $1: $3 fixed notice line(s) on stderr"
    fi
}
while IFS='|' read -r _var _val _cache _want _nl; do
    [ -n "$_var" ] || continue
    if [ "$_var" = "TEST_MAX_JOBS_PER_HOST" ]; then
        lanes_drv "$_cache" "$_var=$_val" -- "$L12_SNIP" </dev/null
        assert_eq "L14 $_var=$_val: resolves to $_want" "$_want" "$(kv_of "$OUT" b)"
        l14_notice "$_var=$_val" "$_val" "$_nl"
    elif [ "$_var" = "DOTENV" ]; then
        dotenv_stub TEST_MAX_JOBS_PER_HOST "$_val"
        lanes_drv "$_cache" "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB" -- "$L12_SNIP" </dev/null
        assert_eq "L14 .env TEST_MAX_JOBS_PER_HOST=$(printf '%q' "$_val"): resolves to $_want" "$_want" "$(kv_of "$OUT" b)"
        l14_notice ".env value $(printf '%q' "$_val")" "$_val" "$_nl"
    else
        rm -rf "$_cache/slots"
        _snip="$LEASE_SNIP"'; thl_release_all'
        [ "$_var" = "TEST_LANES_HEARTBEAT" ] && _snip="$L14_RUNALL"
        lanes_drv "$_cache" TEST_MAX_JOBS_PER_HOST=2 "$_var=$_val" -- "$_snip" </dev/null
        assert_eq "L14 $_var=$_val: the lease does not abort (rc 0)" "0" "$(kv_of "$OUT" rc)"
    fi
    no_shell_error "$ERR" && pass "L14 $_var=$_val: no shell evaluation error" || fail "L14 $_var=$_val: shell error on stderr: $(printf '%q' "$ERR")"
done <<L14ROWS
TEST_MAX_JOBS_PER_HOST|0|$L14N|4/default|1
TEST_MAX_JOBS_PER_HOST|abc|$L14N|4/default|1
TEST_MAX_JOBS_PER_HOST|-1|$L14N|4/default|1
TEST_MAX_JOBS_PER_HOST|1025|$L14N|4/default|1
TEST_MAX_JOBS_PER_HOST|0|$L14K|5/measured|1
TEST_MAX_JOBS_PER_HOST|abc|$L14K|5/measured|1
TEST_MAX_JOBS_PER_HOST|-1|$L14K|5/measured|1
TEST_MAX_JOBS_PER_HOST|1025|$L14K|5/measured|1
TEST_MAX_JOBS_PER_HOST|1|$L14K|1/env|0
TEST_MAX_JOBS_PER_HOST|1024|$L14N|1024/env|0
DOTENV|abc|$L14K|5/measured|1
DOTENV|0|$L14K|5/measured|1
DOTENV|1025|$L14N|4/default|1
DOTENV|\$(touch $L14M)|$L14K|5/measured|1
DOTENV|1024|$L14N|1024/dotenv|0
TEST_LANES_WAIT_CAP|abc|$L14N|-|-
TEST_LANES_WAIT_INTERVAL|abc|$L14N|-|-
TEST_LANES_TTL|abc|$L14N|-|-
TEST_LANES_HEARTBEAT|abc|$L14N|-|-
L14ROWS
[ ! -e "$L14M" ] && pass "L14 a .env payload is data, never evaluated (marker absent)" || fail "L14 a .env value was evaluated as code"
case_ran L14

# ── L15 thl_run_all_lease honours TEST_LANES=off and a nested holder ────────
for _mode in "TEST_LANES=off" "TEST_LANES_HELD=123"; do
    _c="$TMPDIR_BASE/l15-cache-${_mode%%=*}"
    lanes_drv "$_c" TEST_MAX_JOBS_PER_HOST=3 "$_mode" -- 'thl_init_dir; thl_run_all_lease 8 0; echo "rc=$?"; echo "granted=${THL_GRANTED:-unset}"; echo "held=${TEST_LANES_HELD-unset}"; echo "note=${THL_NOTE-}"'
    assert_eq "L15 $_mode: thl_run_all_lease returns 0" "0" "$(kv_of "$OUT" rc)"
    if [ "$_mode" = "TEST_LANES=off" ]; then _why="TEST_LANES=off"; else _why="nested under a lane holder"; fi
    assert_eq "L15 $_mode: THL_NOTE names why the limit is not applied" "not applied ($_why); jobs 8 as requested" "$(kv_of "$OUT" note)"
    [ ! -e "$_c/slots" ] && pass "L15 $_mode: no slots/ directory" || fail "L15 $_mode: slots/ was created ($(lane_names "$_c"))"
    case "$(kv_of "$OUT" granted)" in
        unset|8) pass "L15 $_mode: -j is not truncated (granted=$(kv_of "$OUT" granted))" ;;
        *) fail "L15 $_mode: the grant truncates -j 8 (granted=$(kv_of "$OUT" granted))" ;;
    esac
done
assert_eq "L15 TEST_LANES_HELD=123: the nested marker is left untouched" "123" "$(kv_of "$OUT" held)"
case_ran L15

# ── L16 released heartbeat is really stopped (token-matched probe) ──────────
L16C="$TMPDIR_BASE/l16-cache"
lanes_drv "$L16C" TEST_MAX_JOBS_PER_HOST=3 TEST_LANES_HEARTBEAT=1 -- 'thl_init_dir; thl_run_all_lease 2 0; echo "rc=$?"
d="$THL_CACHE_ROOT/slots/lane.1"
printf "1000\n" > "$d/hb"; sleep 3; echo "hb_live=$(cat "$d/hb")"
cp "$d/owner" "$THL_CACHE_ROOT/owner.save"
thl_release_all
mkdir -p "$d"; cp "$THL_CACHE_ROOT/owner.save" "$d/owner"; printf "1000\n" > "$d/hb"
sleep 3; echo "hb_after=$(cat "$d/hb")"; rm -rf "$d"'
assert_eq "L16 run-all lease precondition" "0" "$(kv_of "$OUT" rc)"
_hb="$(kv_of "$OUT" hb_live)"
[[ "$_hb" =~ ^[0-9]+$ ]] && [ "$_hb" -gt 1000 ] && pass "L16 positive control: the heartbeat refreshes a held lane" || fail "L16 heartbeat never refreshed the held lane (hb=[$_hb])"
assert_eq "L16 after thl_release_all a lane re-created with the SAME token keeps hb=1000" "1000" "$(kv_of "$OUT" hb_after)"
case_ran L16

# ── L17 a reclaimed lane carries the new holder's token, no grave left ──────
L17C="$TMPDIR_BASE/l17-cache"
mk_slot "$L17C" 1 "$(dead_pid)" "$OSTYPE" run-all "" "9.9.9"
lanes_drv "$L17C" TEST_MAX_JOBS_PER_HOST=1 -- "$LEASE_SNIP"'
echo "tok=$(sed -n "s/^token=//p" "$THL_CACHE_ROOT/slots/lane.1/owner" 2>/dev/null)"; echo "mytok=${THL_TOKEN-}"
g=0; for d in "$THL_CACHE_ROOT"/slots/.grave.*; do [ -e "$d" ] && g=$((g+1)); done; echo "graves=$g"
thl_release_all'
assert_eq "L17 dead holder reclaimed (rc 0)" "0" "$(kv_of "$OUT" rc)"
_tok="$(kv_of "$OUT" tok)"
if [ -n "$_tok" ] && [ "$_tok" != "9.9.9" ] && [ "$_tok" = "$(kv_of "$OUT" mytok)" ] && [ "${_tok%%.*}" = "$(kv_of "$OUT" drvpid)" ]; then
    pass "L17 lane.1 owner token is the new holder's ($_tok)"
else
    fail "L17 lane.1 owner token not rewritten — tok=[$_tok] THL_TOKEN=[$(kv_of "$OUT" mytok)] drvpid=[$(kv_of "$OUT" drvpid)]"
fi
assert_eq "L17 no slots/.grave.* left after the reclaim" "0" "$(kv_of "$OUT" graves)"
case_ran L17

# ── L18 malformed owner/hb fields are data, never code ──────────────────────
L18C="$TMPDIR_BASE/l18-cache"
L18M="$TMPDIR_BASE/l18-pwned"
mk_slot "$L18C" 1 "$LIVE_PID"; printf 'abc\n' > "$L18C/slots/lane.1/hb"
mk_slot "$L18C" 2 "$LIVE_PID"; printf 'a[$(touch %s)]\n' "$L18M" > "$L18C/slots/lane.2/hb"
mkdir -p "$L18C/slots/lane.3"
printf 'pid=a[$(touch %s)]\nenv=%s\nkind=run-all\nstart=a[$(touch %s)]\ntoken=x\n' "$L18M" "$OSTYPE" "$L18M" > "$L18C/slots/lane.3/owner"
printf 'a[$(touch %s)]\n' "$L18M" > "$L18C/slots/lane.3/hb"
mkdir -p "$L18C/slots/lane.4"; : > "$L18C/slots/lane.4/owner"
run_status "$L18C" TEST_MAX_JOBS_PER_HOST=4
assert_eq "L18 test-lanes-status survives malformed owners (exit 0)" "0" "$RC"
no_shell_error "$ERR" && pass "L18 status: no shell evaluation error" || fail "L18 status stderr: $(printf '%q' "$ERR")"
lanes_drv "$L18C" TEST_MAX_JOBS_PER_HOST=4 TEST_LANES_WAIT_CAP=2 -- "$LEASE_SNIP"'; thl_release_all'
case "$(kv_of "$OUT" rc)" in
    0|4) pass "L18 lease completes on malformed owners (rc $(kv_of "$OUT" rc))" ;;
    *) fail "L18 lease crashed on malformed owners — drv rc=$RC lease rc=[$(kv_of "$OUT" rc)] err=$(printf '%q' "$ERR")" ;;
esac
no_shell_error "$ERR" && pass "L18 lease: no shell evaluation error" || fail "L18 lease stderr: $(printf '%q' "$ERR")"
[ ! -e "$L18M" ] && pass "L18 no owner/hb payload was evaluated (marker absent)" || fail "L18 a malformed owner/hb field was evaluated as code"
case_ran L18

case_end

case_begin "lanes-status-cli" "bin/test-lanes-status.sh"

# ── LS1 empty ───────────────────────────────────────────────────────────────
run_status "$TMPDIR_BASE/ls1-cache" TEST_MAX_JOBS_PER_HOST=2
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'no test lanes held'; then
    pass "LS1 no slots: 'no test lanes held', exit 0"
else
    fail "LS1 empty status — rc=$RC out=$(printf '%q' "$OUT")"
fi
first_line() { printf '%s\n' "$1" | head -n 1; }
assert_eq "LS1 env source: first line" "max_jobs_per_host=2 source=env" "$(first_line "$OUT")"
run_status "$TMPDIR_BASE/ls1-default"
assert_eq "LS1 no record: first line names the default and the record's reason" \
    "max_jobs_per_host=4 source=default record=missing" "$(first_line "$OUT")"
dotenv_stub TEST_MAX_JOBS_PER_HOST 3
run_status "$TMPDIR_BASE/ls1-dotenv" "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB"
assert_eq "LS1 .env source: first line" "max_jobs_per_host=3 source=dotenv" "$(first_line "$OUT")"
case_ran LS1

# ── LS2 every state, read-only ──────────────────────────────────────────────
LS2C="$TMPDIR_BASE/ls2-cache"
mk_slot "$LS2C" 1 "$LIVE_PID"
mk_slot "$LS2C" 2 "$(dead_pid)"
mk_slot "$LS2C" 3 "$LIVE_PID" "$OSTYPE" run-all "$(( $(now_epoch) - 700 ))"
mk_slot "$LS2C" 4 "$(dead_pid)" other-env
mk_slot "$LS2C" 5 ""
run_status "$LS2C" TEST_MAX_JOBS_PER_HOST=5
assert_eq "LS2 status exits 0" "0" "$RC"
assert_eq "LS2 first line is max_jobs_per_host=<N> source=<...>" "max_jobs_per_host=5 source=env" "$(first_line "$OUT")"
_i=0
for _st in alive stale-dead-pid stale-ttl foreign ownerless; do
    _i=$((_i + 1))
    if printf '%s\n' "$OUT" | grep -qE "^(lane\.)?$_i"$'\t'".*"$'\t'"$_st\$"; then
        pass "LS2 lane $_i reported as $_st"
    else
        fail "LS2 lane $_i not reported as $_st — out=$(printf '%q' "$OUT")"
    fi
done
assert_eq "LS2 status is read-only (all five lanes still present)" "lane.1 lane.2 lane.3 lane.4 lane.5" "$(lane_names "$LS2C")"
run_status "$LS2C" -- --bogus
assert_eq "LS2 --bogus is a usage error (exit 2)" "2" "$RC"
case_ran LS2

# ── LS3 allow-listed and executable ─────────────────────────────────────────
grep -qxF 'bin/test-lanes-status.sh' "$ALLOW_TXT" && pass "LS3 install/settings-allow-commands.txt lists bin/test-lanes-status.sh" || fail "LS3 bin/test-lanes-status.sh missing from the allow list"
_mode="$(git -C "$AGENTS_ROOT" ls-files -s -- bin/test-lanes-status.sh 2>/dev/null | cut -d' ' -f1)"
if [ "$_mode" = "100755" ] || { [ -z "$_mode" ] && [ -x "$STATUS_CLI" ] && [ -f "$STATUS_CLI" ]; }; then
    pass "LS3 bin/test-lanes-status.sh is executable (mode=${_mode:-worktree -x})"
else
    fail "LS3 bin/test-lanes-status.sh is not executable (index mode=[${_mode}] exists=$([ -f "$STATUS_CLI" ] && echo yes || echo no))"
fi
case_ran LS3

# ── LS4 -h / --help is a successful usage print, not a usage error ──────────
for _h in -h --help; do
    run_status "$TMPDIR_BASE/ls4-cache" -- "$_h"
    assert_eq "LS4 bin/test-lanes-status.sh $_h exits 0" "0" "$RC"
done
[ ! -e "$TMPDIR_BASE/ls4-cache/slots" ] && pass "LS4 --help creates no slots/" || fail "LS4 --help created slots/"
case_ran LS4

# ── LS5 a record measured on another OS version keeps its value and advises ─
if [[ "$L_OS_NOW" =~ ^[A-Za-z0-9._-]{1,32}/[A-Za-z0-9._-]{1,64}$ ]]; then
    pass "LS5 precondition: run_all_os_attr yields <kind>/<version> ($L_OS_NOW)"
else
    fail "LS5 precondition: run_all_os_attr missing or malformed [$L_OS_NOW]"
fi
LS5_KIND="${L_OS_NOW%%/*}"; [ -n "$LS5_KIND" ] || LS5_KIND="Unknown"
LS5_OLD="$LS5_KIND/0.0.0-ls5"
LS5_ADVICE="measured on $LS5_OLD, now $L_OS_NOW; re-run bin/calibrate-test-parallelism.sh"
LS5_LEASE='thl_init_dir; thl_run_all_lease 2 0; echo "rc=$?"; echo "b=${THL_MAX_JOBS_PER_HOST-}/${THL_MAX_JOBS_PER_HOST_SOURCE-}"; echo "note=${THL_NOTE-}"; thl_release_all'
LS5D="$TMPDIR_BASE/ls5-diff"
l12_conf "$LS5D" 5 "$LS5_OLD"
run_status "$LS5D"
assert_eq "LS5 os differs: status first line keeps the record and names both versions" \
    "max_jobs_per_host=5 source=measured measured_on=$LS5_OLD now=$L_OS_NOW" "$(first_line "$OUT")"
lanes_drv "$LS5D" -- "$LS5_LEASE"
assert_eq "LS5 os differs: the lease succeeds" "0" "$(kv_of "$OUT" rc)"
assert_eq "LS5 os differs: the limit is the record's value, not invalidated" "5/measured" "$(kv_of "$OUT" b)"
_note="$(kv_of "$OUT" note)"
case "$_note" in
    "jobs 2 of requested 2 (max jobs per host 5, source measured; lanes "*"; $LS5_ADVICE"*)
        pass "LS5 os differs: the lanes: note carries the advice" ;;
    *) fail "LS5 os differs: lanes: note lacks the grant or the advice — note=$(printf '%q' "$_note")" ;;
esac
LS5S="$TMPDIR_BASE/ls5-same"
l12_conf "$LS5S" 5
run_status "$LS5S"
assert_eq "LS5 same os: status first line carries no measured_on/now" "max_jobs_per_host=5 source=measured" "$(first_line "$OUT")"
lanes_drv "$LS5S" -- "$LS5_LEASE"
assert_eq "LS5 same os: the limit is the record's value" "5/measured" "$(kv_of "$OUT" b)"
_note="$(kv_of "$OUT" note)"
case "$_note" in
    *"measured on"*|"") fail "LS5 same os: note missing or carries an advice — note=$(printf '%q' "$_note")" ;;
    "jobs 2 of requested 2 (max jobs per host 5, source measured; lanes 1 2)") pass "LS5 same os: the lanes: note has no advice" ;;
    *) fail "LS5 same os: unexpected note format — note=$(printf '%q' "$_note")" ;;
esac
lanes_drv "$TMPDIR_BASE/ls5-none" -- "$LS5_LEASE"
_note="$(kv_of "$OUT" note)"
case "$_note" in
    "jobs 2 of requested 2 (max jobs per host 4, source default"*missing*calibrate-test-parallelism*)
        pass "LS5 default source: the lanes: note names the record reason and the calibrator" ;;
    *) fail "LS5 default source: note lacks the reason token or the calibrator — note=$(printf '%q' "$_note")" ;;
esac
case_ran LS5

case_end

grp_done lanes-cases.sh
