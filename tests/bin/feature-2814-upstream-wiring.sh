#!/usr/bin/env bash
# tests/bin/feature-2814-upstream-wiring.sh
# Tests: skills/_shared/codex-review-loop/upstream-inconsistency-pause.md, skills/_shared/codex-review-loop.md, skills/_shared/codex-review-loop/exit-codes.md, skills/make-detail-plan/SKILL.md, agents/test-reviewer.md, agents/detail-planner.md, skills/_shared/priority-hierarchy/core.md, skills/_shared/priority-hierarchy.md
# Tags: TL1, static, wiring, review-loop, upstream-inconsistency, priority-hierarchy, issue-2814, scope:issue-specific, pwsh-not-required
# lang-check: ignore -- assertions match Japanese wording in the prompts under test.
# #2814 T5 wiring (static): the pause procedure exists with the A/D reviser table for the four
# formats, the fork branch, one AskUserQuestion with (recommended), the reset sentinel, and the
# B re-run inputs (B quote/defect, plus the A/D quote/defect and the verbatim D instruction);
# every orchestrator, CC fallback reviewer and planner points at it / at core.md and the tag.
# TL3 gap: a live orchestrator following the prose is not driven; this fixes the wiring only.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
WR_ROOT="$(make_tmp)"
readonly WR_ROOT
trap 'cd / 2>/dev/null; rm -rf "$WR_ROOT"' EXIT
harness_isolate "$WR_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID
cd "$WR_ROOT" || exit 1

R="$SCRIPT_CHECKOUT_ROOT"
PAUSE="$R/skills/_shared/codex-review-loop/upstream-inconsistency-pause.md"
CORE_REL="skills/_shared/priority-hierarchy/core.md"
CORE="$R/$CORE_REL"
ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$2 got=$3"; fi; }
# has <name> <file> <ERE> — the file holds a matching line.
has() { if [ -f "$2" ] && grep -q -E -e "$3" "$2"; then pass "$1"; else fail "$1" "no match for $3 in ${2#"$R"/}"; fi; }
# has_f <name> <file> <fixed> — the file holds the fixed string.
has_f() { if [ -f "$2" ] && grep -q -F -e "$3" "$2"; then pass "$1"; else fail "$1" "missing '$3' in ${2#"$R"/}"; fi; }
# line_all <name> <file> <ERE>... — some single line matches every ERE (case-insensitive).
line_all() {
  local n="$1" f="$2" c=0; shift 2
  if [ -f "$f" ]; then
    c="$(awk -v pats="$(printf '%s\034' "$@")" 'BEGIN{k=split(pats,P,"\034")-1} {l=tolower($0); ok=1; for(i=1;i<=k;i++) if (l !~ tolower(P[i])) ok=0; if (ok) c++} END{print c+0}' "$f")"
  fi
  if [ "$c" -gt 0 ]; then pass "$n"; else fail "$n" "no line of ${f#"$R"/} matches all of: $*"; fi
}
# row_cells <file> <format> — the cell count of the table row whose first cell is <format>.
row_cells() { [ -f "$1" ] || { printf none; return; }; awk -F'|' -v f="$2" '{c=$2; gsub(/[ `]/,"",c)} c==f{print NF-2; found=1; exit} END{if(!found) print "none"}' "$1"; }

case_begin "pause-doc-table-and-branches" "skills/_shared/codex-review-loop/upstream-inconsistency-pause.md"
if [ -f "$PAUSE" ]; then pass "pause: the procedure file exists"; else fail "pause: the procedure file exists" "absent"; fi
has "pause: the A/D table has a format column header" "$PAUSE" '^\|[[:space:]]*format[[:space:]]*\|'
for f in detail-plan outline-plan security-plan test-review; do
  ck "pause: the $f row has 4 cells (format, reviser, revised artifact, resume)" "4" "$(row_cells "$PAUSE" "$f")"
done
line_all "pause: detail-plan is revised by the detail-planner" "$PAUSE" '^\|[[:space:]]*`?detail-plan`?[[:space:]]*\|' 'detail-planner'
line_all "pause: outline-plan is revised by the outline-planner" "$PAUSE" '^\|[[:space:]]*`?outline-plan`?[[:space:]]*\|' 'outline-planner'
line_all "pause: security-plan resumes through /review-plan-security" "$PAUSE" '^\|[[:space:]]*`?security-plan`?[[:space:]]*\|' 'review-plan-security'
line_all "pause: test-review resumes through /review-tests" "$PAUSE" '^\|[[:space:]]*`?test-review`?[[:space:]]*\|' 'review-tests'
has_f "pause: the fork branch names context: fork" "$PAUSE" "context: fork"
has_f "pause: the fork branch returns an '## Upstream inconsistency' section" "$PAUSE" "## Upstream inconsistency"
has_f "pause: the user is asked through AskUserQuestion" "$PAUSE" "AskUserQuestion"
has_f "pause: the effective recommend is marked (recommended)" "$PAUSE" "(recommended)"
has "pause: B emits the reset sentinel with the upstream-inconsistency reason" "$PAUSE" 'WORKFLOW_RESET_FROM_[^:]*: upstream-inconsistency'
has_f "pause: B picks the most upstream step via pick-upstream" "$PAUSE" "pick-upstream"
has "pause: B clears the loop data via review-loop-upstream return" "$PAUSE" 'review-loop-upstream[^ ]* return'
has_f "pause: the approval screen lists Accepted upstream inconsistencies" "$PAUSE" "Accepted upstream inconsistencies"
case_end

# Coordinator revision 2 (detail 3-1): the B re-run also receives the A/D concerns'
# quote and defect and the verbatim D instruction.
case_begin "pause-doc-b-rerun-inputs" "skills/_shared/codex-review-loop/upstream-inconsistency-pause.md"
line_all "pause B re-run: the B concerns' quote and defect are passed" "$PAUSE" 'quote' 'defect' '(^|[^a-z])b([^a-z]|$)'
line_all "pause B re-run: the A/D concerns' quote and defect are passed" "$PAUSE" 'quote' 'defect' 'a ?/ ?d|a and d|a or d'
line_all "pause B re-run: the D instruction is passed verbatim" "$PAUSE" '(^|[^a-z])d([^a-z]|$)' 'instruction|指示' 'verbatim|逐語'
line_all "pause B re-run: the existing artifacts are passed for a diff revision" "$PAUSE" 'diff|差分' 'plan|artifact|成果物'
case_end

case_begin "pointers-and-skill-exception-lines" "skills/_shared/codex-review-loop.md"
# Controls: the helpers pass on text that exists today, so a failure below is a real absence.
has_f "control: exit-codes.md has the step e CONCERNS_LOG append" "$R/skills/_shared/codex-review-loop/exit-codes.md" "Append to \`CONCERNS_LOG\`"
line_all "control: line_all matches a line holding every pattern" "$R/skills/_shared/codex-review-loop/exit-codes.md" 'append' 'concerns_log' 'round'
has_f "pointer: codex-review-loop.md points at the pause procedure" "$R/skills/_shared/codex-review-loop.md" "upstream-inconsistency-pause.md"
has "pointer: exit-codes.md routes through the pause before CONCERNS_LOG" "$R/skills/_shared/codex-review-loop/exit-codes.md" 'upstream-inconsistency'
for s in make-detail-plan make-outline-plan review-plan-security review-tests; do
  has_f "skill $s: references the pause procedure" "$R/skills/$s/SKILL.md" "upstream-inconsistency-pause.md"
  has_f "skill $s: names the tag in its exception line" "$R/skills/$s/SKILL.md" "[upstream-inconsistency"
done
case_end

case_begin "cc-reviewers-reference-core-and-tag" "agents/test-reviewer.md"
for a in detail-reviewer outline-reviewer plan-security-reviewer test-reviewer; do
  has_f "reviewer $a: references core.md" "$R/agents/$a.md" "$CORE_REL"
  has_f "reviewer $a: references the [upstream-inconsistency tag" "$R/agents/$a.md" "[upstream-inconsistency"
done
case_end

# audit run-0011 2: a /review-tests rerun (round 2+) only confirms the previous round's fixes.
case_begin "test-reviewer-rerun-confirm-only" "agents/test-reviewer.md"
TR_RULES="$(awk '/^## /{r=($0=="## Rules")} r' "$R/agents/test-reviewer.md" 2>/dev/null)"
ck "test-reviewer: the Rules section is readable (precondition)" "yes" "$([ -n "$TR_RULES" ] && printf yes || printf no)"
TR_LINE="$(printf '%s\n' "$TR_RULES" | grep -iE 'round 2' | grep -iE 'only (confirm|check)[^.]*(fixed|resolved)' | grep -iE 'no new (concerns|findings)|not (raise|introduce) (any )?new (concerns|findings)' || true)"
ck "test-reviewer: one Rules line limits a round 2+ rerun to confirming the previous round's fixes, with no new findings" "yes" \
  "$([ -n "$TR_LINE" ] && printf yes || printf no)"
ck "test-reviewer: that line names the /review-tests rerun" "yes" \
  "$(printf '%s' "$TR_LINE" | grep -qF 'review-tests' && printf yes || printf no)"
ck "test-reviewer: that line scopes the fixes to the previous round" "yes" \
  "$(printf '%s' "$TR_LINE" | grep -qiE '(previous|prior|preceding|last) round' && printf yes || printf no)"
case_end

# audit run-0012 1: with B and C in one confirmation, C binds the current cycle only and the
# same inconsistency reported again in the next cycle after B is asked again.
case_begin "pause-doc-c-scope-current-cycle" "skills/_shared/codex-review-loop/upstream-inconsistency-pause.md"
ck "pause C scope: the pause procedure exists (precondition)" "yes" "$([ -f "$PAUSE" ] && printf yes || printf no)"
PD_LINE="$(grep -iE 'cycle' "$PAUSE" 2>/dev/null | grep -E '(^|[^A-Za-z])C([^A-Za-z]|$)' | grep -E '(^|[^A-Za-z])B([^A-Za-z]|$)' || true)"
ck "pause C scope: a line names B, C and the cycle together" "yes" "$([ -n "$PD_LINE" ] && printf yes || printf no)"
ck "pause C scope: that line limits C to the current cycle" "yes" \
  "$(printf '%s\n' "$PD_LINE" | grep -qiE '(current|this) cycle|現在の cycle' && printf yes || printf no)"
ck "pause C scope: that line asks again in the next cycle" "yes" \
  "$(printf '%s\n' "$PD_LINE" | grep -qiE 'next cycle|次の cycle' && printf yes || printf no)"
case_end

case_begin "planners-diff-revise-no-reject" "agents/detail-planner.md"
for p in detail-planner outline-planner; do
  f="$R/agents/$p.md"
  has_f "planner $p: has the accepted(upstream-inconsistency) disposition" "$f" "accepted(upstream-inconsistency)"
  line_all "planner $p: never rejects a tagged concern" "$f" 'upstream-inconsistency' 'reject' 'never|not|must not|禁止|しない'
  line_all "planner $p: revises as a diff against the existing artifact" "$f" 'diff|差分' 'existing|既存|previous|前回'
done
has_f "supplementary-rules.md: references core.md" "$R/agents/detail-planner/supplementary-rules.md" "$CORE_REL"
case_end

case_begin "core-md-shape" "skills/_shared/priority-hierarchy/core.md"
ck "core.md: exists and is at most 100 lines" "yes" "$([ -f "$CORE" ] && [ "$(wc -l < "$CORE")" -le 100 ] && printf yes || printf no)"
for d in deviation-add deviation-relax deviation-remove deviation-reinterpret upstream-conflict upstream-gap wording-only; do
  has_f "core.md: names the cause $d" "$CORE" "$d"
done
for f in detail-plan outline-plan security-plan test-review; do
  ck "core.md: the format table has a $f row" "yes" "$([ "$(row_cells "$CORE" "$f")" != none ] && printf yes || printf no)"
done
has_f "core.md: the tag format starts with the prefix" "$CORE" "[upstream-inconsistency cause="
case_end

# Detail 1-2: priority-hierarchy.md becomes the role layer over core.md (the legacy
# feature-647 file has no case markers, so these checks live here).
case_begin "priority-hierarchy-role-layer" "skills/_shared/priority-hierarchy.md"
PH="$R/skills/_shared/priority-hierarchy.md"
has_f "control: priority-hierarchy.md keeps the 647 rejection token" "$PH" "reject: contradicts approved"
has_f "priority-hierarchy.md: references core.md" "$PH" "$CORE_REL"
ck "priority-hierarchy.md: the deviation causes are left to core.md" "0" "$(if [ -f "$PH" ]; then awk 'index($0,"deviation-"){c++} END{print c+0}' "$PH"; else printf missing; fi)"
has_f "priority-hierarchy.md: the planner rule names the tag" "$PH" "[upstream-inconsistency "
line_all "priority-hierarchy.md: a tagged concern is answered by accept and revise" "$PH" 'upstream-inconsistency' 'accept and revise'
has_f "priority-hierarchy.md: the C disposition label" "$PH" "accepted(upstream-inconsistency)"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
