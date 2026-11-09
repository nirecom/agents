#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/lanes-cases.sh — L1-L13.
# Drives bin/lib/test-host-lanes.sh through its public API (lanes_drv) and the
# find-tests CLI. Every wait is shortened to interval 1s / cap 3s unless stated.
# Relies on _lanes-fixture.sh (LIVE_PID, LEASE_SNIP, L12_SNIP, l12_conf, dotenv_stub).

case_begin "host-lanes" "bin/lib/test-host-lanes.sh"

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
lanes_drv "$L11C" TEST_MAX_JOBS_PER_HOST=3 TEST_LANES_HEARTBEAT=1 -- "$HB_WAIT_FN"'
thl_init_dir; thl_run_all_lease 2 0; echo "rc=$?"
d="$THL_CACHE_ROOT/slots/lane.1"
printf "1000\n" > "$d/hb"; hb_wait_refresh "$d/hb" 3; echo "hb_own=$(cat "$d/hb")"
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
# Pin-over-record ordering is the AUTO_CONFIG_TEST_MAX_JOBS=off contract (pins only, the
# record unread); the on-mode min(pin, base) rows live in auto-config-cases.sh (AC3).
L12_OFF=AUTO_CONFIG_TEST_MAX_JOBS=off
l12_conf "$TMPDIR_BASE/l12-b" 5
dotenv_stub TEST_MAX_JOBS_PER_HOST 6; L12_STUB_FIRST="$DOTENV_STUB"
l12_case "off: env 7 beats .env 6 and record 5" "$TMPDIR_BASE/l12-b" 7 env "$L12_OFF" TEST_MAX_JOBS_PER_HOST=7 "RUN_ALL_CONFIG_VAR_CMD=$L12_STUB_FIRST"
[ ! -e "$L12_STUB_FIRST.called" ] && pass "L12 valid env values launch no .env resolver" || fail "L12 the .env resolver was launched although the env values are valid"
l12_case "off: env" "$TMPDIR_BASE/l12-a" 7 env "$L12_OFF" TEST_MAX_JOBS_PER_HOST=7
dotenv_stub TEST_MAX_JOBS_PER_HOST 6
l12_case "off: .env stub" "$TMPDIR_BASE/l12-e" 6 dotenv "$L12_OFF" "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB"
[ -e "$DOTENV_STUB.called" ] && pass "L12 the .env resolver stub was launched (positive control)" || fail "L12 RUN_ALL_CONFIG_VAR_CMD stub never launched"
l12_case "off: .env 6 beats record 5" "$TMPDIR_BASE/l12-b" 6 dotenv "$L12_OFF" "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB"
l12_case "on (default): schema-3 measured record" "$TMPDIR_BASE/l12-b" 5 measured
l12_case "on (default): no record" "$TMPDIR_BASE/l12-d" 4 default
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
# 0.2 s polls, 100 of them: the same 20 s cap as before.
_w=0
while [ ! -e "$L13G/ready" ] && [ "$_w" -lt 100 ] && kill -0 "$L13_BG" 2>/dev/null; do sleep 0.2; _w=$((_w + 1)); done
if [ -e "$L13G/ready" ]; then
    [ -n "$(lane_names "$L13I")" ] && pass "L13 INT path: a lane is held while the CLI runs (positive control)" || fail "L13 INT path: no lane held while the CLI runs"
    kill -INT -- "-$L13_BG" 2>/dev/null || kill -INT "$L13_BG" 2>/dev/null
    _w=0
    while kill -0 "$L13_BG" 2>/dev/null && [ "$_w" -lt 100 ]; do sleep 0.2; _w=$((_w + 1)); done
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

case_end

grp_done lanes-cases.sh
