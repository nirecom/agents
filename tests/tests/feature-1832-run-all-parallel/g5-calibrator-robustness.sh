#!/usr/bin/env bash
# g5-calibrator-robustness.sh — the calibrator refuses, replaces or stops instead of mis-measuring.
# Tests: bin/calibrate-test-parallelism.sh
# Tags: tests, bin, parallel, calibrator, robustness, TL2, scope:issue-specific
# WHY (#2079 S3/S4): a measurement that ran beside other runs, at a narrower width, with one
# dominating test, or past its time budget silently produced a wrong record before. Each such
# condition now ends in exit 5 with a fixed token (or a replacement from the reserve), and the
# real cache area is never written except for the final published record.
# Invented interface (TDD): cal_parse_start_lines / cal_child_run in calibrate-test-parallelism/
# measure.sh; sourcing needs SCRIPT_CHECKOUT_ROOT, RUNNER, both run-all libs and TEST_LANES=off.
# TL3 gap: real contention on a busy host is not reproduced; stubs and instant tests stand in.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/_cal-fixture.sh"
cf_init

MEASURE_MOD="$CF_REPO/bin/calibrate-test-parallelism/measure.sh"
if [ ! -f "$CF_CAL" ]; then
    fail "g5/implementation-present" "missing: bin/calibrate-test-parallelism.sh"
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

conf_absent() { if [ -e "$1/parallelism.conf" ]; then fail "$2" "a record was written"; else pass "$2"; fi; }
golden_conf() { printf 'schema=2\nhost_id=golden\nmax_jobs_per_host=3\n' > "$1/parallelism.conf"; }
conf_sum() { cksum < "$1/parallelism.conf" 2>/dev/null || echo absent; }
expect_token() {
    if cf_inconclusive "$1"; then pass "$2"
    else fail "$2" "want exit 5 '$1'; rc=$CF_RC err=$(printf '%s' "$CF_ERR" | tail -n 2)"; fi
}
key_at() { cf_keys "$1" "$2" | sed -n "${3}p"; }
later_has() {
    local st="$1" from="$2" key="$3" n
    for n in $(awk -v f="$from" '$1 >= f { print $1 }' "$st/calls.log" 2>/dev/null); do
        cf_keys "$st" "$n" | grep -qxF "$key" && return 0
    done
    return 1
}
# corpus <n-ledger-candidates> — prints "<suite> <real>" with 6 s in-band tests.
corpus() {
    local s r
    s="$(cf_new_suite)"; r="$(cf_new_real)"
    cf_populate "$s" "$r" bin/a "$1" 6
    printf '%s %s' "$s" "$r"
}
ARGS=(--jobs-list "1 2" --repeat 1 --warmup 1)

# (1) a live lane holder in the real area -> lanes-busy, no seam call; a stale one is ignored
read -r S R <<< "$(corpus 8)"
cf_lane_holder "$R" alive
ST="$(cf_stub)"
cf_run "$S" "$R" "$ST" "${ARGS[@]}"
expect_token lanes-busy "g5/lanes/alive-holder-lanes-busy"
ck "g5/lanes/alive-holder-no-seam-call" "0" "$(cf_calls "$ST")"
read -r S R <<< "$(corpus 8)"
cf_lane_holder "$R" stale
ST="$(cf_stub)"
cf_run "$S" "$R" "$ST" "${ARGS[@]}"
ck "g5/lanes/stale-holder-measures" "0" "$CF_RC"

# (2) the seam reports a narrower effective width -> width-not-honoured
read -r S R <<< "$(corpus 15)"
ST="$(cf_stub)"; printf '1\n' > "$ST/force_width"
cf_run "$S" "$R" "$ST" --jobs-list "2 4" --repeat 1 --warmup 1
expect_token width-not-honoured "g5/width/narrower-width-refused"
conf_absent "$R" "g5/width/no-record"
ck "g5/width/stops-at-first-call" "1" "$(cf_calls "$ST")"

# (3) a warmup overrun is replaced from the reserve and the run still succeeds
read -r S R <<< "$(corpus 8)"
ST="$(cf_stub)"; printf '@1\t40\n' > "$ST/warmup.1.secs"
cf_run "$S" "$R" "$ST" "${ARGS[@]}"
ck "g5/warmup-overrun/exit-0" "0" "$CF_RC"
OV="$(cat "$ST/call.1.overridden" 2>/dev/null)"
if [ -n "$OV" ] && ! later_has "$ST" 2 "$OV"; then pass "g5/warmup-overrun/replaced"
else fail "g5/warmup-overrun/replaced" "overrun key '$OV' still sampled after call 1"; fi
if [ "$(cf_calls "$ST" warmup)" -ge 2 ]; then pass "g5/warmup-overrun/restarts-warmup"
else fail "g5/warmup-overrun/restarts-warmup" "warmup calls: $(cf_calls "$ST" warmup)"; fi

# (4) a measure overrun restarts the whole ladder from warmup
read -r S R <<< "$(corpus 8)"
ST="$(cf_stub)"; printf '@1\t40\n' > "$ST/measure.1.secs"
cf_run "$S" "$R" "$ST" "${ARGS[@]}"
ck "g5/measure-overrun/exit-0" "0" "$CF_RC"
ck "g5/measure-overrun/warmup-calls" "4" "$(cf_calls "$ST" warmup)"
ck "g5/measure-overrun/measure-calls" "3" "$(cf_calls "$ST" measure)"

# (5) more than 3 revisions -> revisions-exhausted (reserve 6 never runs dry)
read -r S R <<< "$(corpus 12)"
ST="$(cf_stub)"
for k in 1 2 3 4 5; do printf '@1\t40\n' > "$ST/warmup.$k.secs"; done
cf_run "$S" "$R" "$ST" --jobs-list "1 2" --sample 6 --repeat 1 --warmup 1
expect_token revisions-exhausted "g5/revisions-exhausted/token"
ck "g5/revisions-exhausted/warmup-calls" "4" "$(cf_calls "$ST" warmup)"
conf_absent "$R" "g5/revisions-exhausted/no-record"

# (6) the reserve (2) runs out before the revision cap -> reserve-exhausted
read -r S R <<< "$(corpus 8)"
ST="$(cf_stub)"
for k in 1 2 3; do printf '@1\t40\n' > "$ST/warmup.$k.secs"; done
cf_run "$S" "$R" "$ST" "${ARGS[@]}"
expect_token reserve-exhausted "g5/reserve-exhausted/token"
conf_absent "$R" "g5/reserve-exhausted/no-record"

# (7) the stderr parser: submitted tests and width values; verdict seconds never matter
parse() {
    ( SCRIPT_CHECKOUT_ROOT="$CF_REPO"; RUNNER="$CF_REPO/tests/run-all.sh"; TEST_LANES=off
      export RUNNER TEST_LANES
      . "$CF_LIB_PAR" >/dev/null 2>&1; . "$CF_LIB_DUR" >/dev/null 2>&1
      . "$MEASURE_MOD" >/dev/null 2>&1 || exit 9
      cal_parse_start_lines "$1" ) 2>/dev/null
}
P="$CF_T/parse"; mkdir -p "$P"
{
    printf '[run-all] reap: waitn\n'
    printf '[run-all] 1/3 start /x/bin/a.sh (j=2 inflight=1)\n'
    printf '[run-all] 2/3 start /x/bin/b.sh (j=2 inflight=2)\n'
    printf '[run-all] 1/3 PASS /x/bin/a.sh 3s\n'
    printf '[run-all] 3/3 start /x/bin/c.sh (j=2 inflight=2)\n'
    printf '[run-all] 2/3 PASS /x/bin/b.sh 4s\n'
    printf '[run-all] 3/3 PASS /x/bin/c.sh 5s\n'
} > "$P/normal.err"
sed 's/ [0-9]s$/ 41s/' "$P/normal.err" > "$P/normal-secs.err"
{
    printf '[run-all] 1/4 start /x/bin/sleeper.sh (j=4 inflight=1)\n'
    printf '[run-all] 2/4 start /x/bin/q1.sh (j=4 inflight=2)\n'
    printf '[run-all] 3/4 start /x/bin/q2.sh (j=4 inflight=3)\n'
    printf '[run-all] 4/4 start /x/bin/q3.sh (j=4 inflight=4)\n'
    printf '[run-all] deadline of 3s exceeded\n'
} > "$P/deadline.err"
if [ ! -f "$MEASURE_MOD" ]; then
    fail "g5/parser/module-present" "missing: bin/calibrate-test-parallelism/measure.sh"
else
    O1="$(parse "$P/normal.err")"; O2="$(parse "$P/normal-secs.err")"; O3="$(parse "$P/deadline.err")"
    ck "g5/parser/normal-submitted" "/x/bin/a.sh /x/bin/b.sh /x/bin/c.sh " \
        "$(printf '%s\n' "$O1" | sed -n 's/^submitted=//p' | tr '\n' ' ')"
    ck "g5/parser/normal-j" "j=2" "$(printf '%s\n' "$O1" | grep '^j=' | LC_ALL=C sort -u | tr -d '\n')"
    ck "g5/parser/normal-inflight-max" "inflight_max=2" "$(printf '%s\n' "$O1" | grep '^inflight_max=')"
    if [ -n "$O1" ] && [ "$O1" = "$O2" ]; then pass "g5/parser/verdict-secs-ignored"
    else fail "g5/parser/verdict-secs-ignored" "output changed with verdict seconds"; fi
    ck "g5/parser/deadline-submitted" "/x/bin/sleeper.sh /x/bin/q1.sh /x/bin/q2.sh /x/bin/q3.sh " \
        "$(printf '%s\n' "$O3" | sed -n 's/^submitted=//p' | tr '\n' ' ')"
    ck "g5/parser/deadline-inflight-max" "inflight_max=4" "$(printf '%s\n' "$O3" | grep '^inflight_max=')"
fi

# (8) --no-write prints the selection, writes no record, leaves an existing one alone
read -r S R <<< "$(corpus 8)"
ST="$(cf_stub)"
cf_run "$S" "$R" "$ST" --no-write "${ARGS[@]}"
ck "g5/no-write/exit-0" "0" "$CF_RC"
if [ -n "$(cf_selected)" ]; then pass "g5/no-write/prints-selection"
else fail "g5/no-write/prints-selection" "no 'calibrate: selected' line"; fi
conf_absent "$R" "g5/no-write/no-record"
golden_conf "$R"; BEFORE="$(conf_sum "$R")"
ST="$(cf_stub)"
cf_run "$S" "$R" "$ST" --no-write "${ARGS[@]}"
ck "g5/no-write/existing-record-unchanged" "$BEFORE" "$(conf_sum "$R")"

# (9) a knee at the top of the ladder advises a wider --jobs-list; elsewhere it does not
read -r S R <<< "$(corpus 8)"
ST="$(cf_stub "1:4000 2:2000")"; : > "$ST/noseg"
cf_run "$S" "$R" "$ST" --jobs-list "1 2" --repeat 1 --warmup 0
ck "g5/knee-top/selected-2" "2" "$(cf_selected)"
if printf '%s\n%s\n' "$CF_OUT" "$CF_ERR" | grep -q -- '--jobs-list'; then pass "g5/knee-top/advice"
else fail "g5/knee-top/advice" "no --jobs-list advice for a knee at the top width"; fi
ST="$(cf_stub "1:2000 2:2000")"; : > "$ST/noseg"
cf_run "$S" "$R" "$ST" --jobs-list "1 2" --repeat 1 --warmup 0
ck "g5/knee-inside/selected-1" "1" "$(cf_selected)"
if printf '%s\n%s\n' "$CF_OUT" "$CF_ERR" | grep -q -- '--jobs-list'; then
    fail "g5/knee-inside/no-advice" "advice printed for a knee below the top width"
else pass "g5/knee-inside/no-advice"; fi

# (10) an inconclusive run leaves an existing record byte-identical
read -r S R <<< "$(corpus 8)"
golden_conf "$R"; BEFORE="$(conf_sum "$R")"
ST="$(cf_stub)"; printf 'rc=2\n' > "$ST/warmup.1.extra"
cf_run "$S" "$R" "$ST" "${ARGS[@]}"
expect_token run-failed "g5/inconclusive-keeps-record/token"
ck "g5/inconclusive-keeps-record/byte-identical" "$BEFORE" "$(conf_sum "$R")"

# (11) deadline run: only submitted-but-unrecorded tests overrun, never unsubmitted ones
read -r S R <<< "$(corpus 8)"
ST="$(cf_stub)"
printf 'rc=3\n' > "$ST/warmup.1.extra"
printf '@1\t-\n@6\t~\n' > "$ST/warmup.1.secs"
cf_run "$S" "$R" "$ST" "${ARGS[@]}"
ck "g5/deadline-run/exit-0" "0" "$CF_RC"
K1="$(key_at "$ST" 1 1)"; K6="$(key_at "$ST" 1 6)"
if [ -n "$K1" ] && ! later_has "$ST" 2 "$K1"; then pass "g5/deadline-run/unrecorded-replaced"
else fail "g5/deadline-run/unrecorded-replaced" "'$K1' still sampled"; fi
if [ -n "$K6" ] && later_has "$ST" 2 "$K6"; then pass "g5/deadline-run/unsubmitted-kept"
else fail "g5/deadline-run/unsubmitted-kept" "'$K6' was dropped although never submitted"; fi

# (12) an unexpected exit code, or a completed run with a missing record -> run-failed
read -r S R <<< "$(corpus 8)"
ST="$(cf_stub)"; printf 'rc=2\n' > "$ST/warmup.1.extra"
cf_run "$S" "$R" "$ST" "${ARGS[@]}"
expect_token run-failed "g5/run-failed/rc-2"
ST="$(cf_stub)"; printf '@3\t~\n' > "$ST/warmup.1.secs"
cf_run "$S" "$R" "$ST" "${ARGS[@]}"
expect_token run-failed "g5/run-failed/completed-but-unrecorded"

# (13) elapsed + next deadline past --time-limit (minutes) -> time-limit before any call
read -r S R <<< "$(corpus 8)"
ST="$(cf_stub)"
cf_run "$S" "$R" "$ST" --time-limit 1 "${ARGS[@]}"
expect_token time-limit "g5/time-limit/token"
ck "g5/time-limit/no-seam-call" "0" "$(cf_calls "$ST")"

# (14) the real area's durations/ is never touched; every seam call gets its own throwaway dir
read -r S R <<< "$(corpus 8)"
TOK="$(env "RUN_ALL_CACHE_DIR=$R" bash -c '. "$1"; . "$2"; run_all_dur_host_token' _ "$CF_LIB_PAR" "$CF_LIB_DUR" 2>/dev/null)"
LEG="$R/durations/dur.1.$TOK.20200101T000000-123.log"
printf 'f59ae20f601db63d|7|bin/legacy.sh\n' > "$LEG"
touch -d '2 hours ago' "$LEG" 2>/dev/null || touch -t 202001010000 "$LEG"
SIG0="$(cf_tree_sig "$R/durations")"
ST="$(cf_stub)"
cf_run "$S" "$R" "$ST" "${ARGS[@]}"
ck "g5/real-area/success-exit-0" "0" "$CF_RC"
ck "g5/real-area/untouched-after-success" "$SIG0" "$(cf_tree_sig "$R/durations")"
DIRS="$(awk '{ print $5 }' "$ST/calls.log" 2>/dev/null)"
if [ -n "$DIRS" ] && ! printf '%s\n' "$DIRS" | grep -qxF "$R" && ! printf '%s\n' "$DIRS" | grep -qx 'unset'; then
    pass "g5/real-area/seam-dir-differs-from-real"
else fail "g5/real-area/seam-dir-differs-from-real" "seam dirs: $(printf '%s' "$DIRS" | tr '\n' ' ')"; fi
ck "g5/real-area/seam-dir-per-call" "yes:$(printf '%s\n' "$DIRS" | grep -c .)" "$([ -n "$DIRS" ] && echo yes):$(printf '%s\n' "$DIRS" | LC_ALL=C sort -u | grep -c .)"
LEFT=0; for d in $DIRS; do [ -e "$d" ] && LEFT=$((LEFT + 1)); done
ck "g5/real-area/seam-dirs-removed" "yes:0" "$([ -n "$DIRS" ] && echo yes):$LEFT"
ST="$(cf_stub)"
cf_run "$S" "$R" "$ST" --no-write "${ARGS[@]}"
ck "g5/real-area/untouched-after-no-write" "$SIG0" "$(cf_tree_sig "$R/durations")"
ST="$(cf_stub)"; printf 'rc=2\n' > "$ST/warmup.1.extra"
cf_run "$S" "$R" "$ST" "${ARGS[@]}"
ck "g5/real-area/untouched-after-inconclusive" "$SIG0" "$(cf_tree_sig "$R/durations")"
if [ -f "$LEG" ]; then pass "g5/real-area/legacy-segment-not-migrated"
else fail "g5/real-area/legacy-segment-not-migrated" "the calibrator migrated or removed $LEG"; fi

# (15)(16) one child run through the REAL runner (seconds, not minutes)
child() {
    ( SCRIPT_CHECKOUT_ROOT="$CF_REPO"; RUNNER="$CF_REPO/tests/run-all.sh"; TEST_LANES=off
      export RUNNER TEST_LANES
      . "$CF_LIB_PAR" >/dev/null 2>&1; . "$CF_LIB_DUR" >/dev/null 2>&1
      . "$MEASURE_MOD" >/dev/null 2>&1 || exit 9
      cal_child_run "$@" ) >/dev/null 2>&1
}
CS="$(cf_new_suite)"; CR="$(cf_new_real)"
cf_ledger_raw "$CR" "$CS" /dev/null
for n in q1 q2 q3; do cf_add "$CS" "bin/$n"; done
printf '#!/usr/bin/env bash\n# Tests: tests/run-all.sh\nsleep 8\nexit 0\n' > "$CS/bin/sleeper.sh"
printf '%s\n' "$CS/bin/q1.sh" "$CS/bin/q2.sh" "$CS/bin/q3.sh" > "$CF_T/child1.list"
printf '%s\n' "$CS/bin/sleeper.sh" "$CS/bin/q1.sh" "$CS/bin/q2.sh" "$CS/bin/q3.sh" > "$CF_T/child2.list"
CSIG0="$(cf_tree_sig "$CR")"
if [ ! -f "$MEASURE_MOD" ]; then
    fail "g5/child-run/module-present" "missing: bin/calibrate-test-parallelism/measure.sh"
else
    RUN_ALL_CACHE_DIR="$CR" TESTS_DIR="$CS" child 3 "$CF_T/child1.list" 30 measure "$CF_T/child1.rep"
    ck "g5/child-run/instant/rc-0" "rc=0" "$(grep '^rc=' "$CF_T/child1.rep" 2>/dev/null)"
    if grep -qE '^ms=[0-9]+$' "$CF_T/child1.rep" 2>/dev/null; then pass "g5/child-run/instant/ms"
    else fail "g5/child-run/instant/ms" "no ms= line"; fi
    ck "g5/child-run/instant/recorded-3" "3" "$(grep -cE '^recorded=.*	[0-9]+$' "$CF_T/child1.rep" 2>/dev/null)"
    ck "g5/child-run/instant/unrecorded-0" "0" "$(grep -c '^unrecorded=' "$CF_T/child1.rep" 2>/dev/null)"
    ck "g5/child-run/instant/real-area-untouched" "$CSIG0" "$(cf_tree_sig "$CR")"
    RUN_ALL_CACHE_DIR="$CR" TESTS_DIR="$CS" child 4 "$CF_T/child2.list" 3 measure "$CF_T/child2.rep"
    ck "g5/child-run/deadline/rc-3" "rc=3" "$(grep '^rc=' "$CF_T/child2.rep" 2>/dev/null)"
    ck "g5/child-run/deadline/only-sleeper-unrecorded" "sleeper.sh" \
        "$(sed -n 's/^unrecorded=//p' "$CF_T/child2.rep" 2>/dev/null | sed 's#.*/##' | tr -d '\n')"
    ck "g5/child-run/deadline/recorded-3" "3" "$(grep -c '^recorded=' "$CF_T/child2.rep" 2>/dev/null)"
    ck "g5/child-run/deadline/real-area-untouched" "$CSIG0" "$(cf_tree_sig "$CR")"
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
