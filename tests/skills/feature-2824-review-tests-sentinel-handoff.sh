#!/usr/bin/env bash
# feature-2824-review-tests-sentinel-handoff.sh — #2824 Step 4: the forked /review-tests returns its sentinel.
# Tests: skills/review-tests/SKILL.md, skills/_shared/handoff-record.md
# Tags: scope:issue-specific, skills, review-tests, sentinel, skill-static, TL1, issue-2824
# TL1: static text checks over the worktree copies (LOCAL, not the deployed ~/.claude copies).
# A fork's sentinel never applies (workflow-mark.js refuses an agent_id payload), so RT-5b / RT-5c
# return a RUN-IN-MAIN line for the main conversation instead of echoing it in the fork.
# TL3 gap (not caught here): whether the main conversation really issues the returned line.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

RT_TMP="$(make_tmp)"
readonly RT_TMP
trap 'cd / || true; rm -rf "$RT_TMP"' EXIT
harness_isolate "$RT_TMP"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
cd "$RT_TMP" || exit 1

LOCAL_SKILL_MD="$SCRIPT_CHECKOUT_ROOT/skills/review-tests/SKILL.md"
LOCAL_HANDOFF_MD="$SCRIPT_CHECKOUT_ROOT/skills/_shared/handoff-record.md"

line_of() { grep -E "$1" "$2" 2>/dev/null | head -n 1; }

case_begin "H1 RT-5b and RT-5c return a RUN-IN-MAIN line" "skills/review-tests/SKILL.md"
check_returned() {
  local label="$1" sentinel="$2" text
  text="$(line_of "^- ${label}\\." "$LOCAL_SKILL_MD")"
  if [[ "$text" == *"RUN-IN-MAIN"* ]]; then pass "$label returns a RUN-IN-MAIN line"; else fail "$label returns a RUN-IN-MAIN line" "line=[$text]"; fi
  if [[ "$text" == *"$sentinel"* && "$text" == *'fingerprint=${FINGERPRINT}'* ]]; then
    pass "$label keeps the sentinel body ($sentinel, fingerprint)"
  else
    fail "$label keeps the sentinel body ($sentinel, fingerprint)" "line=[$text]"
  fi
  if [[ "$text" =~ ^-\ RT-5[bc]\.\ \([a-z/]+\)\ \`echo ]]; then
    fail "$label is not an echo for the fork to run" "line=[$text]"
  else
    pass "$label is not an echo for the fork to run"
  fi
}
check_returned "RT-5b" "WORKFLOW_REVIEW_TESTS_COMPLETE"
check_returned "RT-5c" "WORKFLOW_REVIEW_TESTS_WARNINGS"
case_end

case_begin "H2 the old emit wording is gone" "skills/review-tests/SKILL.md"
if grep -qi 'two separate Bash calls' "$LOCAL_SKILL_MD"; then
  fail "no 'two separate Bash calls'" "$(grep -ni 'two separate Bash calls' "$LOCAL_SKILL_MD")"
else
  pass "no 'two separate Bash calls'"
fi
if grep -qi 'emits\? exactly one' "$LOCAL_SKILL_MD"; then
  fail "no 'emit(s) exactly one' (Rules line and invariant)" "$(grep -ni 'emits\? exactly one' "$LOCAL_SKILL_MD")"
else
  pass "no 'emit(s) exactly one' (Rules line and invariant)"
fi
if grep -q 'exactly one RUN-IN-MAIN line' "$LOCAL_SKILL_MD"; then
  pass "the rule names exactly one RUN-IN-MAIN line"
else
  fail "the rule names exactly one RUN-IN-MAIN line" "no 'exactly one RUN-IN-MAIN line' in $LOCAL_SKILL_MD"
fi
case_end

case_begin "H3 the handoff-record trigger says returned" "skills/_shared/handoff-record.md"
trigger="$(line_of '`review-tests:sentinel`' "$LOCAL_HANDOFF_MD")"
if [[ "$trigger" == *"RT-5b / RT-5c returned a sentinel line"* ]]; then
  pass "review-tests:sentinel trigger is 'returned a sentinel line'"
else
  fail "review-tests:sentinel trigger is 'returned a sentinel line'" "row=[$trigger]"
fi
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
