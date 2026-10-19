# 4d — a compaction leaves a pending flag (post-compact.js) that the next PostToolUse or Stop
# turns into one update request; a compaction burst yields one suggestion to the user per
# session. stop_hook_active never outputs. Sourced by ../feat-progress-pressure.sh.

echo "=== 4d: compaction -> one request at the next PostToolUse ==="
pp_prime cp1
pp_compact cp1
pp_hook cp1 PostToolUse Read
pp_expect_fire "CP1 the call after a compaction asks for an update"
case "$PP_CTX" in
  *"- a context compaction happened"*) pass "CP1 the request names the compaction" ;;
  *) fail "CP1 the request names the compaction" "ctx=${PP_CTX:0:300}" ;;
esac
pp_hook cp1 PostToolUse Read
pp_expect_silent "CP1 the pending flag is consumed"

echo "=== 4d: compaction -> Stop carries it ==="
pp_prime cp2
pp_compact cp2
pp_hook cp2 Stop
pp_expect_fire "CP2 Stop after a compaction asks for an update"
case "$PP_EVT" in
  Stop) pass "CP2 the Stop request is addressed to the Stop event" ;;
  *) fail "CP2 the Stop request is addressed to the Stop event" "hookEventName=$PP_EVT" ;;
esac
pp_hook cp2 Stop
pp_expect_silent "CP2 a second Stop is silent"

echo "=== 4d: a second compaction follows the 4c threshold, not the pending flag ==="
# A compaction is a risk, so the 4c threshold is halved to 1MiB (detail plan stage 2 step 7): MiB-1 of
# growth stays silent, MiB+1 in total fires — the full 2MiB would not, so this pins the halving.
pp_prime cp5
pp_compact cp5
pp_hook cp5 PostToolUse Read
pp_expect_fire "CP5 the first compaction asks for an update"
pp_compact cp5
pp_hook cp5 PostToolUse Read
pp_expect_silent "CP5 a second compaction alone does not ask again"
pp_state grow cp5 $((MiB - 1))
pp_hook cp5 PostToolUse Read
pp_expect_silent "CP5 after the second compaction, growth under the halved 1MiB threshold stays silent"
pp_state grow cp5 2
pp_hook cp5 PostToolUse Read
pp_expect_fire "CP5 after the second compaction, a total just over 1MiB asks for an update (the threshold is halved)"

echo "=== 4d after a 4c request: inside the hour the shared cap drops it ==="
# compaction (4d, request 1) -> volume growth (4c, request 2) -> compaction, no session-progress.md edit.
# Detail plan stage 2 step 9: two 4c/4d requests in the last hour cap both, and a capped 4d pending
# is cleared, not deferred — so the pending never fires once the hour has passed either.
pp_prime cp6
pp_compact cp6
pp_hook cp6 PostToolUse Read
pp_expect_fire "CP6 the first compaction asks for an update (request 1)" compaction
pp_state grow cp6 $((2 * MiB + 1))
pp_hook cp6 PostToolUse Read
pp_expect_fire "CP6 2MiB of growth asks for an update (request 2)" transcript
pp_compact cp6
pp_hook cp6 PostToolUse Read
pp_expect_silent "CP6 a compaction after two requests in the hour is capped"
case "$(pp_pressure cp6 compaction_pending)" in
  true) fail "CP6 the capped 4d pending is cleared" "compaction_pending=true" ;;
  *) pass "CP6 the capped 4d pending is cleared" ;;
esac
pp_hook cp6 Stop
pp_expect_silent "CP6 Stop does not carry the capped 4d"
pp_age cp6 61
pp_hook cp6 PostToolUse Read
pp_expect_silent "CP6 the dropped 4d does not fire once the hour has passed"

echo "=== 4d after a 4c request: outside the cap, the next compaction is a first again ==="
# Intent 4d: the first compaction AFTER THE PREVIOUS PROGRESS REQUEST asks once, even below the
# 4c threshold. A 4c request is a progress request, so the compaction after it is a first one;
# the hour is aged away so the cap cannot be what decides the outcome.
pp_prime cp7
pp_compact cp7
pp_hook cp7 PostToolUse Read
pp_expect_fire "CP7 the first compaction asks for an update" compaction
pp_state grow cp7 $((2 * MiB + 1))
pp_hook cp7 PostToolUse Read
pp_expect_fire "CP7 2MiB of growth asks for an update" transcript
pp_age cp7 61
pp_compact cp7
pp_hook cp7 PostToolUse Read
pp_expect_fire "CP7 the first compaction after the 4c request asks for an update (no session-progress.md edit between)" compaction
pp_hook cp7 PostToolUse Read
pp_expect_silent "CP7 that request is delivered once"

echo "=== 4d: an update written after the compaction answers the pending request ==="
pp_prime cp8
pp_compact cp8
pp_state touch-progress cp8
pp_hook cp8 PostToolUse Read
pp_expect_silent "CP8 an update after the compaction suppresses the compaction request"
case "$(pp_pressure cp8 compaction_pending)" in
  true) fail "CP8 the pending flag is cleared by the update" "compaction_pending=true" ;;
  *) pass "CP8 the pending flag is cleared by the update" ;;
esac

echo "=== 4d: an update older than the compaction keeps the request ==="
pp_prime cp9
pp_state touch-progress cp9
pp_age cp9 1
pp_compact cp9
pp_hook cp9 PostToolUse Read
pp_expect_fire "CP9 an update older than the compaction does not answer it" compaction

echo "=== stop_hook_active never outputs ==="
pp_prime cp3
pp_compact cp3
pp_hook cp3 Stop - stop-active
pp_expect_silent "CP3 Stop with stop_hook_active is silent"
pp_hook cp3 PostToolUse Read
pp_expect_fire "CP3 the pending flag survives for the next PostToolUse"

echo "=== burst: many compactions -> one suggestion to the user ==="
# BURST_THRESHOLD is 7: seven compactions inside 30 minutes are not a burst, the eighth is.
pp_prime cp4
for _i in 1 2 3 4 5 6 7; do pp_compact cp4; done
pp_hook cp4 Stop
case "$PP_CTX" in
  *"Tell the user"*) fail "CP4 seven compactions in 30 min do not suggest telling the user" "ctx=${PP_CTX:0:300}" ;;
  *) pass "CP4 seven compactions in 30 min do not suggest telling the user" ;;
esac
pp_compact cp4
pp_hook cp4 Stop
pp_expect_fire "CP4 Stop after the eighth compaction carries a request"
case "$PP_CTX" in
  *"Compactions are coming in quick succession. Tell the user this one thing: propose, once, updating session-progress.md and handing over to a new session."*) pass "CP4 the burst request suggests telling the user" ;;
  *) fail "CP4 the burst request suggests telling the user" "ctx=${PP_CTX:0:300}" ;;
esac
CP4_LINES="$(printf '%s\n' "$PP_CTX" | grep -c -F 'Tell the user' || true)"
if [[ "$CP4_LINES" -eq 1 ]]; then
  pass "CP4 the eighth compaction yields exactly one suggestion line"
else
  fail "CP4 the eighth compaction yields exactly one suggestion line" "lines=$CP4_LINES ctx=${PP_CTX:0:300}"
fi
pp_hook cp4 Stop
pp_expect_silent "CP4 the suggestion is not repeated at the next Stop"
pp_compact cp4
pp_hook cp4 Stop
case "$PP_CTX" in
  *"Tell the user"*) fail "CP4 a later compaction does not repeat the suggestion (once per session)" "ctx=${PP_CTX:0:300}" ;;
  *) pass "CP4 a later compaction does not repeat the suggestion (once per session)" ;;
esac
