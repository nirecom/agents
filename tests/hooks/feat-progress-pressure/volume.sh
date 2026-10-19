# 4c — the transcript grew 2MiB (or 60 minutes passed with growth) since the baseline; both
# thresholds halve after a risk signal. An update of session-progress.md moves the baseline. Never
# output at Stop. Sourced by ../feat-progress-pressure.sh inside its case block.

echo "=== 4c: the 2MiB edge ==="
pp_prime vo1
pp_state grow vo1 $((2 * MiB - 1))
pp_hook vo1 PostToolUse Read
pp_expect_silent "VO1 2MiB-1 of growth is silent"
pp_state grow vo1 1
pp_hook vo1 PostToolUse Read
pp_expect_fire "VO1 2MiB of growth asks for an update (any tool)" progress
pp_hook vo1 PostToolUse Read
pp_expect_silent "VO1 the request moved the baseline (the next call is silent)"

echo "=== 4c: UserPromptSubmit is a candidate ==="
pp_prime vo2
pp_state grow vo2 $((2 * MiB))
pp_hook vo2 UserPromptSubmit
pp_expect_fire "VO2 UserPromptSubmit carries the volume request"
case "$PP_EVT" in
  UserPromptSubmit) pass "VO2 hookEventName matches the event" ;;
  *) fail "VO2 hookEventName matches the event" "hookEventName=$PP_EVT" ;;
esac

echo "=== 4c: never at Stop ==="
pp_prime vo3
pp_state grow vo3 $((2 * MiB))
pp_hook vo3 Stop
pp_expect_silent "VO3 Stop does not carry a volume request"
pp_hook vo3 PostToolUse Read
pp_expect_fire "VO3 the next PostToolUse carries it (Stop did not consume it)"

echo "=== 4c: a risk halves the volume threshold ==="
pp_prime vo4
pp_state risk vo4
pp_state grow vo4 $((MiB + 1))
pp_hook vo4 PostToolUse Read
pp_expect_fire "VO4 1MiB after a risk signal asks for an update"
pp_prime vo5
pp_state grow vo5 $((MiB + 1))
pp_hook vo5 PostToolUse Read
pp_expect_silent "VO5 1MiB without a risk signal is silent"

echo "=== 4c: the 60-minute timer ==="
pp_prime vo6
pp_age vo6 61
pp_state grow vo6 4096
pp_hook vo6 PostToolUse Read
pp_expect_fire "VO6 61 minutes with growth asks for an update"
pp_prime vo7
pp_age vo7 59
pp_state grow vo7 4096
pp_hook vo7 PostToolUse Read
pp_expect_silent "VO7 59 minutes with growth is silent"
pp_prime vo8
pp_age vo8 61
pp_hook vo8 PostToolUse Read
pp_expect_silent "VO8 61 minutes without growth is silent (an idle session is not asked)"
pp_prime vo9
pp_state risk vo9
pp_age vo9 31
pp_state grow vo9 4096
pp_hook vo9 PostToolUse Read
pp_expect_fire "VO9 31 minutes with growth after a risk signal asks for an update"

echo "=== 4c: an update of session-progress.md moves the baseline ==="
pp_prime vo10
pp_state grow vo10 $((2 * MiB))
pp_state touch-progress vo10
pp_hook vo10 PostToolUse Read
pp_expect_silent "VO10 growth before a session-progress.md update is forgiven"
pp_state grow vo10 $((2 * MiB))
pp_hook vo10 PostToolUse Read
pp_expect_fire "VO10 growth after the update counts again"
