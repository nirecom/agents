#!/usr/bin/env bash
# tests/hooks/feat-progress-nudge-acceptance.sh
# Tests: hooks/progress-nudge.js, hooks/post-compact.js
# Tags: progress-file, progress-pressure, progress-nudge, acceptance, compaction, cap, scope:issue-specific, pwsh-not-required, TL2
# Issue #2594 acceptance — whole sessions, not single edges: a long run without user prompts
# still gets asked, a prompt-heavy run is asked no more than the old handoff nudge asked, each
# step complete is reported once, and an inactive session hears nothing.
# TDD (write_code has not run): every case is expected to FAIL with the hook absent.
set -u

# TL3 gap (what this test does NOT catch):
# - real elapsed time (time is moved by ageing the session's files 5 minutes per step)
# - a real compaction by Claude Code (post-compact.js gets the envelope by hand)
# - the old hook run on the same fixture: it is removed by this change, so AC2 compares with
#   the old rule (2MiB, or 60 min with growth, no cap) computed here
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

PP_TMP="$(make_tmp)"
readonly PP_TMP
trap 'rm -rf "$PP_TMP" 2>/dev/null || true' EXIT
mkdir -p "$PP_TMP/home" "$PP_TMP/transcripts" "$PP_TMP/neutral" "$PP_TMP/plans"
export WORKFLOW_STATE_DIR="$(np "$PP_TMP/wf")" WORKFLOW_PLANS_DIR="$(np "$PP_TMP/plans")"
export HOME="$(np "$PP_TMP/home")" USERPROFILE="$(np "$PP_TMP/home")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$PP_TMP/transcripts")"
unset CLAUDE_CODE_SESSION_ID
cd "$PP_TMP/neutral" || exit 1

PP_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feat-progress-pressure"
# shellcheck source=feat-progress-pressure/_lib.sh
. "$PP_DIR/_lib.sh"
KiB=1024

# max_in_hour <step...> — the most fires inside any window shorter than 12 steps (60 min).
max_in_hour() {
  local a b n max=0
  for a in "$@"; do
    n=0
    for b in "$@"; do [ "$b" -ge "$a" ] && [ $((b - a)) -lt 12 ] && n=$((n + 1)); done
    [ "$n" -gt "$max" ] && max=$n
  done
  printf '%s' "$max"
}

case_begin "unattended-run-is-asked-within-cap" "hooks/progress-nudge.js"
# 150 minutes, no user prompt: 400KiB of tool output and one Read every 5 minutes, a
# compaction every 40 minutes.
pp_prime ac1
AC1_FIRES=()
for step in $(seq 1 30); do
  pp_age ac1 5
  pp_state grow ac1 $((400 * KiB))
  [ $((step % 8)) -eq 0 ] && pp_compact ac1
  pp_hook ac1 PostToolUse Read
  pp_fired && AC1_FIRES+=("$step")
done
echo "  AC1 requests at steps: ${AC1_FIRES[*]:-none}"
if [ "${#AC1_FIRES[@]}" -ge 1 ]; then pass "AC1 a run without user prompts is still asked to update"; else fail "AC1 a run without user prompts is still asked to update" "0 requests in 150 min"; fi
AC1_MAX="$(max_in_hour "${AC1_FIRES[@]:-}")"
if [ "${AC1_MAX:-0}" -le 2 ]; then pass "AC1 no 60-minute window holds more than two requests"; else fail "AC1 no 60-minute window holds more than two requests" "max=$AC1_MAX steps=${AC1_FIRES[*]}"; fi
case_end

case_begin "prompt-heavy-run-is-not-asked-more" "hooks/progress-nudge.js"
# 90 minutes of frequent prompts, 300KiB every 5 minutes.
pp_prime ac2
AC2_NEW=0
for step in $(seq 1 18); do
  pp_age ac2 5
  pp_state grow ac2 $((300 * KiB))
  pp_hook ac2 UserPromptSubmit
  pp_fired && AC2_NEW=$((AC2_NEW + 1))
done
# The old rule on the same series: fire at 2MiB since the baseline, or 60 min with growth.
AC2_OLD=0 since=0 mins=0
for step in $(seq 1 18); do
  since=$((since + 300 * KiB)) mins=$((mins + 5))
  if [ "$since" -ge $((2 * MiB)) ] || [ "$mins" -ge 60 ]; then AC2_OLD=$((AC2_OLD + 1)) since=0 mins=0; fi
done
echo "  AC2 new=$AC2_NEW old-rule=$AC2_OLD"
if [ "$AC2_NEW" -ge 1 ] && [ "$AC2_NEW" -le "$AC2_OLD" ]; then pass "AC2 a prompt-heavy run is asked at least once and no more often than before"; else fail "AC2 a prompt-heavy run is asked at least once and no more often than before" "new=$AC2_NEW old=$AC2_OLD"; fi
case_end

case_begin "each-step-complete-reported-once" "hooks/progress-nudge.js"
pp_prime ac3
AC3_SEEN=""
for st in research outline detail write_tests; do
  pp_state mark ac3 "$st"
  pp_hook ac3 PostToolUse Bash
  case "$PP_CTX" in *"$st"*) AC3_SEEN="$AC3_SEEN $st" ;; esac
  pp_hook ac3 PostToolUse Bash
  case "$PP_CTX" in *"$st"*) AC3_SEEN="$AC3_SEEN again:$st" ;; esac
done
if [ "$AC3_SEEN" = " research outline detail write_tests" ]; then pass "AC3 every step complete is reported exactly once"; else fail "AC3 every step complete is reported exactly once" "seen=$AC3_SEEN"; fi
case_end

case_begin "inactive-session-hears-nothing" "hooks/progress-nudge.js"
pp_state seed ac4
pp_state pause ac4
AC4_OUT=""
for step in 1 2 3; do
  pp_state grow ac4 $((3 * MiB))
  pp_compact ac4
  pp_state mark ac4 research
  for ev in "PostToolUse Bash" "PostToolUse Read" "UserPromptSubmit -" "Stop -"; do
    # shellcheck disable=SC2086
    pp_hook ac4 $ev
    case "$(printf '%s' "$PP_OUT" | tr -d ' \r\n')" in ''|'{}') : ;; *) AC4_OUT="$AC4_OUT [$ev] ${PP_OUT:0:120}" ;; esac
  done
done
if [ -z "$AC4_OUT" ]; then pass "AC4 a paused session gets no output on any event"; else fail "AC4 a paused session gets no output on any event" "$AC4_OUT"; fi
if [ -e "$WORKFLOW_PLANS_DIR/ac4-session-progress.md" ]; then fail "AC4 no session-progress.md is created for it" "created"; else pass "AC4 no session-progress.md is created for it"; fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
