# Gating — the hourly cap on 4c/4d (4a exempt), the inactive period (nothing, no cursor move),
# subagent calls, and the output shape. Sourced by ../feat-progress-pressure.sh.

echo "=== cap: at most two 4c/4d requests an hour ==="
pp_prime ga1
pp_state grow ga1 $((2 * MiB)); pp_hook ga1 PostToolUse Read
pp_expect_fire "GA1 first volume request"
if printf '%s\n' "$PP_CTX" | grep -qxE -- '- the transcript grew by about [0-9]+KB since the last update'; then
  pass "GA1 the volume reason line reads '- the transcript grew by about <N>KB since the last update'"
else
  fail "GA1 the volume reason line reads '- the transcript grew by about <N>KB since the last update'" "ctx=${PP_CTX:0:300}"
fi
pp_state grow ga1 $((2 * MiB)); pp_hook ga1 PostToolUse Read
pp_expect_fire "GA1 second volume request"
pp_state grow ga1 $((2 * MiB)); pp_hook ga1 PostToolUse Read
pp_expect_silent "GA1 a third volume request within the hour is capped"
pp_compact ga1; pp_hook ga1 PostToolUse Read
pp_expect_silent "GA1 a compaction request within the hour is capped too"
pp_state mark ga1 research; pp_hook ga1 PostToolUse Bash
pp_expect_fire "GA1 a step complete is not capped" research
pp_age ga1 61
pp_hook ga1 PostToolUse Read
pp_expect_silent "GA1 the capped compaction's pending flag was cleared (not replayed an hour later)"
pp_state grow ga1 $((2 * MiB)); pp_hook ga1 PostToolUse Read
pp_expect_fire "GA1 an hour later the cap admits a request again"

echo "=== inactive: nothing is said and nothing moves ==="
pp_hook ga2 PostToolUse Bash
pp_expect_silent "GA2 a session with no workflow state is silent"
if [ -e "$WORKFLOW_PLANS_DIR/ga2-session-progress.md" ]; then fail "GA2 no session-progress.md is created outside the workflow" "created"; else pass "GA2 no session-progress.md is created outside the workflow"; fi

pp_prime ga3
pp_state pause ga3
pp_state mark ga3 write_tests
pp_hook ga3 PostToolUse Bash
pp_expect_silent "GA3 a paused session is silent"
pp_state unpause ga3
pp_hook ga3 PostToolUse Bash
pp_expect_fire "GA3 after the pause the cursor did not move (write_tests is reported now)" write_tests

pp_prime ga4
pp_state off ga4
pp_state mark ga4 research
pp_hook ga4 PostToolUse Bash
pp_expect_silent "GA4 a WORKFLOW_OFF session is silent"
pp_state on ga4
pp_hook ga4 PostToolUse Bash
pp_expect_fire "GA4 once WORKFLOW_OFF is lifted the complete is reported" research

echo "=== subagent calls belong to the main session ==="
pp_prime ga5
pp_compact ga5
pp_hook ga5 PostToolUse Bash subagent
pp_expect_silent "GA5 a subagent's tool call is silent"
pp_hook ga5 PostToolUse Read
pp_expect_fire "GA5 the pending flag is left for the main session"

echo "=== output shape ==="
pp_state seed ga6
pp_hook ga6 PostToolUse Bash
pp_expect_fire "GA6 the request starts with [progress check] and names the rule and the file" \
  "rules/progress-update.md" "ga6-session-progress.md" \
  "[progress check] time to update session-progress.md. Reasons:" \
  'Per rules/progress-update.md, rewrite "Current state" and add facts not yet recorded.' \
  "- step complete: workflow_init" \
  "If nothing changed, write nothing and continue. Use Edit only; do not explain."
case "$PP_CTX" in
  *"[handoff check]"*|*handoff-emergency-flush*) fail "GA6 no handoff-flush wording is left" "ctx=${PP_CTX:0:300}" ;;
  *) pass "GA6 no handoff-flush wording is left" ;;
esac
if [ -f "$WORKFLOW_PLANS_DIR/ga6-session-progress.md" ]; then pass "GA6 an active evaluation ensures session-progress.md"; else fail "GA6 an active evaluation ensures session-progress.md" "absent"; fi
GA7_OUT="$(printf 'not json' | run_with_timeout 60 node "$PP_HOOK" 2>/dev/null)"
GA7_RC=$?
case "$(printf '%s' "$GA7_OUT" | tr -d ' \r\n'):$GA7_RC" in
  ':0'|'{}:0') pass "GA7 malformed stdin is silent and exits 0" ;;
  *) fail "GA7 malformed stdin is silent and exits 0" "rc=$GA7_RC out=${GA7_OUT:0:200}" ;;
esac
