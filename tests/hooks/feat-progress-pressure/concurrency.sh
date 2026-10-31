# RACE TEST — overlapping hook / CLI processes against one sid share progress-pressure.json
# through the O_EXCL lock of hooks/lib/progress-file.js updatePressure. Every assertion holds
# for any interleaving under correct locking, so the case may miss a race on a given run but
# never goes red against correct code. Sourced by ../feat-progress-pressure.sh (fixture: _lib.sh).

# burst-records.js <sid> — the number of "compaction-burst" entries the state handoff reader returns.
cat > "$PP_TMP/js/burst-records.js" <<'JS'
const { readStateHandoff } = require(process.env.AGENTS + '/hooks/lib/state-handoff-record');
const all = readStateHandoff(process.argv[2]).entries || [];
process.stdout.write(String(all.filter((x) => x.record_key === 'compaction-burst').length));
JS

# cc_count <needle> <file...> — how many of the hook outputs carry <needle> in additionalContext.
cc_count() {
  local needle="$1" f ctx n=0
  shift
  for f in "$@"; do
    ctx="$(run_with_timeout 30 node "$(np "$PP_TMP/js/ctx.js")" < "$f" 2>/dev/null)"
    case "$ctx" in *"$needle"*) n=$((n + 1)) ;; esac
  done
  printf '%s' "$n"
}

# cc_nudge_bg <sid> <event> <tool> <out> — one progress-nudge run in the background.
cc_nudge_bg() {
  { pp_node env.js "$1" "$2" "$3" | run_with_timeout 60 node "$PP_HOOK" > "$4" 2>/dev/null; } &
}

cc_expect_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1" "want=$2 got=$3"; fi
}

echo "=== race: parallel nudges share one pending compaction and one new complete ==="
CC_OUT="$PP_TMP/cc-out"
mkdir -p "$CC_OUT"
pp_prime cc1
pp_state mark cc1 research
pp_compact cc1
CC1_STEP_BEFORE="$(pp_pressure cc1 counts.step_complete)"
CC1_FILES=()
for _i in 1 2 3 4 5; do
  cc_nudge_bg cc1 PostToolUse Bash "$CC_OUT/cc1-$_i.json"
  CC1_FILES+=("$CC_OUT/cc1-$_i.json")
done
wait
pp_hook cc1 Stop
printf '%s' "$PP_OUT" > "$CC_OUT/cc1-final.json"
CC1_FILES+=("$CC_OUT/cc1-final.json")
cc_expect_eq "CC1 the new complete is delivered exactly once across the parallel nudges" 1 "$(cc_count "step complete: research" "${CC1_FILES[@]}")"
cc_expect_eq "CC1 the one pending compaction is requested exactly once" 1 "$(cc_count "a context compaction happened" "${CC1_FILES[@]}")"
cc_expect_eq "CC1 counts.compaction records one consumed request" 1 "$(pp_pressure cc1 counts.compaction)"
cc_expect_eq "CC1 counts.step_complete grows by one" "$((${CC1_STEP_BEFORE:-0} + 1))" "$(pp_pressure cc1 counts.step_complete)"

echo "=== race: parallel /update-progress bumps, compactions and nudges on one sid ==="
# N bumps and M compactions (M > BURST_THRESHOLD, all inside 30 min) overlap K nudges.
CC_N=6
CC_M=9
pp_prime cc2
pp_state mark cc2 detail
CC2_FILES=()
for _i in $(seq 1 "$CC_N"); do
  run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/progress-file" ensure --session cc2 --reason update-progress > /dev/null 2>&1 &
done
for _i in $(seq 1 "$CC_M"); do
  { printf '{"session_id":"cc2"}' | run_with_timeout 60 node "$PP_COMPACT" > /dev/null 2>&1; } &
done
for _i in 1 2 3 4; do
  cc_nudge_bg cc2 PostToolUse Bash "$CC_OUT/cc2-$_i.json"
  CC2_FILES+=("$CC_OUT/cc2-$_i.json")
done
wait
for _i in 1 2; do
  pp_hook cc2 Stop
  printf '%s' "$PP_OUT" > "$CC_OUT/cc2-final-$_i.json"
  CC2_FILES+=("$CC_OUT/cc2-final-$_i.json")
done
cc_expect_eq "CC2 no /update-progress increment is lost" "$CC_N" "$(pp_pressure cc2 counts.update_progress)"
CC2_TIMES="$(pp_node pressure.js cc2 compactions_at 2>/dev/null | tr ',' '\n' | grep -c 'T' || true)"
cc_expect_eq "CC2 no compaction time is lost" "$CC_M" "$CC2_TIMES"
cc_expect_eq "CC2 the burst is recorded exactly once" 1 "$(pp_node burst-records.js cc2 2>/dev/null)"
cc_expect_eq "CC2 the burst suggestion is delivered exactly once" 1 "$(cc_count "Tell the user" "${CC2_FILES[@]}")"
cc_expect_eq "CC2 the new complete is delivered exactly once" 1 "$(cc_count "step complete: detail" "${CC2_FILES[@]}")"

# cc_requests <sid> — the number of entries in requests_at.
cc_requests() {
  pp_node pressure.js "$1" requests_at 2>/dev/null | tr ',' '\n' | grep -c 'T' || true
}

echo "=== race: two parallel nudges share one 4c volume increment ==="
# Read is not a step candidate and nothing is compaction-pending, so only 4c can fire.
# Barrier preload (test-side only): each progress-nudge waits (<=3s) for the other at start-up
# and again at its first mergePressure call — the baseline write that follows the unlocked
# readBaseline of computePressureSignal — so both measure against the same baseline.
cat > "$PP_TMP/js/cc3-barrier.js" <<'JS'
if (/progress-nudge\.js$/.test(String(process.argv[1] || '')) && process.env.PP_BARRIER_DIR) {
  const fs = require('fs');
  const path = require('path');
  const dir = process.env.PP_BARRIER_DIR;
  const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
  const barrier = (tag) => {
    fs.writeFileSync(path.join(dir, tag + '.' + process.pid), '');
    const start = Date.now();
    let seen = 0;
    for (;;) {
      seen = fs.readdirSync(dir).filter((n) => n.startsWith(tag + '.')).length;
      if (seen >= 2 || Date.now() - start >= 3000) break;
      sleep(10);
    }
    fs.writeFileSync(path.join(dir, 'seen-' + tag + '.' + process.pid), seen + ' ' + (Date.now() - start));
  };
  barrier('start');
  const pf = require(process.env.AGENTS + '/hooks/lib/progress-file');
  const orig = pf.mergePressure;
  let first = true;
  pf.mergePressure = function () {
    if (first) { first = false; barrier('measured'); }
    return orig.apply(this, arguments);
  };
}
JS

# cc_barrier_met <dir> — how many processes saw both markers at the measured barrier.
cc_barrier_met() {
  local f n=0
  for f in "$1"/seen-measured.*; do
    [[ -f "$f" ]] || continue
    case "$(cat "$f")" in 2\ *) n=$((n + 1)) ;; esac
  done
  printf '%s' "$n"
}

for _i in 1 2 3 4 5; do
  CC3_SID="cc3-$_i"
  CC3_BARRIER="$PP_TMP/cc3-barrier-$_i"
  mkdir -p "$CC3_BARRIER"
  pp_prime "$CC3_SID"
  pp_state grow "$CC3_SID" "$((2 * MiB))"
  CC3_REQ_BEFORE="$(cc_requests "$CC3_SID")"
  NODE_OPTIONS="--require $(np "$PP_TMP/js/cc3-barrier.js")"
  export NODE_OPTIONS PP_BARRIER_DIR="$(np "$CC3_BARRIER")"
  cc_nudge_bg "$CC3_SID" PostToolUse Read "$CC_OUT/$CC3_SID-a.json"
  cc_nudge_bg "$CC3_SID" PostToolUse Read "$CC_OUT/$CC3_SID-b.json"
  wait
  unset NODE_OPTIONS PP_BARRIER_DIR
  cc_expect_eq "CC3[$_i] fixture: both processes met at the post-measurement barrier" 2 "$(cc_barrier_met "$CC3_BARRIER")"
  cc_expect_eq "CC3[$_i] exactly one of two parallel nudges carries the volume request" 1 "$(cc_count "the transcript grew by about" "$CC_OUT/$CC3_SID-a.json" "$CC_OUT/$CC3_SID-b.json")"
  cc_expect_eq "CC3[$_i] counts.volume records one request" 1 "$(pp_pressure "$CC3_SID" counts.volume)"
  cc_expect_eq "CC3[$_i] requests_at grows by exactly one" "$((${CC3_REQ_BEFORE:-0} + 1))" "$(cc_requests "$CC3_SID")"
done
