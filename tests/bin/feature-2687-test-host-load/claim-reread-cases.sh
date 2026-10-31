#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-load/claim-reread-cases.sh — CL18-CL19 (#2692): thl_load_tick
# re-reads load/sample once it holds load/.claim. The pre-claim read finds a stale sample; a
# wrapped _thl_load_claim then writes the next sample (as another tick would) before taking the
# real claim. CL18: the re-read is fresh, so the tick neither measures, allocates nor writes, and
# releases its claim. CL19: the re-read is still stale, so the tick measures and writes, carrying
# the re-read rows (not the pre-claim ones).

# cr_sample <file> <measured_at> <external_centicores> <row> — a valid schema-2 sample with one row.
cr_sample() {
    printf 'schema=2\nmeasured_at=%s\nstate=ok\nhost_counter=node\nhost_busy_centicores=%s\nexternal_centicores=%s\nreserved_cores=0\nscale_in=0\nabove=0\nbelow=0\nmem_avail_mb=unknown\nmem_total_mb=unknown\nmem_reserve_mb=unknown\nmem_scope=unknown\nmem_tests_mb=0\nmem_cap=none\npool=11\nruns=1\nalloc.%s\n' \
        "$2" "$3" "$3" "$4" > "$1"
}

# The wrapped claim writes $THL_CACHE_ROOT/next.sample, CR_AGE seconds old, as load/sample (a copy
# in written.sample), then takes the real claim; _thl_alloc_run is wrapped to leave a marker.
CR_SNIP='
L="$THL_CACHE_ROOT/load"
eval "$(declare -f _thl_load_claim | sed "1s/^_thl_load_claim /_cr_claim_real /")"
_thl_load_claim() {
    : > "$THL_CACHE_ROOT/wrapped"
    sed "s/^measured_at=.*/measured_at=$(($(date +%s) - CR_AGE))/" "$THL_CACHE_ROOT/next.sample" > "$L/sample"
    cp "$L/sample" "$THL_CACHE_ROOT/written.sample"
    _cr_claim_real "$@"
}
eval "$(declare -f _thl_alloc_run | sed "1s/^_thl_alloc_run /_cr_alloc_real /")"
_thl_alloc_run() { : > "$THL_CACHE_ROOT/alloc.called"; _cr_alloc_real "$@"; }
thl_load_tick; echo "rc=$?"
[ -e "$THL_CACHE_ROOT/wrapped" ] && echo "wrapped=1" || echo "wrapped=0"
[ -e "$THL_CACHE_ROOT/alloc.called" ] && echo "alloc=1" || echo "alloc=0"
cmp -s "$THL_CACHE_ROOT/written.sample" "$L/sample" && echo "same=1" || echo "same=0"
echo "ext=$(ls_key external_centicores)"
echo "m=$(ls_key measured_at)"
echo "row=$(ls_key "alloc\.$CR_TOK")"
_thl_sample_read "$L/sample"; echo "f_ok=$?"
[ -e "$L/.claim" ] && echo "claim=1" || echo "claim=0"
echo "graves=$(ls -A "$L" | grep -c "^\.grave")"'

# cr_setup — a cache with one live run (token CR_TOK, max jobs per host 12), a 10 s old sample
# without rows, next.sample (external 4242, the run's row 3 7 11 slow-start) and a probe snapshot.
cr_setup() {
    local t
    C="$(new_cache)"; CR_S="$(new_snaps)"
    t="$(now_epoch)"; CR_TOK="$LIVE_SLEEP.$t.88"
    mk_presence "$C" "$CR_TOK" "$LIVE_SLEEP" "$t" 12
    CR_OLD="$((t - 10))"
    mk_sample "$C" "$CR_OLD" 0 0
    cr_sample "$C/next.sample" 0 4242 "$CR_TOK=3 7 11 slow-start"
    snap2 "$CR_S/snap.1" 111111 1000000 "$ROOT_PID 1 500 10240 bash"
}

case_begin "load-claim-reread" "bin/lib/test-host-load.sh"

# ── CL18 the sample turned fresh while the tick took the claim: the tick stands down ─
cr_setup
load_drv "$C" "$CR_S" CR_AGE=0 "CR_TOK=$CR_TOK" -- "$CR_SNIP"
assert_eq "CL18 positive control: the wrapped claim wrote a fresh sample before the real claim" "1" "$(kv_of "$OUT" wrapped)"
assert_eq "CL18 the tick completes (rc 0)" "0" "$(kv_of "$OUT" rc)"
assert_eq "CL18 the re-read is fresh: the probe is not run" "0" "$(probe_calls "$CR_S")"
assert_eq "CL18 the re-read is fresh: the allocation is not run" "0" "$(kv_of "$OUT" alloc)"
assert_eq "CL18 the fresh sample is not overwritten (byte-identical)" "1" "$(kv_of "$OUT" same)"
assert_eq "CL18 the fresh sample keeps its marker external_centicores 4242" "4242" "$(kv_of "$OUT" ext)"
assert_eq "CL18 the tick releases its own claim (load/.claim gone)" "0" "$(kv_of "$OUT" claim)"
assert_eq "CL18 no grave is left" "0" "$(kv_of "$OUT" graves)"
case_ran CL18

# ── CL19 the re-read is still stale: the tick measures and writes from the re-read rows ─
cr_setup
load_drv "$C" "$CR_S" CR_AGE=10 "CR_TOK=$CR_TOK" -- "$CR_SNIP"
assert_eq "CL19 positive control: the wrapped claim wrote a stale sample before the real claim" "1" "$(kv_of "$OUT" wrapped)"
assert_eq "CL19 the tick completes (rc 0)" "0" "$(kv_of "$OUT" rc)"
assert_eq "CL19 the re-read is stale: the probe runs once" "1" "$(probe_calls "$CR_S")"
assert_eq "CL19 the re-read is stale: the allocation runs" "1" "$(kv_of "$OUT" alloc)"
assert_eq "CL19 the tick rewrites the sample (not byte-identical)" "0" "$(kv_of "$OUT" same)"
_cl19_m="$(kv_of "$OUT" m)"
[[ $_cl19_m =~ ^[0-9]+$ ]] && [ "$_cl19_m" -gt "$CR_OLD" ] \
    && pass "CL19 the rewritten sample's measured_at advanced" \
    || fail "CL19 the tick did not rewrite load/sample" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
assert_eq "CL19 the rewritten sample is well-formed" "0" "$(kv_of "$OUT" f_ok)"
assert_eq "CL19 the run keeps the re-read row 3/7 (stale: no growth), not a new run's 4" "3 7 11 slow-start" "$(kv_of "$OUT" row)"
assert_eq "CL19 the tick releases its claim" "0" "$(kv_of "$OUT" claim)"
case_ran CL19

case_end

grp_done claim-reread-cases.sh
