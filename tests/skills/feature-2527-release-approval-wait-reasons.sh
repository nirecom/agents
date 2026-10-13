#!/usr/bin/env bash
# feature-2527-release-approval-wait-reasons.sh — #2527: GA-1 lets every wait verdict reach the preflight.
# Tests: skills/get-release-approval/SKILL.md, bin/workflow/lib/next-step/release-wait.js
# Tags: scope:issue-specific, skills, get-release-approval, release-phase, skill-static, TL1, issue-2527
# TL1: static text checks over the worktree copies (LOCAL, not the deployed ~/.claude copies).
# TL3 gap (not caught here): whether the model, given REASON=web-merge-*, really continues to
# GA-2 instead of stopping at GA-1.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

GA_TMP="$(make_tmp)"
readonly GA_TMP
trap 'cd / || true; rm -rf "$GA_TMP"' EXIT
harness_isolate "$GA_TMP"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
cd "$GA_TMP" || exit 1

LOCAL_SKILL_MD="$SCRIPT_CHECKOUT_ROOT/skills/get-release-approval/SKILL.md"
RELEASE_WAIT_JS="$SCRIPT_CHECKOUT_ROOT/bin/workflow/lib/next-step/release-wait.js"

check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=[$3] got=[$2]"; fi; }

# GA-1's own lines: from the "GA-1." label up to (not including) the "GA-2." label.
ga1=""
if [[ -f "$LOCAL_SKILL_MD" ]]; then
  ga1="$(awk '/^GA-2\./ { on = 0 } /^GA-1\./ { on = 1 } on' "$LOCAL_SKILL_MD")"
fi
# The line of GA-1 that sends a verdict on to GA-2.
ga1_continue="$(printf '%s\n' "$ga1" | grep -F 'continue to GA-2' || true)"

# Every reason release-wait.js returns together with the skill (an invoke verdict); a verdict
# with skill "" is a blocked one and never reaches the skill.
skill_reasons=""
if [[ -f "$RELEASE_WAIT_JS" ]]; then
  skill_reasons="$(grep -E 'skill:[[:space:]]*SKILL\b' "$RELEASE_WAIT_JS" | sed -n 's/.*reason:[[:space:]]*"\([^"]*\)".*/\1/p' | sort -u)"
fi

case_begin "D1 GA-1 sends web-merge-pending and web-merge-not-ready on to GA-2" "skills/get-release-approval/SKILL.md"
if [[ -n "$ga1" ]]; then pass "GA-1 block found"; else fail "GA-1 block found" "no GA-1. label in $LOCAL_SKILL_MD"; fi
check "exactly one GA-1 line continues to GA-2" "$(printf '%s' "$ga1_continue" | grep -c . || true)" "1"
for reason in web-merge-pending web-merge-not-ready; do
  if [[ "$ga1_continue" == *"\`$reason\`"* ]]; then pass "$reason is on the continue-to-GA-2 line"; else fail "$reason is on the continue-to-GA-2 line" "line=[$ga1_continue]"; fi
done
if [[ "$ga1_continue" == *"REASON="* ]]; then pass "the line is keyed on REASON="; else fail "the line is keyed on REASON=" "line=[$ga1_continue]"; fi
# The catch-all stays after the continue line, so it cannot swallow the two wait reasons first.
cont_no="$(printf '%s\n' "$ga1" | grep -n -F 'continue to GA-2' | head -n 1 | cut -d: -f1)"
other_no="$(printf '%s\n' "$ga1" | grep -n -F 'Any other `REASON=`' | head -n 1 | cut -d: -f1)"
if [[ -n "$cont_no" && -n "$other_no" && "$cont_no" -lt "$other_no" ]]; then
  pass "the continue line precedes the any-other-REASON catch-all"
else
  fail "the continue line precedes the any-other-REASON catch-all" "continue=[$cont_no] catch-all=[$other_no]"
fi
case_end

case_begin "D2 sanity: release-wait.js returns the skill with the two wait reasons" "bin/workflow/lib/next-step/release-wait.js"
check "reasons returned with skill get-release-approval" "$(printf '%s' "$skill_reasons" | tr '\n' ' ')" "web-merge-not-ready web-merge-pending"
if grep -Eq '^const SKILL[[:space:]]*=.*(STEP_TO_SKILL\.user_verification|"get-release-approval")' "$RELEASE_WAIT_JS" 2>/dev/null; then
  pass "SKILL is the user_verification skill"
else
  fail "SKILL is the user_verification skill" "no matching const SKILL in $RELEASE_WAIT_JS"
fi
case_end

case_begin "D2 every reason returned with the skill is named in GA-1" "skills/get-release-approval/SKILL.md"
n=0
while IFS= read -r reason; do
  [[ -n "$reason" ]] || continue
  n=$((n + 1))
  if [[ "$ga1_continue" == *"\`$reason\`"* ]]; then pass "GA-1 names $reason"; else fail "GA-1 names $reason" "GA-1=[$ga1]"; fi
done <<< "$skill_reasons"
if [[ "$n" -ge 1 ]]; then pass "at least one reason was checked ($n)"; else fail "at least one reason was checked" "release-wait.js yielded no skill reason"; fi
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
