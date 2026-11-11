#!/usr/bin/env bash
# tests/agents/feature-2924-no-upstream-copy-prompts.sh
# Tests: skills/_shared/no-upstream-copy.md, agents/outline-planner.md, agents/outline-planner/output-format.md, agents/detail-planner.md, agents/outline-reviewer.md, agents/detail-reviewer.md, skills/_shared/codex-review-loop.md, bin/issue-snapshot
# Tags: TL1, static, prompt, planning, review, no-upstream-copy, accepted-tradeoffs, scope:issue-specific, pwsh-not-required, test-lang-exception:text-only
# lang-check: ignore — the assertions match plan-language marker values and plan text the code under test emits (functional data).
# #2924 test 8: the prompt layer after the copy ban. The planners and reviewers stay under their
# size limits (outline-planner.md at or under WARN after its split into sibling files), every
# writer and reviewer references the copy-ban SSOT, output-format.md has one Adopted approach,
# and the fallback reviewer launch hands over the resolver's merged-file path.
# TL3 gap: whether a live planner or reviewer actually stops copying upstream text.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
TMPROOT="$(make_tmp)"
readonly TMPROOT
trap 'cd / 2>/dev/null; rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT/iso"
unset CLAUDE_CODE_SESSION_ID
cd "$TMPROOT" || exit 1

R="$SCRIPT_CHECKOUT_ROOT"
SSOT="$R/skills/_shared/no-upstream-copy.md"
OP="$R/agents/outline-planner.md"
OF="$R/agents/outline-planner/output-format.md"
ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "${3:0:300}")"; fi; }
lines_of() { if [ -f "$1" ]; then awk 'END{print NR}' "$1"; else printf missing; fi; }
# within <file> <max> — "yes" when the file exists and has at most <max> lines.
within() { local n; n="$(lines_of "$1")"; if [ "$n" != missing ] && [ "$n" -le "$2" ]; then printf yes; else printf 'no(%s)' "$n"; fi; }
has() { if grep -q -F -e "$2" "$1" 2>/dev/null; then printf yes; else printf no; fi; }
hasE() { if grep -q -E -e "$2" "$1" 2>/dev/null; then printf yes; else printf no; fi; }

case_begin "prompt-files-within-size-limits" "agents/outline-planner.md"
ck "outline-planner.md is at or under the prompt WARN (100 lines)" "yes" "$(within "$OP" 100)"
for f in agents/detail-planner.md agents/outline-reviewer.md agents/detail-reviewer.md; do
  ck "$f stays under the prompt HARD (200 lines)" "yes" "$(within "$R/$f" 199)"
done
case_end

case_begin "outline-planner-split-into-siblings" "agents/outline-planner.md"
for s in mandatory-sections class-members revision-round; do
  ck "agents/outline-planner/$s.md exists" "yes" "$([ -s "$R/agents/outline-planner/$s.md" ] && printf yes || printf no)"
  ck "outline-planner.md points at outline-planner/$s.md" "yes" "$(has "$OP" "outline-planner/$s.md")"
done
ck "mandatory-sections.md: only Issues is carried, (outline) is written by the planner" "yes yes" \
  "$(has "$R/agents/outline-planner/mandatory-sections.md" '## Issues') $(has "$R/agents/outline-planner/mandatory-sections.md" 'Accepted Tradeoffs (outline)')"
case_end

case_begin "copy-ban-ssot-is-short-and-complete" "skills/_shared/no-upstream-copy.md"
ck "no-upstream-copy.md exists and is at most 20 lines (its full text enters the codex prompt)" "yes" "$(within "$SSOT" 20)"
ck "the SSOT names the one exception, the ## Issues carry" "yes" "$(has "$SSOT" '## Issues')"
ck "the SSOT tells each stage to write its own Accepted Tradeoffs (<stage>)" "yes" "$(has "$SSOT" 'Accepted Tradeoffs (')"
ck "the SSOT says an empty stage writes なし" "yes" "$(has "$SSOT" 'なし')"
case_end

case_begin "writers-and-reviewers-reference-the-ssot" "skills/_shared/no-upstream-copy.md"
for f in agents/outline-planner.md agents/detail-planner.md agents/outline-reviewer.md agents/detail-reviewer.md \
  skills/_shared/review-criteria.md skills/clarify-intent/SKILL.md skills/clarify-intent/reference/intent-md-schema.md \
  skills/make-detail-plan/SKILL.md; do
  ck "$f references no-upstream-copy.md" "yes" "$(has "$R/$f" 'no-upstream-copy.md')"
done
case_end

case_begin "output-format-has-one-adopted-approach" "agents/outline-planner/output-format.md"
ck "output-format.md has no '## Approach A' heading" "no" "$(hasE "$OF" '^## Approach A')"
ck "output-format.md has '## Adopted approach'" "yes" "$(hasE "$OF" '^## Adopted approach')"
ck "output-format.md has '## Considered alternatives (rejected)'" "yes" "$(hasE "$OF" '^## Considered alternatives \(rejected\)')"
ck "the Trade-off item points at ## Accepted Tradeoffs (outline)" "yes" "$(has "$OF" 'Accepted Tradeoffs (outline)')"
ck "SINGLE_APPROACH_JUSTIFIED gains an optional ACCEPTED_TRADEOFFS: line" "yes yes" "$(has "$OF" 'SINGLE_APPROACH_JUSTIFIED') $(has "$OF" 'ACCEPTED_TRADEOFFS:')"
ck "NEEDS_RESEARCH is kept" "yes" "$(has "$OF" 'NEEDS_RESEARCH')"
case_end

case_begin "reviewers-read-snapshot-and-own-stage" "agents/outline-reviewer.md"
for pair in "outline-reviewer:outline" "detail-reviewer:detail"; do
  a="${pair%%:*}"; st="${pair##*:}"; f="$R/agents/$a.md"
  ck "$a reads the issue snapshot through bin/issue-snapshot" "yes" "$(has "$f" 'bin/issue-snapshot')"
  ck "$a checks its own ## Accepted Tradeoffs ($st)" "yes" "$(has "$f" "Accepted Tradeoffs ($st)")"
done
ck "outline-reviewer points the cramming check at output-format.md" "yes" "$(has "$R/agents/outline-reviewer.md" 'outline-planner/output-format.md')"
case_end

# A worktree-relative call would run a bin/issue-snapshot the branch under review can rewrite.
SNAP_TOOL='bin/issue-snapshot'
SNAP_ABS="\$AGENTS_MAIN_ROOT/$SNAP_TOOL"
SNAP_REL='node "?(\./)?bin/issue-snapshot'

case_begin "outline-reviewer-runs-snapshot-from-main-root" "agents/outline-reviewer.md"
ck "outline-reviewer runs $SNAP_ABS" "yes" "$(has "$R/agents/outline-reviewer.md" "$SNAP_ABS")"
ck "outline-reviewer has no worktree-relative bin/issue-snapshot call" "no" "$(hasE "$R/agents/outline-reviewer.md" "$SNAP_REL")"
case_end

case_begin "detail-reviewer-runs-snapshot-from-main-root" "agents/detail-reviewer.md"
ck "detail-reviewer runs $SNAP_ABS" "yes" "$(has "$R/agents/detail-reviewer.md" "$SNAP_ABS")"
ck "detail-reviewer has no worktree-relative bin/issue-snapshot call" "no" "$(hasE "$R/agents/detail-reviewer.md" "$SNAP_REL")"
case_end

case_begin "snapshot-path-checks-catch-relative-mutation" "agents/outline-reviewer.md"
i=0
for variant in 'bin/issue-snapshot' '"bin/issue-snapshot"' './bin/issue-snapshot'; do
  i=$((i + 1)); mut="$TMPROOT/outline-reviewer-mut-$i.md"
  sed "s|\"$SNAP_ABS\"|$variant|g" "$R/agents/outline-reviewer.md" > "$mut"
  ck "mutation to node $variant changes the copy (precondition)" "yes" "$(cmp -s "$R/agents/outline-reviewer.md" "$mut" && printf no || printf yes)"
  ck "absolute-path check fails after mutation to node $variant" "no" "$(has "$mut" "$SNAP_ABS")"
  ck "relative-call check fires after mutation to node $variant" "yes" "$(hasE "$mut" "$SNAP_REL")"
done
case_end

case_begin "fallback-launch-passes-resolver-path" "skills/_shared/codex-review-loop.md"
CRL="$R/skills/_shared/codex-review-loop.md"
FB="$(grep -n -F 'Exit 3' "$CRL" 2>/dev/null | head -n 1 | cut -d: -f1)"
ck "codex-review-loop.md has the Exit 3 fallback line (precondition)" "yes" "$([ -n "$FB" ] && printf yes || printf no)"
WIN="$(awk -v s="${FB:-0}" 'NR>=s && NR<=s+6' "$CRL" 2>/dev/null)"
ck "the fallback launch calls bin/resolve-accepted-tradeoffs-file" "yes" "$(printf '%s' "$WIN" | grep -q -F 'resolve-accepted-tradeoffs-file' && printf yes || printf no)"
ck "the fallback launch hands the stdout path to the REVIEWER_AGENT prompt" "yes" "$(printf '%s' "$WIN" | grep -q -E 'REVIEWER_AGENT.*(path|stdout)|(path|stdout).*REVIEWER_AGENT' && printf yes || printf no)"
case_end

UNAVAIL='unavailable marker'
# line_has_both <file> <a> <b> — "yes" when one line of <file> contains both fixed strings.
line_has_both() { if grep -F -e "$2" "$1" 2>/dev/null | grep -q -F -e "$3"; then printf yes; else printf no; fi; }

case_begin "ssot-defines-unavailable-marker" "skills/_shared/no-upstream-copy.md"
ck "one SSOT line defines the unavailable marker as 'snapshot なし (<reason>)'" "yes" "$(line_has_both "$SSOT" "$UNAVAIL" 'snapshot なし (<reason>)')"
ck "the SSOT still defines the empty marker on its own line" "yes" "$(line_has_both "$SSOT" 'empty marker' 'なし')"
case_end

case_begin "outline-reviewer-points-at-unavailable-marker" "agents/outline-reviewer.md"
ck "outline-reviewer names the unavailable marker of no-upstream-copy.md on one line" "yes" "$(line_has_both "$R/agents/outline-reviewer.md" "$UNAVAIL" 'no-upstream-copy.md')"
case_end

case_begin "detail-reviewer-points-at-unavailable-marker" "agents/detail-reviewer.md"
ck "detail-reviewer names the unavailable marker of no-upstream-copy.md on one line" "yes" "$(line_has_both "$R/agents/detail-reviewer.md" "$UNAVAIL" 'no-upstream-copy.md')"
case_end

# marker_matches <ssot> <value> — "yes" when the SSOT's unavailable-marker line holds <value>.
marker_matches() { line_has_both "$1" "$UNAVAIL" "$2"; }

case_begin "ssot-marker-matches-cli-value" "bin/issue-snapshot"
CLI_MARK="$(sed -n 's/^const NO_SNAPSHOT = "\([^"]*\)";.*/\1/p' "$R/bin/issue-snapshot" 2>/dev/null | head -n 1)"
ck "NO_SNAPSHOT is extracted from bin/issue-snapshot and non-empty (precondition)" "yes" "$([ -n "$CLI_MARK" ] && printf yes || printf no)"
if [ -n "$CLI_MARK" ]; then
  ck "the SSOT unavailable-marker line carries the CLI value '$CLI_MARK'" "yes" "$(marker_matches "$SSOT" "$CLI_MARK")"
  DRIFT="$TMPROOT/no-upstream-copy-drift.md"
  sed 's/snapshot なし (<reason>)/snapshot missing (<reason>)/' "$SSOT" > "$DRIFT"
  ck "the drifted SSOT copy differs from the original (precondition)" "yes" "$(cmp -s "$SSOT" "$DRIFT" && printf no || printf yes)"
  ck "the drifted copy keeps its unavailable-marker line (precondition)" "yes" "$(hasE "$DRIFT" "$UNAVAIL")"
  ck "the match check reports a mismatch on the drifted copy" "no" "$(marker_matches "$DRIFT" "$CLI_MARK")"
fi
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
