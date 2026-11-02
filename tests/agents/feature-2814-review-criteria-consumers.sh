#!/usr/bin/env bash
# tests/agents/feature-2814-review-criteria-consumers.sh
# Tests: agents/lib/nfr-severity-calibration.md, agents/detail-reviewer.md, agents/outline-reviewer.md, agents/plan-security-reviewer.md, agents/test-reviewer.md, agents/security-scanner.md, skills/_shared/severity.md, skills/issue-create/SKILL.md, skills/_shared/test-design.md, skills/review-tests/SKILL.md, rules/mid-workflow-findings.md, rules/github-issues.md, .github/labels.yml, bin/github-issues/issue-create.sh, skills/_shared/codex-review-loop/upstream-inconsistency-pause.md, agents/supervisor-audit.md, agents/supervisor-audit/course-correction-lookup.md
# Tags: TL1, static, review-criteria, severity, upstream-inconsistency, course-correction, issue-2814, scope:issue-specific, pwsh-not-required
# #2814 reopen T1/T2/T7 (static part): the CC reviewers fetch the review criteria block through
# the calibration doc; severity has one definition (skills/_shared/severity.md) that every former
# definer references; the pause procedure looks up course-correction records before asking.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
CO_ROOT="$(make_tmp)"
readonly CO_ROOT
trap 'cd / 2>/dev/null; rm -rf "$CO_ROOT"' EXIT
harness_isolate "$CO_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID
cd "$CO_ROOT" || exit 1

R="$SCRIPT_CHECKOUT_ROOT"
CALIB="agents/lib/nfr-severity-calibration.md"
SEV_REF="skills/_shared/severity.md"
ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "${3:0:300}")"; fi; }
# has <rel> <text> — yes / no / missing (a missing file never passes a "no" check).
has() { if [ ! -f "$R/$1" ]; then printf missing; elif grep -q -F -- "$2" "$R/$1"; then printf yes; else printf no; fi; }

case_begin "reviewers-fetch-criteria-via-calibration" "agents/lib/nfr-severity-calibration.md"
for a in detail-reviewer outline-reviewer plan-security-reviewer test-reviewer security-scanner; do
  ck "$a: fetches the review criteria block through the calibration doc" "yes" \
    "$(has "agents/$a.md" 'Fetch the review criteria block by the reviewer steps of `agents/lib/nfr-severity-calibration.md` and apply it.')"
done
ck "calibration: names bin/review-criteria-block" "yes" "$(has "$CALIB" 'bin/review-criteria-block')"
ck "calibration: still names bin/project-nfr-block" "yes" "$(has "$CALIB" 'bin/project-nfr-block')"
ck "calibration: no 'standard adversarial'" "no" "$(has "$CALIB" 'standard adversarial')"
ck "calibration: reviewers never Read the two files directly" "yes" \
  "$(has "$CALIB" 'never Read `agents/lib/review-criteria.md` or `skills/_shared/severity.md` directly')"
case_end

case_begin "reviewer-thoroughness-words-removed" "agents/detail-reviewer.md"
for w in "Thorough" "flag minor" "minor issues" "Knock-out" "nice-to-have"; do
  ck "detail-reviewer: no '$w'" "no" "$(has agents/detail-reviewer.md "$w")"
done
for w in "Knock-out" "nice-to-have"; do
  ck "outline-reviewer: no '$w'" "no" "$(has agents/outline-reviewer.md "$w")"
done
ck "detail-reviewer: reports only concerns meeting the Reporting minimum" "yes" \
  "$(has agents/detail-reviewer.md 'Report only concerns that meet the Reporting minimum of the review criteria.')"
for a in detail-reviewer outline-reviewer; do
  ck "$a: tags severity by the delivered definition" "yes" "$(has "agents/$a.md" 'Tag severity by the severity definition in the review criteria block.')"
done
case_end

case_begin "former-definers-reference-severity-md" "skills/_shared/severity.md"
ck "severity.md exists (precondition)" "yes" "$([ -f "$R/$SEV_REF" ] && printf yes || printf no)"
for f in skills/issue-create/SKILL.md skills/_shared/test-design.md skills/review-tests/SKILL.md rules/mid-workflow-findings.md rules/github-issues.md .github/labels.yml bin/github-issues/issue-create.sh bin/github-issues/severity-audit.sh; do
  ck "$f: references $SEV_REF" "yes" "$(has "$f" "$SEV_REF")"
done
ck "issue-create: keeps the no-inference sentence" "yes" "$(has skills/issue-create/SKILL.md 'no script under `bin/` infers severity')"
case_end

case_begin "old-tier-wording-removed" "skills/_shared/test-design.md"
ck "test-design: no 'critical:' tier" "no" "$(has skills/_shared/test-design.md 'critical:')"
ck "review-tests: no 'critical and high'" "no" "$(has skills/review-tests/SKILL.md 'critical and high')"
ck "review-tests: no '\`high\`-tier gap'" "no" "$(has skills/review-tests/SKILL.md '`high`-tier gap')"
case_end

PAUSE="skills/_shared/codex-review-loop/upstream-inconsistency-pause.md"
case_begin "pause-looks-up-course-corrections" "skills/_shared/codex-review-loop/upstream-inconsistency-pause.md"
ck "pause: runs the locate CLI" "yes" "$(has "$PAUSE" 'course-correction-record" locate')"
ck "pause: dispatches the lookup mode" "yes" "$(has "$PAUSE" 'course-correction lookup mode')"
ck "pause: the fork returns list-args" "yes" "$(has "$PAUSE" 'list-args:')"
ck "pause: the fork returns the surviving count" "yes" "$(has "$PAUSE" 'Other surviving concerns:')"
ck "pause: a course-correction row is not asked again" "yes" "$(has "$PAUSE" 'prior_choice=course-correction')"
ck "supervisor-audit: names the lookup file" "yes" "$(has agents/supervisor-audit.md 'agents/supervisor-audit/course-correction-lookup.md')"
ck "lookup: records through decide --choice course-correction" "yes" "$(has agents/supervisor-audit/course-correction-lookup.md '--choice course-correction')"
ck "core.md: a course-correction record is not a deviation" "yes" "$(has skills/_shared/priority-hierarchy/core.md '## User course corrections')"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
