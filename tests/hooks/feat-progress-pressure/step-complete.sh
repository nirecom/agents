# 4a — a step completed since the last evaluation is reported once, at a PostToolUse Bash,
# Agent or Task (legacy alias of Agent) or at Stop, from the events after the session's cursor. Sourced by
# ../feat-progress-pressure.sh inside its case block (fixture: _lib.sh).

echo "=== 4a: first evaluation reports the past completes once ==="
pp_state seed sc1
pp_hook sc1 PostToolUse Bash
pp_expect_fire "SC1 the first evaluation reports workflow_init (cursor starts at 0)" workflow_init
pp_hook sc1 PostToolUse Bash
pp_expect_silent "SC1 the next Bash call is silent (the cursor moved past it)"

echo "=== 4a: one complete -> one report ==="
pp_prime sc2
pp_state mark sc2 research
pp_hook sc2 PostToolUse Bash
pp_expect_fire "SC2 a research complete is reported at the next Bash" research
pp_hook sc2 PostToolUse Bash
pp_expect_silent "SC2 the same complete is not reported twice"

echo "=== 4a: two completes -> both named in one request ==="
pp_prime sc3
pp_state mark sc3 research
pp_state mark sc3 outline
pp_hook sc3 PostToolUse Bash
pp_expect_fire "SC3 both completes are named in one request" research outline
case "$PP_CTX" in
  *research*$'\n'*outline*|*outline*$'\n'*research*) pass "SC3 each complete sits on its own line" ;;
  *) fail "SC3 each complete sits on its own line" "ctx=${PP_CTX:0:300}" ;;
esac

echo "=== 4a: skipped and backfilled are not progress ==="
pp_prime sc4
pp_state mark sc4 outline skipped
pp_hook sc4 PostToolUse Bash
pp_expect_silent "SC4 a skipped step is not reported"
pp_state backfill sc4 detail
pp_hook sc4 PostToolUse Bash
pp_expect_silent "SC4 a backfilled (inherited) complete is not reported"

echo "=== 4a: only Bash, Agent, Task and Stop are candidates ==="
pp_prime sc5
pp_state mark sc5 research
pp_hook sc5 PostToolUse Read
pp_expect_silent "SC5 a Read call does not report a complete"
pp_hook sc5 UserPromptSubmit
case "$PP_CTX" in
  *research*) fail "SC5 UserPromptSubmit does not report a complete" "ctx=${PP_CTX:0:300}" ;;
  *) pass "SC5 UserPromptSubmit does not report a complete" ;;
esac
pp_hook sc5 Stop
pp_expect_fire "SC5 Stop reports the complete the Read call left pending" research
case "$PP_EVT" in
  Stop) pass "SC5 the Stop request is addressed to the Stop event" ;;
  *) fail "SC5 the Stop request is addressed to the Stop event" "hookEventName=$PP_EVT" ;;
esac
pp_hook sc5 Stop
pp_expect_silent "SC5 a second Stop is silent"

pp_prime sc6
pp_state mark sc6 write_tests
pp_hook sc6 PostToolUse Agent
pp_expect_fire "SC6 an Agent call reports a complete" write_tests

pp_prime sc10
pp_state mark sc10 write_tests
pp_hook sc10 PostToolUse Task
pp_expect_fire "SC10 a Task call (legacy alias of Agent) reports a complete" write_tests
pp_hook sc10 PostToolUse Task
pp_expect_silent "SC10 the same complete is not reported twice at the next Task call"

echo "=== 4a: a complete marked after the Bash call waits for the next candidate ==="
pp_prime sc7
pp_hook sc7 PostToolUse Bash
pp_expect_silent "SC7 a Bash call before the complete is silent"
pp_state mark sc7 detail
pp_hook sc7 PostToolUse Bash
pp_expect_fire "SC7 the next Bash call reports it" detail

echo "=== 4a: two completes in one evaluation -> two counted requests, each delivered once ==="
# Detail plan stage 2: several completes found in one evaluation go into ONE additionalContext, one
# line per step, and each step counts as one request (counts.step_complete += 2).
pp_prime sc8
SC8_BEFORE="$(pp_pressure sc8 counts.step_complete)"
pp_state mark sc8 research
pp_state mark sc8 outline
pp_hook sc8 PostToolUse Bash
pp_expect_fire "SC8 one request names both completes" research outline
SC8_RES_LINES="$(printf '%s\n' "$PP_CTX" | grep -c 'research' || true)"
SC8_OUT_LINES="$(printf '%s\n' "$PP_CTX" | grep -c 'outline' || true)"
SC8_BOTH_LINES="$(printf '%s\n' "$PP_CTX" | grep 'research' | grep -c 'outline' || true)"
if [[ "$SC8_RES_LINES" -ge 1 && "$SC8_OUT_LINES" -ge 1 && "$SC8_BOTH_LINES" -eq 0 ]]; then
  pass "SC8 research and outline sit on separate lines"
else
  fail "SC8 research and outline sit on separate lines" "research=$SC8_RES_LINES outline=$SC8_OUT_LINES same-line=$SC8_BOTH_LINES ctx=${PP_CTX:0:300}"
fi
SC8_AFTER="$(pp_pressure sc8 counts.step_complete)"
if [[ "$SC8_AFTER" =~ ^[0-9]+$ && "$SC8_BEFORE" =~ ^[0-9]+$ && $((SC8_AFTER - SC8_BEFORE)) -eq 2 ]]; then
  pass "SC8 the 4a counter grows by 2 (each complete is one request)"
else
  fail "SC8 the 4a counter grows by 2 (each complete is one request)" "before=$SC8_BEFORE after=$SC8_AFTER"
fi
pp_hook sc8 PostToolUse Bash
case "$PP_CTX" in
  *research*|*outline*) fail "SC8 neither complete is re-delivered at the next Bash" "ctx=${PP_CTX:0:300}" ;;
  *) pass "SC8 neither complete is re-delivered at the next Bash" ;;
esac
pp_hook sc8 Stop
case "$PP_CTX" in
  *research*|*outline*) fail "SC8 neither complete is re-delivered at Stop" "ctx=${PP_CTX:0:300}" ;;
  *) pass "SC8 neither complete is re-delivered at Stop" ;;
esac
SC8_LATER="$(pp_pressure sc8 counts.step_complete)"
if [[ "$SC8_LATER" = "$SC8_AFTER" ]]; then
  pass "SC8 the 4a counter does not grow without a new complete"
else
  fail "SC8 the 4a counter does not grow without a new complete" "after=$SC8_AFTER later=$SC8_LATER"
fi

echo "=== 4a: the decision write fails after the cursor moved -> the complete is still delivered once ==="
# Fault injection: a --require preload makes the 2nd progress-pressure.json write of one
# progress-nudge process fail (writeSidecar returns false, as a full disk would), i.e. phase (a)
# moved event_cursor past the complete and the phase-(b) decision write is lost.
cat > "$PP_TMP/js/fail-nth-pressure-write.js" <<'JS'
if (/progress-nudge\.js$/.test(String(process.argv[1] || ''))) {
  const fs = require('fs');
  const hs = require(process.env.AGENTS + '/hooks/lib/handoff-sidecar');
  const orig = hs.writeSidecar;
  const nth = Number(process.env.PP_FAIL_PRESSURE_WRITE_NTH);
  let n = 0;
  hs.writeSidecar = function (sid, suffix, obj) {
    if (suffix === 'progress-pressure.json' && ++n === nth) {
      fs.writeFileSync(process.env.PP_FAIL_MARK, String(n));
      return false;
    }
    return orig.apply(this, arguments);
  };
}
JS
SC9_MARK="$(np "$PP_TMP")/sc9-injected"
pp_prime sc9
pp_state mark sc9 research
NODE_OPTIONS="--require $(np "$PP_TMP/js/fail-nth-pressure-write.js")"
export NODE_OPTIONS PP_FAIL_PRESSURE_WRITE_NTH=2 PP_FAIL_MARK="$SC9_MARK"
pp_hook sc9 PostToolUse Bash
unset NODE_OPTIONS PP_FAIL_PRESSURE_WRITE_NTH PP_FAIL_MARK
SC9_FIRST="$PP_CTX"
if [[ -f "$SC9_MARK" ]]; then
  pass "SC9 fixture: the 2nd pressure write of the first run was made to fail"
else
  fail "SC9 fixture: the 2nd pressure write of the first run was made to fail" "the preload never failed a write; stdout=${PP_OUT:0:300}"
fi
case "$SC9_FIRST" in
  *"step complete: research"*) pass "SC9 the run whose decision write failed still delivers the complete" ;;
  *) fail "SC9 the run whose decision write failed still delivers the complete" "stdout=${PP_OUT:0:300}" ;;
esac
pp_hook sc9 PostToolUse Bash
SC9_SECOND="$PP_CTX"
SC9_N=0
case "$SC9_FIRST" in *"step complete: research"*) SC9_N=$((SC9_N + 1)) ;; esac
case "$SC9_SECOND" in *"step complete: research"*) SC9_N=$((SC9_N + 1)) ;; esac
if [[ "$SC9_N" -eq 1 ]]; then
  pass "SC9 the complete is delivered exactly once across the failed run and the next normal run"
else
  fail "SC9 the complete is delivered exactly once across the failed run and the next normal run" "deliveries=$SC9_N first=${SC9_FIRST:0:200} second=${SC9_SECOND:0:200}"
fi
case "$SC9_SECOND" in
  *"step complete: research"*) fail "SC9 the next normal run does not repeat the complete" "ctx=${SC9_SECOND:0:300}" ;;
  *) pass "SC9 the next normal run does not repeat the complete" ;;
esac
