# shellcheck shell=bash
# tests/skills/feature-2263-subagent-dispatch-prompts/inventory.sh
# Tests: skills/write-code/SKILL.md, skills/write-tests/SKILL.md, agents/test-reviewer.md
# Tags: TL2, skills, dispatch, inventory, scope:issue-specific, pwsh-not-required
# The detail plan's 19-item dispatch inventory as DATA (the test-side SSOT). Items 3 and 10
# carry two sites each, so 21 rows. Sites are found by anchor pattern, never by line number.

# Row: id|file|anchor-ere|lo|hi|form   (form: plain | json | delegated:<id>)
INV_ROWS=(
  '1|skills/write-code/SKILL.md|^WCD-4\. |0|12|plain'
  '2|skills/write-tests/SKILL.md|^WT-7\. |0|25|plain'
  '3a|skills/make-outline-plan/SKILL.md|Delegate to \*\*outline-planner\*\*|0|3|plain'
  '3b|skills/make-outline-plan/SKILL.md|^MOP-C1\. |0|0|delegated:5'
  '4|skills/make-detail-plan/SKILL.md|Delegate to \*\*planner\*\*|0|3|plain'
  '5|skills/_shared/jev-two-stage-judge.md|^[-*#[:space:]]*JJ-2[^0-9]|0|10|plain'
  '6|skills/_shared/codex-review-loop.md|^Every REVIEWER_AGENT .*launch passes|0|2|json'
  '7|skills/_shared/codex-review-loop/exit-codes.md|silently launch .REVIEWER_AGENT. subagent|0|0|delegated:6'
  '8|skills/review-plan-codex/SKILL.md|before\*\* launching reviewer subagent|0|4|plain'
  '9|skills/review-plan-security/SKILL.md|launch .plan-security-reviewer. subagent|0|2|plain'
  '10a|skills/review-tests/SKILL.md|^RT-0\. |-4|-1|plain'
  '10b|skills/review-tests/SKILL.md|launch .test-reviewer. subagent|0|2|plain'
  '11|skills/review-code-security/SKILL.md|^RCS-2\. |0|2|json'
  '12|skills/issue-create/SKILL.md|^2b\. Invoke the .issue-create-survey-worker.|0|2|json'
  '13|skills/deep-research/SKILL.md|^DR-1\. |0|8|json'
  '14|skills/refactor-prompts/SKILL.md|Resolve .<PLANS_DIR>.|0|2|plain'
  '15|skills/resume-session/scripts/summarize-transcript-tail.md|^## Brief|-5|12|plain'
  '16|skills/workflow-init/SKILL.md|^### WI-10 |0|5|plain'
  '17|skills/sweep-tests/SKILL.md|^STE-4\. |0|2|plain'
  '18|skills/survey-code/SKILL.md|Use Explore subagents|-1|2|plain'
  '19|agents/test-reviewer.md|^Do not call Edit/Write|0|2|plain'
)

declare -A INV_RESULT=()
echo "=== inventory: every dispatch site references the ${SECTION_NAME} section ==="
case_begin "INV-sites-reference-section" "skills/write-code/SKILL.md"
for row in "${INV_ROWS[@]}"; do
  ROWS=$((ROWS + 1))
  IFS='|' read -r id file anchor lo hi form <<< "$row"
  case "$form" in
    delegated:*) INV_RESULT[$id]="delegated" ;;
    *) INV_RESULT[$id]="$(inv_verdict "$SCRIPT_CHECKOUT_ROOT" "$file" "$anchor" "$lo" "$hi" "$form")"
       ck "INV#$id: $file references the section near /$anchor/${form/plain/}" "yes" "${INV_RESULT[$id]}" ;;
  esac
done
case_end

case_begin "INV-delegated-rows" "skills/write-code/SKILL.md"
for row in "${INV_ROWS[@]}"; do
  IFS='|' read -r id file anchor lo hi form <<< "$row"
  case "$form" in delegated:*) ;; *) continue ;; esac
  to="${form#delegated:}"
  ck "INV#$id: $file still has its anchor and is covered by INV#$to" "anchor-present|yes" \
    "$(grep -qE -- "$anchor" "$SCRIPT_CHECKOUT_ROOT/$file" 2>/dev/null && echo anchor-present || echo anchor-missing)|${INV_RESULT[$to]:-unknown}"
done
case_end

# #2460 JJ-2 is the one judge dispatch: inside its own block (up to the JJ-3 label) it must
# reference the section and hand the subagent the JEV_INPUT_FILE path.
case_begin "INV-jj2-block" "skills/write-code/SKILL.md"
JJ_DOC="$SCRIPT_CHECKOUT_ROOT/skills/_shared/jev-two-stage-judge.md"
JJ2_BLOCK="$(awk '/^[-*#[:space:]]*JJ-2[^0-9]/ { on = 1 } on && /^[-*#[:space:]]*JJ-3[^0-9]/ { exit } on { print }' "$JJ_DOC" 2>/dev/null)"
ck "INV#5: JJ-2 block exists in skills/_shared/jev-two-stage-judge.md" "yes" "$([ -n "$JJ2_BLOCK" ] && echo yes || echo no)"
ck "INV#5: JJ-2 block references the ${SECTION_NAME} section" "yes" \
  "$(printf '%s\n' "$JJ2_BLOCK" | grep -qF -- "$SECTION_NAME" && echo yes || echo no)"
ck "INV#5: JJ-2 block passes JEV_INPUT_FILE to the subagent" "yes" \
  "$(printf '%s\n' "$JJ2_BLOCK" | grep -qF -- 'JEV_INPUT_FILE' && echo yes || echo no)"
ck "INV#5: JJ-2 dispatches only on RESULT=need-subagent" "yes" \
  "$(printf '%s\n' "$JJ2_BLOCK" | grep -qF -- 'RESULT=need-subagent' && echo yes || echo no)"
case_end

# The canonical line is owned by the rule; a dispatch site references it and never copies it.
case_begin "INV-no-canonical-copy" "skills/write-code/SKILL.md"
INV_COPIES="$(grep -rlF -- 'counting every blocked or rejected command' "$SCRIPT_CHECKOUT_ROOT/skills" "$SCRIPT_CHECKOUT_ROOT/agents" 2>/dev/null | sed "s#^$SCRIPT_CHECKOUT_ROOT/##" | tr '\n' ' ')"
ck "INV: no skill or agent file copies the canonical line's text" "" "$INV_COPIES"
case_end
