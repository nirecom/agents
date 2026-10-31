#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-load/probe-cases.sh — PB1-PB9: the node host lines of
# _thl_load_probe_host. Arguments override what node reports (values in bytes, `absent` = the
# API is missing): platform= availableMemory= constrainedMemory= freemem= totalmem=. With no
# argument it reports the real host. Needs node; without it every case but PB5 (source text) is skipped.
# PB10-PB12 (no node needed): the probe timeout of _thl_load_snapshot, clamped to one heartbeat.

GIB=1073741824
PB_NODE=0
command -v node >/dev/null 2>&1 && PB_NODE=1
# pb <args...> — OUT holds the host lines for those overrides, plus fn=<0|1>.
pb() {
    load_drv "$(new_cache)" "$CD" "PB_ARGS=$*" -- \
        'declare -F _thl_load_probe_host >/dev/null && echo fn=1 || echo fn=0; _thl_load_probe_host $PB_ARGS'
}
# pb_base — 16 GiB host, 4 GiB available, 6 GiB free (the host-wide figure).
pb_base() { printf 'platform=linux totalmem=%s freemem=%s availableMemory=%s' "$((16 * GIB))" "$((6 * GIB))" "$((4 * GIB))"; }
pb_skip() { skip "$1 node absent: _thl_load_probe_host prints no host line on this host"; }

case_begin "probe-node-scope" "bin/lib/test-host-load-probe.sh"
# ── PB1 constrainedMemory decides the scope: 0 / below total / at or above ──
if [ "$PB_NODE" = 1 ]; then
    pb $(pb_base) constrainedMemory=0
    assert_eq "PB1 _thl_load_probe_host is defined" "1" "$(kv_of "$OUT" fn)"
    assert_eq "PB1 constrained 0: scope host" "host" "$(kv_of "$OUT" host_mem_scope)"
    assert_eq "PB1 constrained 0: total is totalmem" "16777216" "$(kv_of "$OUT" host_mem_total_kb)"
    assert_eq "PB1 constrained 0: avail is availableMemory" "4194304" "$(kv_of "$OUT" host_mem_avail_kb)"
    pb $(pb_base) constrainedMemory=$((8 * GIB))
    assert_eq "PB1 constrained 8 GiB < total: scope cgroup" "cgroup" "$(kv_of "$OUT" host_mem_scope)"
    assert_eq "PB1 constrained 8 GiB: total is the limit" "8388608" "$(kv_of "$OUT" host_mem_total_kb)"
    pb $(pb_base) constrainedMemory=$((32 * GIB))
    assert_eq "PB1 constrained above total (no limit): scope host" "host" "$(kv_of "$OUT" host_mem_scope)"
    assert_eq "PB1 constrained above total: total is totalmem" "16777216" "$(kv_of "$OUT" host_mem_total_kb)"
else
    pb_skip PB1
fi
case_ran PB1

# ── PB2 avail is capped at the total ────────────────────────────────────────
if [ "$PB_NODE" = 1 ]; then
    pb platform=linux totalmem=$((16 * GIB)) freemem=$GIB availableMemory=$((12 * GIB)) constrainedMemory=$((8 * GIB))
    assert_eq "PB2 12 GiB available under an 8 GiB limit: avail = 8 GiB" "8388608" "$(kv_of "$OUT" host_mem_avail_kb)"
else
    pb_skip PB2
fi
case_ran PB2
case_end

case_begin "probe-node-missing-api" "bin/lib/test-host-load-probe.sh"
# ── PB3 a missing API falls back without mixing scopes ──────────────────────
if [ "$PB_NODE" = 1 ]; then
    pb $(pb_base) constrainedMemory=absent
    assert_eq "PB3 constrainedMemory missing: avail falls to freemem" "6291456" "$(kv_of "$OUT" host_mem_avail_kb)"
    assert_eq "PB3 constrainedMemory missing: scope host" "host" "$(kv_of "$OUT" host_mem_scope)"
    pb platform=linux totalmem=$((16 * GIB)) freemem=$((6 * GIB)) availableMemory=absent constrainedMemory=absent
    assert_eq "PB3 linux, availableMemory missing: avail is freemem" "6291456" "$(kv_of "$OUT" host_mem_avail_kb)"
    pb platform=darwin totalmem=$((16 * GIB)) freemem=$((6 * GIB)) availableMemory=absent constrainedMemory=absent
    assert_eq "PB3 darwin positive control: the host total is still printed" "16777216" "$(kv_of "$OUT" host_mem_total_kb)"
    assert_eq "PB3 darwin, availableMemory missing: no host_mem_avail_kb line" "0" "$(printf '%s\n' "$OUT" | grep -c '^host_mem_avail_kb=')"
else
    pb_skip PB3
fi
case_ran PB3
case_end

case_begin "probe-node-real" "bin/lib/test-host-load-probe.sh"
# ── PB4 the real host: integer CPU lines (a carriage return breaks the match) ─
if [ "$PB_NODE" = 1 ]; then
    pb
    assert_eq "PB4 one host_busy_ms=<integer> line" "1" "$(printf '%s\n' "$OUT" | grep -cE '^host_busy_ms=[0-9]+$')"
    assert_eq "PB4 one host_cpus=<integer> line" "1" "$(printf '%s\n' "$OUT" | grep -cE '^host_cpus=[0-9]+$')"
    assert_eq "PB4 one host_mem_scope line" "1" "$(printf '%s\n' "$OUT" | grep -cE '^host_mem_scope=(host|cgroup)$')"
else
    pb_skip PB4
fi
case_ran PB4
case_end

case_begin "probe-node-available-memory" "bin/lib/test-host-load-probe.sh"
# ── PB5 the node program reads process.availableMemory (os has none) ────────
PB_BODY="$(sed -n '/^_thl_load_probe_host() {/,/^}/p' "$PROBE_LIB")"
assert_eq "PB5 positive control: the function body was found" "1" "$(printf '%s\n' "$PB_BODY" | grep -c '^_thl_load_probe_host() {')"
assert_eq "PB5 the program calls process.availableMemory" "1" "$([ "$(printf '%s\n' "$PB_BODY" | grep -c 'process\.availableMemory')" -ge 1 ] && echo 1 || echo 0)"
assert_eq "PB5 the program never reads os.availableMemory" "0" "$(printf '%s\n' "$PB_BODY" | grep -c 'os\.availableMemory')"
case_ran PB5

# ── PB6 a cgroup limit with both APIs finite: avail is availableMemory, not freemem ─
if [ "$PB_NODE" = 1 ]; then
    pb platform=linux totalmem=$((16 * GIB)) freemem=$((10 * GIB)) availableMemory=$((3 * GIB)) constrainedMemory=$((8 * GIB))
    assert_eq "PB6 cgroup: scope" "cgroup" "$(kv_of "$OUT" host_mem_scope)"
    assert_eq "PB6 cgroup: avail is availableMemory 3 GiB (freemem is 10 GiB)" "3145728" "$(kv_of "$OUT" host_mem_avail_kb)"
else
    pb_skip PB6
fi
case_ran PB6

# ── PB7 the real node: with freemem forced tiny, avail follows process.availableMemory ─
PB_REF=""
if [ "$PB_NODE" = 1 ]; then
    PB_REF="$(node -e 'const os = require("os"); console.log(typeof process.availableMemory === "function" ? Math.floor(Math.min(process.availableMemory(), os.totalmem()) / 1024) : "absent")' 2>/dev/null | tr -d '\r')"
fi
if [ "$PB_NODE" != 1 ]; then
    pb_skip PB7
elif ! [[ $PB_REF =~ ^[0-9]+$ ]]; then
    skip "PB7 this node has no process.availableMemory (ref=$PB_REF)"
else
    pb freemem=1024 constrainedMemory=0
    PB_GOT="$(kv_of "$OUT" host_mem_avail_kb)"
    PB_TOL=$((PB_REF / 10)); [ "$PB_TOL" -ge 262144 ] || PB_TOL=262144
    PB_DIFF=$(( ${PB_GOT:-0} - PB_REF )); [ "$PB_DIFF" -ge 0 ] || PB_DIFF=$((-PB_DIFF))
    if [[ $PB_GOT =~ ^[0-9]+$ ]] && [ "$PB_DIFF" -le "$PB_TOL" ]; then
        pass "PB7 host_mem_avail_kb $PB_GOT within $PB_TOL kB of process.availableMemory $PB_REF"
    else
        fail "PB7 host_mem_avail_kb follows process.availableMemory" "ref=$PB_REF got=${PB_GOT:-none} tol=$PB_TOL"
    fi
fi
case_ran PB7
case_end

case_begin "probe-node-missing-available-under-limit" "bin/lib/test-host-load-probe.sh"
# ── PB8 a finite cgroup limit but no availableMemory: detail §4 "no availableMemory" ─
# The cgroup free amount cannot be read, so host freemem never pairs with the cgroup scope:
# Linux and Windows fall to freemem with totalmem and scope host; darwin prints no avail.
if [ "$PB_NODE" = 1 ]; then
    for _pl in linux win32; do
        pb platform=$_pl totalmem=$((16 * GIB)) freemem=$((6 * GIB)) availableMemory=absent constrainedMemory=$((8 * GIB))
        assert_eq "PB8 $_pl: scope host, not cgroup" "host" "$(kv_of "$OUT" host_mem_scope)"
        assert_eq "PB8 $_pl: total is totalmem 16 GiB, not the 8 GiB limit" "16777216" "$(kv_of "$OUT" host_mem_total_kb)"
        assert_eq "PB8 $_pl: avail is the host freemem 6 GiB" "6291456" "$(kv_of "$OUT" host_mem_avail_kb)"
    done
    pb platform=darwin totalmem=$((16 * GIB)) freemem=$((6 * GIB)) availableMemory=absent constrainedMemory=$((8 * GIB))
    assert_eq "PB8 darwin: no host_mem_avail_kb line" "0" "$(printf '%s\n' "$OUT" | grep -c '^host_mem_avail_kb=')"
    assert_eq "PB8 darwin: scope host" "host" "$(kv_of "$OUT" host_mem_scope)"
    assert_eq "PB8 darwin: total is totalmem 16 GiB" "16777216" "$(kv_of "$OUT" host_mem_total_kb)"
else
    pb_skip PB8
fi
case_ran PB8
case_end

case_begin "probe-node-degenerate-memory" "bin/lib/test-host-load-probe.sh"
# ── PB9 availableMemory 0 is a real reading; a totalmem of 0 or NaN drops every memory line ─
# want: <avail_kb>,<total_kb>,<scope>,<host_mem_ line count>; `-` = the line is absent.
if [ "$PB_NODE" = 1 ]; then
    while IFS='|' read -r PB9_NAME PB9_ARGS PB9_WANT; do
        [[ -z "$PB9_NAME" || "$PB9_NAME" =~ ^[[:space:]]*# ]] && continue
        PB9_NAME="${PB9_NAME//[[:space:]]/}"
        PB9_WANT="${PB9_WANT//[[:space:]]/}"
        PB9_ARGS="${PB9_ARGS//@G16@/$((16 * GIB))}"
        PB9_ARGS="${PB9_ARGS//@G8@/$((8 * GIB))}"
        PB9_ARGS="${PB9_ARGS//@G6@/$((6 * GIB))}"
        # shellcheck disable=SC2086  # the overrides are one word each
        pb $PB9_ARGS </dev/null
        PB9_GOT=""
        for PB9_KEY in host_mem_avail_kb host_mem_total_kb host_mem_scope; do
            PB9_V="$(kv_of "$OUT" "$PB9_KEY")"
            PB9_GOT="$PB9_GOT${PB9_V:--},"
        done
        PB9_GOT="$PB9_GOT$(printf '%s\n' "$OUT" | grep -c '^host_mem_')"
        assert_eq "PB9 $PB9_NAME: avail,total,scope,lines" "$PB9_WANT" "$PB9_GOT"
        assert_eq "PB9 $PB9_NAME positive control: one host_busy_ms line" "1" "$(printf '%s\n' "$OUT" | grep -cE '^host_busy_ms=[0-9]+$')"
    done <<'TABLE'
avail0-no-limit      | platform=linux totalmem=@G16@ freemem=@G6@ availableMemory=0 constrainedMemory=0    | 0,16777216,host,3
avail0-cgroup-limit  | platform=linux totalmem=@G16@ freemem=@G6@ availableMemory=0 constrainedMemory=@G8@ | 0,8388608,cgroup,3
totalmem-zero        | platform=linux totalmem=0 freemem=@G6@ availableMemory=@G6@ constrainedMemory=0      | -,-,-,0
totalmem-non-numeric | platform=linux totalmem=abc freemem=@G6@ availableMemory=@G6@ constrainedMemory=0    | -,-,-,0
TABLE
else
    pb_skip PB9
fi
case_ran PB9
case_end

# PB10-PB12: the probe timeout is the shorter of 20 s and one heartbeat (TEST_LANES_HEARTBEAT,
# an invalid value falls back to 60). The stub sleeps PB_SLEEP seconds, then prints a valid snapshot.
PB_STUB="$TMPDIR_BASE/probe-sleep-stub.sh"
printf '%s\n' '#!/usr/bin/env bash' 'sleep "${PB_SLEEP:?}"' "printf 'wall_ms=1\\nsnapshot=2\\n'" > "$PB_STUB"
chmod +x "$PB_STUB"
# pbt <heartbeat> <sleep-secs> — PBT_RC / PBT_EL: _thl_load_snapshot's status and wall seconds.
pbt() {
    load_drv "$(new_cache)" "$CD" "TEST_LANES_HEARTBEAT=$1" "PB_SLEEP=$2" "TEST_LANES_LOAD_PROBE_CMD=$PB_STUB" \
        "PB_OUTF=$TMPDIR_BASE/pbt.out" -- \
        '_t0=$SECONDS; _thl_load_snapshot "$PB_OUTF"; echo "rc=$?"; echo "el=$((SECONDS - _t0))"'
    PBT_RC="$(kv_of "$OUT" rc)"
    PBT_EL="$(kv_of "$OUT" el)"
}
# pbt_within <name> <max-secs> — passes when PBT_EL is an integer <= max-secs.
pbt_within() {
    if [[ ${PBT_EL:-} =~ ^[0-9]+$ ]] && [ "$PBT_EL" -le "$2" ]; then
        pass "$1 (${PBT_EL}s)"
    else
        fail "$1" "elapsed=${PBT_EL:-none}s max=$2s rc=$RC err=$(printf '%q' "$ERR")"
    fi
}

case_begin "probe-timeout-heartbeat-clamp" "bin/lib/test-host-load-probe.sh"
# ── PB10 heartbeat 2: a probe that sleeps 25 s is cut off after ~2 s, not 20 s ─
pbt 2 0
assert_eq "PB10 positive control: heartbeat 2, an instant stub probe succeeds" "0" "$PBT_RC"
pbt 2 25
assert_eq "PB10 heartbeat 2, a 25 s stub probe: _thl_load_snapshot fails" "1" "$PBT_RC"
pbt_within "PB10 heartbeat 2, a 25 s stub probe is cut off within 6 s (one heartbeat, not 20 s)" 6
case_ran PB10

# ── PB11 heartbeat above 20 s keeps 20 s; heartbeat 5 clamps to 5 s ──────────
pbt 60 3
assert_eq "PB11 heartbeat 60, a 3 s stub probe succeeds (timeout not clamped small)" "0" "$PBT_RC"
pbt 5 3
assert_eq "PB11 heartbeat 5, a 3 s stub probe succeeds (timeout above 3 s)" "0" "$PBT_RC"
pbt 5 8
assert_eq "PB11 heartbeat 5, an 8 s stub probe: _thl_load_snapshot fails" "1" "$PBT_RC"
pbt_within "PB11 heartbeat 5, an 8 s stub probe is cut off within 7 s" 7
case_ran PB11
case_end

case_begin "probe-timeout-heartbeat-invalid" "bin/lib/test-host-load-probe.sh"
# ── PB12 an invalid or empty heartbeat falls back to 60: the timeout is 20 s ─
for _hb in "" abc 0 -5; do
    pbt "$_hb" 3
    assert_eq "PB12 heartbeat '$_hb' (default 60): a 3 s stub probe succeeds" "0" "$PBT_RC"
done
case_ran PB12
case_end

grp_done probe-cases.sh
