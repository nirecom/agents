#!/usr/bin/env bash
# tests/bin/feature-2692-test-lanes-status.sh — #2692 status: the load line and the allocation columns.
# Tests: bin/lib/test-host-lanes-status.sh, bin/test-lanes-status.sh
# Tags: TL2, scope:issue-specific, lanes, load-scale-in
# TL3 gap (what this test does NOT catch):
# - a sample written by a real claim holder on a busy host; the fixture writes the sample file
# Mitigation: before WORKFLOW_USER_VERIFIED read bash bin/test-lanes-status.sh while 3 run-alls
# run at once on this host and check the load line and the presence rows against their logs.

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_ROOT/tests/lib/harness.sh"
STATUS_LIB="$AGENTS_ROOT/bin/lib/test-host-lanes-status.sh"
STATUS_CLI="$AGENTS_ROOT/bin/test-lanes-status.sh"
RUN_TIMEOUT="$AGENTS_ROOT/bin/run-with-timeout.sh"
# shellcheck source=../lib/load-sample2-fixture.sh
source "$AGENTS_ROOT/tests/lib/load-sample2-fixture.sh"

# expect_eq <label> <want> <got> — the CLI's RC and stderr ride along on a mismatch.
expect_eq() {
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3") rc=${RC:-} err=$(printf '%q' "${ERR:-}")"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
readonly TMPDIR_BASE
LIVE_SLEEP=""
trap '[ -n "$LIVE_SLEEP" ] && kill "$LIVE_SLEEP" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md).
export WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPDIR_BASE/transcripts"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$CLAUDE_TRANSCRIPT_BASE_DIR"
unset CLAUDE_CODE_SESSION_ID
unset TEST_LANES_HELD TEST_LANES TEST_LANES_TTL TEST_LANES_HEARTBEAT TEST_LANES_WAIT_INTERVAL \
    TEST_LANES_WAIT_CAP TEST_MAX_JOBS_PER_HOST TEST_MAX_JOBS_PER_RUN AUTO_CONFIG_TEST_MAX_JOBS \
    TEST_LANES_LOAD_PROBE_CMD RUN_ALL_LANES_LIB GIT_DIR GIT_WORK_TREE
export RUN_ALL_CACHE_DIR="$TMPDIR_BASE/default-cache"
export RUN_ALL_CONFIG_VAR_CMD="$TMPDIR_BASE/no-such-config-var-cmd"
NEUTRAL_DIR="$TMPDIR_BASE/neutral"
mkdir -p "$NEUTRAL_DIR"

# nproc 1024 keeps the logical-CPU ceiling out of every case.
CPU_SHIM_DIR="$TMPDIR_BASE/cpu-shim"
mkdir -p "$CPU_SHIM_DIR"
printf '#!%s\nprintf "1024\\n"\n' "$(type -P bash)" > "$CPU_SHIM_DIR/nproc"
chmod +x "$CPU_SHIM_DIR/nproc"

# A live pid that owns every fixture presence record.
sleep 600 &
LIVE_SLEEP=$!

CASE_RAN=""
case_ran() { CASE_RAN="${CASE_RAN} $1"; }
now_epoch() { printf '%(%s)T' -1; }

# mk_run <cache> <token> — an alive presence record runs/run.<token> owned by LIVE_SLEEP.
mk_run() {
    local d="$1/runs/run.$2" now
    now="$(now_epoch)"
    mkdir -p "$d"
    printf 'pid=%s\nenv=%s\nkind=run-all\nstart=%s\ntoken=%s\nmax_jobs_per_run=1000\nmax_jobs_per_host=5\n' \
        "$LIVE_SLEEP" "$OSTYPE" "$now" "$2" > "$d/owner"
    printf '%s\n' "$now" > "$d/hb"
}

# run_status <cache> [NAME=VAL ...] — bin/test-lanes-status.sh; sets OUT / ERR / RC.
run_status() {
    local cache="$1"; shift
    (
        cd "$NEUTRAL_DIR" || exit 2
        bash "$RUN_TIMEOUT" 60 env "RUN_ALL_CACHE_DIR=$cache" "PATH=$CPU_SHIM_DIR:$PATH" \
            TEST_MAX_JOBS_PER_HOST=5 AUTO_CONFIG_TEST_MAX_JOBS=off "$@" bash "$STATUS_CLI"
    ) >"$TMPDIR_BASE/st.out" 2>"$TMPDIR_BASE/st.err"
    RC=$?
    OUT="$(cat "$TMPDIR_BASE/st.out")"
    ERR="$(cat "$TMPDIR_BASE/st.err")"
}

line_n() { printf '%s\n' "$OUT" | sed -n "${1}p"; }
# load_val <key> — the value of <key>= on the load line.
load_val() { line_n 2 | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1; }
# tail4 — the last 4 columns of every run.* row, one row per line, sorted.
tail4() { printf '%s\n' "$OUT" | grep '^run\.' | awk -F'\t' '{ print NF ":" $7 " " $8 " " $9 " " $10 }' | sort; }
# tree_sig <cache> — every path and file content under <cache>, for the read-only check.
tree_sig() { (cd "$1" 2>/dev/null && find . -print0 | sort -z | xargs -0 -I{} sh -c 'printf "%s\n" "{}"; [ -f "{}" ] && cat "{}"'); }

case_begin "preconditions-status-lib" "bin/lib/test-host-lanes-status.sh"
if [[ -f "$STATUS_LIB" ]]; then pass "P0 bin/lib/test-host-lanes-status.sh exists"; else fail "P0 bin/lib/test-host-lanes-status.sh missing (not implemented yet)"; fi
case_end

TOK1="$LIVE_SLEEP.1700000000.1"
TOK2="$LIVE_SLEEP.1700000000.2"

case_begin "status-first-line" "bin/test-lanes-status.sh"
# ST1 line 1 keeps today's tokens, and a sample never changes it.
C1="$TMPDIR_BASE/st1"
mk_run "$C1" "$TOK1"
run_status "$C1"
expect_eq "ST1 status exits 0" "0" "$RC"
L1_BARE="$(line_n 1)"
case " $L1_BARE " in
    " max_jobs_per_host=5 "*"source=env "*"mode=off runs=1 ") pass "ST1 line 1 keeps max_jobs_per_host/source/mode/runs" ;;
    *) fail "ST1 line 1 changed" "line=$(printf '%q' "$L1_BARE")" ;;
esac
case " $L1_BARE " in *" load "*|*" state="*|*" pool="*) fail "ST1 line 1 carries load keys" "line=$(printf '%q' "$L1_BARE")" ;; *) pass "ST1 line 1 carries no load key" ;; esac
ls2_write "$C1" 0 external_centicores=300 -- "$TOK1=3 4 3 cpu-load-limit"
run_status "$C1"
expect_eq "ST1 line 1 is the same with a sample" "$L1_BARE" "$(line_n 1)"
case_ran ST1
case_end

case_begin "status-load-line" "bin/lib/test-host-lanes-status.sh"
# ST2 no sample: line 2 is just `load state=none`.
C2="$TMPDIR_BASE/st2"
mk_run "$C2" "$TOK1"
run_status "$C2"
expect_eq "ST2 no sample: line 2" "load state=none" "$(line_n 2)"
case_ran ST2

# ST3 a valid sample: every key, in the documented order, with the sample's values.
C3="$TMPDIR_BASE/st3"
mk_run "$C3" "$TOK1"
ls2_write "$C3" 5 external_centicores=250 reserved_cores=12 scale_in=0 \
    host_busy_centicores=900 mem_scope=host mem_avail_mb=8000 mem_total_mb=16000 mem_reserve_mb=2048 \
    mem_cap=6 pool=15 -- "$TOK1=3 4 3 cpu-load-limit"
run_status "$C3"
# No held_samples (the unmeasurable hold is gone) and no mem_spare_lanes (the start-width trim is gone).
expect_eq "ST3 load line key order" \
    "load state age_s external_centicores reserved_cores scale_in host_busy_centicores mem_scope mem_avail_mb mem_reserve_mb mem_cap pool" \
    "$(line_n 2 | tr ' ' '\n' | sed 's/=.*//' | tr '\n' ' ' | sed 's/ $//')"
ST3_GOT=""
for _kv in state=ok external_centicores=250 reserved_cores=12 scale_in=0 \
    host_busy_centicores=900 mem_scope=host mem_avail_mb=8000 mem_reserve_mb=2048 mem_cap=6 \
    pool=15; do
    [ "$(load_val "${_kv%%=*}")" = "${_kv#*=}" ] || ST3_GOT="$ST3_GOT ${_kv%%=*}=$(load_val "${_kv%%=*}")"
done
expect_eq "ST3 load line values come from the sample" "" "$ST3_GOT"
_age="$(load_val age_s)"
if [[ "$_age" =~ ^[0-9]+$ ]] && [ "$_age" -ge 4 ] && [ "$_age" -le 60 ]; then
    pass "ST3 age_s is the sample age ($_age)"
else
    fail "ST3 age_s is not the sample age" "age_s=$(printf '%q' "$_age") line=$(printf '%q' "$(line_n 2)")"
fi
ls2_write "$C3" 0 state=unmeasurable mem_scope=cgroup mem_cap=none -- "$TOK1=3 4 3 cpu-load-limit"
run_status "$C3"
expect_eq "ST3 unmeasurable sample: state" "unmeasurable" "$(load_val state)"
expect_eq "ST3 unmeasurable sample: mem_scope / mem_cap" \
    "cgroup none" "$(load_val mem_scope) $(load_val mem_cap)"
case " $(line_n 2) " in
    *" held_samples="*|*" mem_spare_lanes="*) fail "ST3 the load line still shows a retired key" "line=$(printf '%q' "$(line_n 2)")" ;;
    *) pass "ST3 the load line shows neither held_samples nor mem_spare_lanes" ;;
esac
case_ran ST3

# ST4 a rejected sample (runs mismatch, schema 1) shows `load state=none`.
C4="$TMPDIR_BASE/st4"
mk_run "$C4" "$TOK1"
ls2_write "$C4" 0 runs=3 -- "$TOK1=3 4 3 cpu-load-limit"
run_status "$C4"
expect_eq "ST4 runs mismatch: line 2" "load state=none" "$(line_n 2)"
expect_eq "ST4 runs mismatch: the row is not shown" "10:- - - -" "$(tail4)"
ls2_write "$C4" 0 schema=1 -- "$TOK1=3 4 3 cpu-load-limit"
run_status "$C4"
expect_eq "ST4 schema 1: line 2" "load state=none" "$(line_n 2)"
case_ran ST4
case_end

case_begin "status-presence-columns" "bin/lib/test-host-lanes-status.sh"
# ST5 presence rows: 10 columns; the own allocation row, or `-` when the sample has none.
C5="$TMPDIR_BASE/st5"
mk_run "$C5" "$TOK1"
mk_run "$C5" "$TOK2"
run_status "$C5"
expect_eq "ST5 no sample: both rows have 10 columns and '-' allocation columns" \
    "10:- - - -"$'\n'"10:- - - -" "$(tail4)"
ls2_write "$C5" 0 runs=1 -- "$TOK1=3 4 3 cpu-load-limit"
run_status "$C5"
expect_eq "ST5 sample: the row of TOK1 carries width/ssthresh/per-run lane cap/decided_by, TOK2 '-'" \
    "10:- - - -"$'\n'"10:3 4 3 cpu-load-limit" "$(tail4)"
ls2_write "$C5" 0 -- "$TOK1=2 2 2 memory-limit" "$TOK2=5 15 5 slow-start"
run_status "$C5"
expect_eq "ST5 sample with both rows" "10:2 2 2 memory-limit"$'\n'"10:5 15 5 slow-start" "$(tail4)"
_lane_cols="$(printf '%s\n' "$OUT" | grep -c '^lane\.')"
expect_eq "ST5 no lane rows (only presence records exist)" "0" "$_lane_cols"
case_ran ST5
case_end

case_begin "status-malicious-sample" "bin/lib/test-host-lanes-status.sh"
# ST6 a hostile value is neither evaluated nor shown; the shown values stay in [A-Za-z0-9._-].
C6="$TMPDIR_BASE/st6"
mk_run "$C6" "$TOK1"
M6="$TMPDIR_BASE/st6-marker"
ls2_write "$C6" 0 "mem_scope=\$(touch $M6)" -- "$TOK1=3 4 3 cpu-load-limit"
run_status "$C6"
expect_eq "ST6 header payload: status exits 0" "0" "$RC"
# Positive control: the checks below mean something only when status reads the sample at all.
expect_eq "ST6 header payload: the load line is printed" "load state=" "$(line_n 2 | cut -c1-11)"
[ ! -e "$M6" ] && pass "ST6 header payload was not evaluated" || fail "ST6 header payload was evaluated (marker created)"
case "$OUT" in *touch*|*'$('*) fail "ST6 header payload shown" "out=$(printf '%q' "$OUT")" ;; *) pass "ST6 header payload not shown" ;; esac
ls2_write "$C6" 0 -- "$TOK1=3 4 3 \$(touch $M6)"
run_status "$C6"
expect_eq "ST6 row payload: the presence row has 10 columns" "10" "$(printf '%s\n' "$OUT" | awk -F'\t' '/^run\./ { print NF; exit }')"
[ ! -e "$M6" ] && pass "ST6 row payload was not evaluated" || fail "ST6 row payload was evaluated (marker created)"
case "$OUT" in *touch*|*'$('*) fail "ST6 row payload shown" "out=$(printf '%q' "$OUT")" ;; *) pass "ST6 row payload not shown" ;; esac
_bad="$(printf '%s\n' "$OUT" | sed -n '2,$p' | tr '\t ' '\n\n' | grep -v '^$' | grep -vE '^[A-Za-z0-9._=-]+$|^\?+$' | head -n 3)"
expect_eq "ST6 every shown value is sanitized" "" "$_bad"
if printf '%s' "$ERR" | grep -qiE 'syntax error|invalid arithmetic|bad substitution|unbound variable|command not found'; then
    fail "ST6 shell evaluation error on a hostile sample" "err=$(printf '%q' "$ERR")"
else
    pass "ST6 no shell evaluation error"
fi
case_ran ST6
case_end

case_begin "status-read-only" "bin/test-lanes-status.sh"
# ST7 status changes nothing: no claim, no slots/, no sample rewrite, no reclaim.
C7="$TMPDIR_BASE/st7"
mk_run "$C7" "$TOK1"
mkdir -p "$C7/runs/run.9.9.9"
ls2_write "$C7" 0 runs=1 -- "$TOK1=3 4 3 cpu-load-limit"
ST7_BEFORE="$(tree_sig "$C7")"
run_status "$C7"
expect_eq "ST7 status exits 0" "0" "$RC"
expect_eq "ST7 positive control: status read the sample (load state=ok)" "ok" "$(load_val state)"
expect_eq "ST7 the cache tree is unchanged (no claim, no slots/, no rewrite, no reclaim)" "$ST7_BEFORE" "$(tree_sig "$C7")"
[ ! -e "$C7/slots" ] && pass "ST7 no slots/ created" || fail "ST7 status created slots/"
case_ran ST7
case_end

case_begin "status-naming" "bin/test-lanes-status.sh"
# ST8 #2692 rename: the old name fair share is gone from the status display, and the status
# display names load/sample the run-all lane allocation sample.
C8="$TMPDIR_BASE/st8"
mk_run "$C8" "$TOK1"
ls2_write "$C8" 0 -- "$TOK1=3 15 3 per-run-cap"
run_status "$C8"
expect_eq "ST8 positive control: a per-run-cap row is read and shown" "10:3 15 3 per-run-cap" "$(tail4)"
case "$OUT$ERR" in
    *[Ff]air[\ _-][Ss]hare*) fail "ST8 the status output still says fair share" "out=$(printf '%q' "$OUT")" ;;
    *) pass "ST8 the status output never says fair share" ;;
esac
_st8_hits=""
for _f in "$STATUS_CLI" "$STATUS_LIB"; do
    grep -qiE 'fair[ _-]share' "$_f" 2>/dev/null && _st8_hits="$_st8_hits ${_f#"$AGENTS_ROOT"/}"
done
expect_eq "ST8 neither the status CLI nor the status lib says fair share" "" "$_st8_hits"
case "$OUT" in
    *"run-all lane allocation sample"*) pass "ST8 the status output names load/sample the run-all lane allocation sample" ;;
    *) fail "ST8 the status output does not name the run-all lane allocation sample" "out=$(printf '%q' "$OUT")" ;;
esac
case_ran ST8

# ST9 #2692 rename: the status CLI header lists the decided_by values under their new names.
grep -qF "per-run-cap|cpu-load-limit|memory-limit|slow-start" "$STATUS_CLI" \
    && pass "ST9 the status CLI lists decided_by as per-run-cap|cpu-load-limit|memory-limit|slow-start" \
    || fail "ST9 the status CLI does not list the renamed decided_by values" "file=$STATUS_CLI"
grep -qF "per-run-cap|cpu|memory|slow-start" "$STATUS_CLI" \
    && fail "ST9 the status CLI still lists the old decided_by names cpu|memory" "file=$STATUS_CLI" \
    || pass "ST9 the status CLI no longer lists the old decided_by names"
case_ran ST9
case_end

case_begin "suite-integrity" "bin/lib/test-host-lanes-status.sh"
CASE_EXPECTED="ST1 ST2 ST3 ST4 ST5 ST6 ST7 ST8 ST9"
CASE_MISSING=""
for _c in $CASE_EXPECTED; do
    case " $CASE_RAN " in *" $_c "*) ;; *) CASE_MISSING="${CASE_MISSING:+$CASE_MISSING }$_c" ;; esac
done
expect_eq "CASE1 every planned case id ran" "" "$CASE_MISSING"
case_end

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
