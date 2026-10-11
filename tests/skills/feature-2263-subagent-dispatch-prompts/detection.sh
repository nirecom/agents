# shellcheck shell=bash
# tests/skills/feature-2263-subagent-dispatch-prompts/detection.sh
# Tests: skills/write-code/SKILL.md, skills/write-tests/SKILL.md, agents/survey-history.md
# Tags: TL2, skills, dispatch, inventory, detection, scope:issue-specific, pwsh-not-required
# Every line under skills/ and agents/ that reads like an Agent-tool launch must be owned by a
# coverage row: an inventory item (inv:<id>), a write-less exempt agent (exempt:<agent>), or a
# named exclusion (excl:<reason>). A new dispatch site without a row fails here.

DET_ERE='subagent_type|mode: *"default"|Agent tool|Task tool|(launch|dispatch|invoke|delegate|spawn).{0,60}subagent'

# Row: file|line-ere|disposition   (the ere is matched against the hit line's text)
DET_ROWS=(
  'skills/deep-research/SKILL.md|subagent_type: "web-researcher"|inv:13'
  'skills/issue-create/SKILL.md|^2b\. Invoke the .issue-create-survey-worker.|inv:12'
  'skills/make-detail-plan/SKILL.md|dispatch .subagent_type: complexity-judge.|exempt:complexity-judge'
  'skills/make-detail-plan/SKILL.md|Delegate to \*\*planner\*\*|inv:4'
  'skills/make-outline-plan/SKILL.md|dispatch .subagent_type: complexity-judge.|exempt:complexity-judge'
  'skills/make-outline-plan/SKILL.md|Delegate to \*\*outline-planner\*\*|inv:3a'
  'skills/make-outline-plan/SKILL.md|^MOP-C1\. |inv:3b'
  'skills/resume-session/SKILL.md|launch a subagent per .skills/resume-session/scripts/summarize-transcript-tail\.md|inv:15'
  'skills/review-code-codex/SKILL.md|Do \*\*not\*\* spawn a subagent|excl:negated-launch'
  'skills/review-plan-codex/SKILL.md|launching reviewer subagent|inv:8'
  'skills/review-plan-security/SKILL.md|launch .plan-security-reviewer. subagent|inv:9'
  'skills/review-tests/SKILL.md|launch .test-reviewer. subagent|inv:10b'
  'skills/survey-code/SKILL.md|When invoked as a parallel Agent subagent|excl:invoked-side'
  'skills/survey-history/SKILL.md|When invoked as a parallel Agent subagent|excl:invoked-side'
  'skills/survey-history/SKILL.md|When invoked as a subagent, do NOT emit|excl:invoked-side'
  'skills/sweep-tests/SKILL.md|^STE-4\. |inv:17'
  'skills/write-code/SKILL.md|Dispatch .subagent_type: complexity-judge.|exempt:complexity-judge'
  'skills/write-code/SKILL.md|^WCD-4\. |inv:1'
  'skills/write-tests/SKILL.md|Dispatch .subagent_type: complexity-judge.|exempt:complexity-judge'
  'skills/write-tests/SKILL.md|^WT-7\. |inv:2'
  'skills/_shared/codex-review-loop/exit-codes.md|silently launch .REVIEWER_AGENT. subagent|inv:7'
  'skills/_shared/complexity-and-outline-skip.md|^Dispatch .subagent_type: complexity-judge.|exempt:complexity-judge'
  'skills/_shared/complexity-and-outline-skip.md|subagent_type=skip-verifier|inv:5'
  'skills/_shared/judge-task-complexity.md|before launching a subagent\. Not invoked via the Skill tool|excl:rubric-not-launch'
  'skills/_shared/worker-dispatch.md|LLM subagent \(Task tool|excl:naming-convention'
  'agents/survey-history.md|When invoked as a parallel Agent subagent|excl:invoked-side'
)

# det_hits <root> -> "file:line:text" per detection hit; lines naming the section are references, not launches.
det_hits() {
  (cd "$1" && grep -rnE --include='*.md' -- "$DET_ERE" skills agents 2>/dev/null) | grep -vF -- "$SECTION_NAME"
}

# det_uncovered <root> <rows-array-name> -> "file:line" per hit no row owns
det_uncovered() {
  local -n _rows="$2"
  local hit f rest text row rf re disp ok
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    f="${hit%%:*}"; rest="${hit#*:}"; text="${rest#*:}"
    ok=0
    for row in "${_rows[@]}"; do
      IFS='|' read -r rf re disp <<< "$row"
      [ "$rf" = "$f" ] || continue
      if [[ "$text" =~ $re ]]; then ok=1; break; fi
    done
    [ "$ok" -eq 1 ] || printf '%s:%s\n' "$f" "${rest%%:*}"
  done < <(det_hits "$1")
}

# det_row_verdict <root> <row> -> ok | stale | bad-inv:<id> | not-exempt:<agent> | bad-disposition
det_row_verdict() {
  local rf re disp
  IFS='|' read -r rf re disp <<< "$2"
  grep -qE -- "$re" "$1/$rf" 2>/dev/null || { printf 'stale'; return; }
  case "$disp" in
    inv:*) inv_id_known "${disp#inv:}" || { printf 'bad-inv:%s' "${disp#inv:}"; return; } ;;
    exempt:*) [ "$(agent_exempt "$1/agents/${disp#exempt:}.md")" = "yes" ] || { printf 'not-exempt:%s' "${disp#exempt:}"; return; } ;;
    excl:?*) ;;
    *) printf 'bad-disposition'; return ;;
  esac
  printf 'ok'
}

inv_id_known() {
  local r
  for r in "${INV_ROWS[@]}"; do [ "${r%%|*}" = "$1" ] && return 0; done
  return 1
}

echo "=== detection: every launch-like line is owned by a coverage row ==="
case_begin "DET-rows-valid" "skills/write-code/SKILL.md"
for row in "${DET_ROWS[@]}"; do
  ROWS=$((ROWS + 1))
  ck "DET row ${row%%|*} /$(printf '%s' "$row" | cut -d'|' -f2)/ is live and its disposition holds" \
    "ok" "$(det_row_verdict "$SCRIPT_CHECKOUT_ROOT" "$row")"
done
case_end

case_begin "DET-no-uncovered-hit" "skills/write-tests/SKILL.md"
DET_HIT_COUNT="$(det_hits "$SCRIPT_CHECKOUT_ROOT" | grep -c .)"
if [ "$DET_HIT_COUNT" -gt 0 ]; then pass "DET: the detection ERE finds launch lines (${DET_HIT_COUNT} hits; anti-vacuity)"
else fail "DET: the detection ERE finds launch lines" "0 hits; the scan is vacuous"; fi
ck "DET: every hit under skills/ and agents/ is owned by a coverage row" "" \
  "$(det_uncovered "$SCRIPT_CHECKOUT_ROOT" DET_ROWS | tr '\n' ' ')"
case_end
