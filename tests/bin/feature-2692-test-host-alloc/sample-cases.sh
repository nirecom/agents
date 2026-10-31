#!/usr/bin/env bash
# tests/bin/feature-2692-test-host-alloc/sample-cases.sh — SR1-SR6: the strict, non-evaluating
# schema-2 reader (_thl_sample_read <file>, rc 0 accept / non-0 reject), the tick replacing
# a schema-1 sample, the header keys the tick writes, the 256-row alloc cap, and the decided_by set.

SRC="$(new_cache)"
SRV="$TMPDIR_BASE/sr-variants"
mkdir -p "$SRV"
# sr_trim <text> — <text> without leading or trailing blanks.
sr_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
# sr_build <name> <header> <rows> <extra> — one variant in $SRV through ls2_write: <header> is
# `,`-separated key=val (PWN = the pwned-marker path), <rows> `;`-separated alloc rows (Tn = run
# n's token); <extra> `+line` appends, `=line` replaces the whole file (`\n` splits lines).
# The retired-* variants are a valid sample plus held_samples / mem_spare_lanes: those keys
# are gone from the schema, so the strict reader rejects them like any unknown key.
sr_build() {
    local n="$1" x="$4" e pwn="$TMPDIR_BASE/sr-pwned"
    local -a hs=() rs=() hdr=() rows=()
    IFS=',' read -r -a hs <<< "$2"
    IFS=';' read -r -a rs <<< "$3"
    for e in ${hs[@]+"${hs[@]}"}; do e="$(sr_trim "$e")"; [[ -n "$e" ]] && hdr+=("${e//PWN/$pwn}"); done
    for e in ${rs[@]+"${rs[@]}"}; do
        e="$(sr_trim "$e")"; [[ -n "$e" ]] || continue
        [[ $e =~ ^T([0-9]+)= ]] && e="$(tok "${BASH_REMATCH[1]}")=${e#*=}"
        rows+=("$e")
    done
    rm -f "$SRC/load/sample"
    ls2_write "$SRC" 3 ${hdr[@]+"${hdr[@]}"} -- ${rows[@]+"${rows[@]}"}
    cp "$SRC/load/sample" "$SRV/$n"
    case "$x" in
        +*) printf '%b\n' "${x#+}" >> "$SRV/$n" ;;
        =*) printf '%b\n' "${x#=}" > "$SRV/$n" ;;
    esac
}
declare -A SR_WANT=()
SR_NAMES=()
while IFS='|' read -r _n _w _h _r _x; do
    [[ -z "$_n" || "$_n" =~ ^[[:space:]]*# ]] && continue
    _n="${_n//[[:space:]]/}"; _w="${_w//[[:space:]]/}"
    sr_build "$_n" "$_h" "$_r" "$(sr_trim "$_x")"
    SR_WANT[$_n]="$_w"; SR_NAMES+=("$_n")
done <<'TABLE'
# name            | want | header overrides (,)                         | alloc rows (;)                          | extra
ok-bare           | 0 |                                                  |                                          |
ok-rows           | 0 | mem_avail_mb=4096, mem_total_mb=16384, mem_reserve_mb=2048, mem_scope=cgroup, mem_cap=3 | T1=4 15 8 slow-start; T2=3 3 7 memory-limit |
ok-off            | 0 | state=off, host_counter=                         |                                          |
ok-unmeasurable   | 0 | state=unmeasurable, mem_scope=host               | T1=1 1 1 per-run-cap; T2=2 2 2 cpu-load-limit |
schema1           | 1 | schema=1                                         |                                          |
schema3           | 1 | schema=3                                         |                                          |
unknown-state     | 1 | state=busy                                       |                                          |
bad-scope         | 1 | mem_scope=pod                                    |                                          |
retired-held      | 1 |                                                  |                                          | +held_samples=0
retired-spare     | 1 |                                                  |                                          | +mem_spare_lanes=none
retired-both      | 1 |                                                  |                                          | +held_samples=0\nmem_spare_lanes=none
bad-cap           | 1 | mem_cap=-1                                       |                                          |
bad-counter       | 1 | host_counter=system                              |                                          |
bad-measured-at   | 1 | measured_at=soon                                 |                                          |
wide-scale        | 1 | scale_in=12345                                   |                                          |
missing-pool      | 1 | pool=DROP                                        |                                          |
runs-mismatch     | 1 | runs=2                                           | T1=4 15 8 slow-start                     |
bad-decided       | 1 |                                                  | T1=4 15 8 held                           |
bad-token         | 1 |                                                  | abc=4 15 8 slow-start                    |
bad-row-shape     | 1 |                                                  | T1=4 15 slow-start                       |
wide-row          | 1 |                                                  | T1=12345 1 1 cpu-load-limit              |
duplicate-row     | 1 |                                                  | T1=4 15 8 cpu-load-limit; T1=4 15 8 cpu-load-limit |
subst             | 1 | state=$(touch PWN)                               |                                          |
unknown-key       | 1 |                                                  |                                          | +bogus=1
duplicate         | 1 |                                                  |                                          | +pool=15
garbage           | 1 |                                                  |                                          | =not a key value line
no-equals         | 1 |                                                  |                                          | +schema 2
TABLE

# decided_by on one row: the 4 current values are accepted; the pre-rename cpu / memory (never
# released) are rejected like any unknown decided_by.
declare -A SR_DB_WANT=()
SR_DB_NAMES=()
while IFS='|' read -r _n _w _d; do
    [[ -z "$_n" || "$_n" =~ ^[[:space:]]*# ]] && continue
    _n="${_n//[[:space:]]/}"; _w="${_w//[[:space:]]/}"; _d="${_d//[[:space:]]/}"
    sr_build "$_n" "" "T1=4 15 8 $_d" ""
    SR_DB_WANT[$_n]="$_w"; SR_DB_NAMES+=("$_n")
done <<'TABLE'
# name               | want | decided_by
db-per-run-cap       | 0    | per-run-cap
db-cpu-load-limit    | 0    | cpu-load-limit
db-memory-limit      | 0    | memory-limit
db-slow-start        | 0    | slow-start
db-old-cpu           | 1    | cpu
db-old-memory        | 1    | memory
TABLE

al_drv "$(new_cache)" "$(new_snaps)" "SRV=$SRV" -- '
for f in "$SRV"/*; do _thl_sample_read "$f" >/dev/null 2>&1; r=$?; [ "$r" -eq 0 ] || r=1; echo "${f##*/}=$r"; done'

case_begin "sample-reader-accepts" "bin/lib/test-host-load-sample.sh"
# ── SR1 a complete schema-2 sample, with or without rows, is accepted ───────
for _v in "${SR_NAMES[@]}"; do
    [[ "${SR_WANT[$_v]}" == 0 ]] && expect_eq "SR1 $_v: accepted" "0" "$(kv_of "$OUT" "$_v")"
done
case_ran SR1
case_end

case_begin "sample-reader-rejects" "bin/lib/test-host-load-sample.sh"
# ── SR2 every malformed variant is rejected; nothing in a value is evaluated ─
for _v in "${SR_NAMES[@]}"; do
    [[ "${SR_WANT[$_v]}" == 1 ]] && expect_eq "SR2 $_v: rejected" "1" "$(kv_of "$OUT" "$_v")"
done
if [ "$RC" -ne 0 ] || [ -e "$TMPDIR_BASE/sr-pwned" ]; then
    fail "SR2 a \$(...) value was evaluated, or the reader never ran" "rc=$RC err=$(printf '%q' "$ERR")"
else
    pass "SR2 a \$(...) value is never evaluated"
fi
case_ran SR2
case_end

case_begin "sample-reader-decided-by" "bin/lib/test-host-load-sample.sh"
# ── SR6 decided_by: only per-run-cap|cpu-load-limit|memory-limit|slow-start are accepted ─
for _v in "${SR_DB_NAMES[@]}"; do
    if [[ "${SR_DB_WANT[$_v]}" == 0 ]]; then
        expect_eq "SR6 $_v: accepted" "0" "$(kv_of "$OUT" "$_v")"
    else
        expect_eq "SR6 $_v: the pre-rename decided_by is rejected" "1" "$(kv_of "$OUT" "$_v")"
    fi
done
case_ran SR6
case_end

case_begin "sample-schema1-replaced" "bin/lib/test-host-load-sample.sh"
# ── SR3 a schema-1 sample counts as absent: the tick writes schema 2 at once ─
SR3C="$(new_cache)"
al_run "$SR3C" 1
mkdir -p "$SR3C/load"
printf 'schema=1\nmeasured_at=%s\nstate=ok\nhost_counter=system\nexternal_centicores=300\nscale_in=3\nabove=2\nbelow=0\n' \
    "$(now_epoch)" > "$SR3C/load/sample"
al_drv "$SR3C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "SR3 schema 1 just written is not 'fresh': the tick rewrites it as schema 2" "2" "$(tk 1 schema)"
expect_eq "SR3 mode off writes state=off" "off" "$(tk 1 state)"
expect_eq "SR3 the schema-1 scale_in 3 is not carried over" "0" "$(tk 1 scale_in)"
expect_eq "SR3 the rewritten sample carries no held_samples key" "" "$(tk 1 held_samples)"
case_ran SR3
case_end

case_begin "sample-writer-keys" "bin/lib/test-host-load-sample.sh"
# ── SR4 the tick writes exactly the schema-2 header keys (no held_samples / mem_spare_lanes) ─
SR4_KEYS=""
for _m in off on; do
    SR4C="$(new_cache)"
    al_run "$SR4C" 1; al_lanes "$SR4C" 1 4 1
    if [ "$_m" = on ]; then
        al_snaps "$SR4C" "$SR4C/snaps" "0 $(mb 4096) $GIB16 host"
        al_drv "$SR4C" "$SR4C/snaps" "$ON" -- 'al_tick 1'
    else
        al_drv "$SR4C" "$(new_snaps)" -- 'al_tick 1'
    fi
    SR4_GOT="$(printf '%s\n' "$OUT" | sed -n 's/^t1\.\([a-z_]*\)=.*/\1/p' | sort | tr '\n' ' ')"
    SR4_KEYS="$(printf '%s\n' "${LS2_KEYS[@]}" | sort | tr '\n' ' ')"
    expect_eq "SR4 mode $_m: the written header keys are the schema-2 keys" "$SR4_KEYS" "$SR4_GOT"
done
expect_eq "SR4 the schema has 18 header keys" "18" "${#LS2_KEYS[@]}"
case_ran SR4
case_end

case_begin "sample-reader-row-cap" "bin/lib/test-host-load-sample.sh"
# ── SR5 the alloc row cap: 256 rows are accepted, 257 rejected (runs= matches both) ─
SR5C="$(new_cache)"
SR5_ROWS=()
for ((_i = 1; _i <= 257; _i++)); do SR5_ROWS+=("1.1.$_i=1 1 1 cpu-load-limit"); done
ls2_write "$SR5C" 3 -- "${SR5_ROWS[@]:0:256}"
cp "$SR5C/load/sample" "$TMPDIR_BASE/sr5-256"
ls2_write "$SR5C" 3 -- "${SR5_ROWS[@]}"
cp "$SR5C/load/sample" "$TMPDIR_BASE/sr5-257"
al_drv "$(new_cache)" "$(new_snaps)" "SR5D=$TMPDIR_BASE" -- '
for f in sr5-256 sr5-257; do
    _thl_sample_read "$SR5D/$f"; r=$?
    printf "%s.rc=%s\n%s.valid=%s\n%s.runs=%s\n%s.rows=%s\n" "$f" "$r" "$f" "$_THL_S_VALID" "$f" "$_THL_S_RUNS" \
        "$f" "$(printf "%s" "$_THL_S_ROWS" | grep -c .)"
done'
expect_eq "SR5 256 rows: accepted (rc 0)" "0" "$(kv_of "$OUT" sr5-256.rc)"
expect_eq "SR5 256 rows: the sample is valid" "1" "$(kv_of "$OUT" sr5-256.valid)"
expect_eq "SR5 256 rows: all 256 rows are read" "256" "$(kv_of "$OUT" sr5-256.rows)"
expect_eq "SR5 257 rows (runs=257): the file really carries runs=257" "runs=257" "$(grep '^runs=' "$TMPDIR_BASE/sr5-257")"
[ "$(kv_of "$OUT" sr5-257.rc)" != 0 ] && [ -n "$(kv_of "$OUT" sr5-257.rc)" ] && pass "SR5 257 rows: rejected (rc non-0)" \
    || fail "SR5 257 rows: not rejected" "rc=$(kv_of "$OUT" sr5-257.rc) drv-rc=$RC err=$(printf '%q' "$ERR")"
expect_eq "SR5 257 rows: the reject resets the sample (valid 0)" "0" "$(kv_of "$OUT" sr5-257.valid)"
expect_eq "SR5 257 rows: the reject resets runs to 0" "0" "$(kv_of "$OUT" sr5-257.runs)"
expect_eq "SR5 257 rows: the reject leaves no rows" "0" "$(kv_of "$OUT" sr5-257.rows)"
case_ran SR5
case_end

grp_done sample-cases.sh
