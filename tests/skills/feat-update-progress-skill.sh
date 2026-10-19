#!/usr/bin/env bash
# feat-update-progress-skill.sh — #2594 stage 4: /update-progress rewrites session-progress.md in the main conversation.
# Tests: skills/update-progress/SKILL.md
# Tags: scope:issue-specific, skills, update-progress, progress-file, skill-static, TL1, regression-2594
# TL1: static text checks over the worktree copy (LOCAL, not the deployed ~/.claude copy).
# TL3 gap (not caught here): whether the model, given /update-progress, really edits session-progress.md
# itself and prints only the path. Mitigated at WORKFLOW_USER_VERIFIED preflight.
# TDD (write_code has not run): every case is expected to FAIL until the skill exists.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

UP_TMP="$(make_tmp)"
readonly UP_TMP
trap 'cd / || true; rm -rf "$UP_TMP"' EXIT
harness_isolate "$UP_TMP"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
cd "$UP_TMP" || exit 1

LOCAL_SKILL_MD="$SCRIPT_CHECKOUT_ROOT/skills/update-progress/SKILL.md"
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=[$3] got=[$2]"; fi; }
has() { if [[ -f "$LOCAL_SKILL_MD" ]] && grep -qiE -- "$2" "$LOCAL_SKILL_MD"; then pass "$1"; else fail "$1" "no match for /$2/ in $LOCAL_SKILL_MD"; fi; }

check "K1: skills/update-progress/SKILL.md exists" "$([[ -f "$LOCAL_SKILL_MD" ]] && echo yes || echo no)" "yes"

LINES="$(wc -l < "$LOCAL_SKILL_MD" 2>/dev/null | tr -d ' ')"
check "K2: SKILL.md stays under the 200-line prompt HARD limit" "$([[ -n "$LINES" && "$LINES" -lt 200 ]] && echo yes || echo "no:${LINES:-missing}")" "yes"

# The longest fenced code block, in body lines (a procedure of 3+ lines belongs in a script).
LONGEST="$(awk '/^[[:space:]]*```/ { if (on) { if (n > max) max = n; on = 0 } else { on = 1; n = 0 } next } on { n++ } END { print max + 0 }' "$LOCAL_SKILL_MD" 2>/dev/null)"
check "K3: no fenced code block of 3 or more lines" "$([[ -f "$LOCAL_SKILL_MD" && "${LONGEST:-0}" -lt 3 ]] && echo yes || echo "no:${LONGEST:-missing}")" "yes"

has "K4: the skill ensures the file through bin/progress-file ensure --session" 'bin/progress-file ensure[^`]*--session'
has "K4: the ensure call passes --reason update-progress (so the run is counted)" 'bin/progress-file ensure[^`]*--reason update-progress'
has "K5: the skill follows rules/progress-update.md" 'rules/progress-update\.md'
has "K5: the skill rewrites the Current state section" 'Current state'
has "K6: the skill says the main conversation performs the update itself" 'The main conversation does this itself'
has "K6: the same rule forbids delegating it to a subagent" 'The main conversation does this itself; do not delegate it to a subagent\.'
has "K6: the write is done with the Edit tool (by the main conversation, not a dispatched agent)" 'Write with the Edit tool only'
if [[ -f "$LOCAL_SKILL_MD" ]] && grep -qiE '(delegate|dispatch|launch|spawn)[^.]*\b(subagent|Agent tool)\b' "$LOCAL_SKILL_MD" && ! grep -qiE '(do not|never|not)[^.]*(delegate|dispatch|launch|spawn)' "$LOCAL_SKILL_MD"; then
  fail "K6: the skill never tells the model to delegate to a subagent" "a delegation directive without a negation"
elif [[ -f "$LOCAL_SKILL_MD" ]]; then
  pass "K6: the skill never tells the model to delegate to a subagent"
else
  fail "K6: the skill never tells the model to delegate to a subagent" "SKILL.md missing"
fi
REPORT_SECTION="$(awk '/^#+ .*Report/ { on = 1; next } on && /^#+ / { exit } on' "$LOCAL_SKILL_MD" 2>/dev/null)"
check "K7: the Report section shows the updated path to the user in one line" \
  "$(grep -qiE 'path' <<<"$REPORT_SECTION" && grep -qiE 'one line' <<<"$REPORT_SECTION" && echo yes || echo "no:[${REPORT_SECTION:0:200}]")" "yes"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
