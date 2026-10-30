#!/usr/bin/env bash
# tests/bin/feat-2430-step-terminology.sh
# Tests: docs/glossary/user.md, docs/glossary/internal.md, docs/architecture/claude-code/workflow.md, docs/architecture/claude-code/workflow-runtime.md, docs/architecture/claude-code/settings/hooks.md, README.md, CLAUDE.md, rules/progress-update.md, docs/architecture/claude-code/state-handoff-record.md
# Tags: terminology, glossary, docs, handoff, static-check, regression-2430, regression-2594, regression-2652, state-handoff-record, progress-update, scope:issue-specific, pwsh-not-required, TL1

# Issue #2430 — "step" drifted between three meanings (a workflow step, a numbered line inside a skill procedure, a conversational turn) and the docs disagreed on how many workflow steps exist (16 vs 17). The glossary becomes the one owner of the three terms, the prose stops restating a count that VALID_STEPS already owns (CPR-SSOT), the flush rule owns "What to record", and the handoff class table files a RESET_FROM under class E (a sentinel emitted).
# Issue #2529 split the glossary by category: workflow step lives in docs/glossary/user.md, in-skill step and turn in docs/glossary/internal.md, and entries no longer carry file paths.
# Issue #2652 renamed docs/architecture/claude-code/handoff-artifact.md to state-handoff-record.md and replaced the glossary's "handoff artifact" entry with "state handoff record" (user); RESET_FROM keeps its class E row (the state handoff reader derives the reset-from entry from the `reset` event), and the two-reader claims move with the doc and the entry.

set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$3 got=${2:0:300}"; fi; }

# section <file> <level-2 heading> — the body of one "## " section.
section() { awk -v h="## $2" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$1"; }

# entry <file> <term> — the body of one "### <term>" glossary entry.
entry() { awk -v h="### $2" '{ sub(/\r$/, "") } $0 == h { on = 1; next } /^##+ / { on = 0 } on' "$1" 2>/dev/null; }

GL_USER="$SCRIPT_CHECKOUT_ROOT/docs/glossary/user.md"
GL_INTERNAL="$SCRIPT_CHECKOUT_ROOT/docs/glossary/internal.md"

case_begin "glossary-owns-the-three-terms" "docs/glossary/user.md"
expect "S1: glossary/user.md has a '### workflow step' entry" "$(grep -cx '### workflow step' "$GL_USER" 2>/dev/null)" "1"
expect "S1: glossary/internal.md has a '### in-skill step' entry" "$(grep -cx '### in-skill step' "$GL_INTERNAL" 2>/dev/null)" "1"
expect "S1: glossary/internal.md has a '### turn' entry" "$(grep -cx '### turn' "$GL_INTERNAL" 2>/dev/null)" "1"
expect "S1: the workflow step entry is non-empty" "$([ -n "$(entry "$GL_USER" 'workflow step')" ] && echo yes || echo no)" "yes"
case_end

# A count of the whole step set (16 or 17, the two values that disagreed) in
# prose that should point at VALID_STEPS instead of restating its length.
COUNT_RE='\b1[67][- ](workflow[- ])?(steps?|units)\b'
no_count() {
    if [ ! -s "$SCRIPT_CHECKOUT_ROOT/$1" ]; then fail "S2: $1 states no workflow-step count" "$1 missing or empty"; return; fi
    expect "S2: $1 states no workflow-step count" "$(grep -nEi "$COUNT_RE" "$SCRIPT_CHECKOUT_ROOT/$1" 2>/dev/null)" ""
}

case_begin "glossary-states-no-step-count" "docs/glossary/user.md"
no_count docs/glossary/user.md
no_count docs/glossary/internal.md
case_end

case_begin "workflow-doc-states-no-step-count" "docs/architecture/claude-code/workflow.md"
no_count docs/architecture/claude-code/workflow.md
case_end

case_begin "workflow-runtime-doc-states-no-step-count" "docs/architecture/claude-code/workflow-runtime.md"
no_count docs/architecture/claude-code/workflow-runtime.md
case_end

case_begin "hooks-settings-doc-states-no-step-count" "docs/architecture/claude-code/settings/hooks.md"
no_count docs/architecture/claude-code/settings/hooks.md
case_end

case_begin "readme-states-no-step-count" "README.md"
no_count README.md
case_end

case_begin "claude-md-states-no-step-count" "CLAUDE.md"
no_count CLAUDE.md
case_end

# #2594 renamed the flush rule to rules/progress-update.md: it still owns what the model
# records, now as the four kinds of fact written to session-progress.md instead of classes C/D/F.
case_begin "progress-rule-owns-what-to-record" "rules/progress-update.md"
RULE="$SCRIPT_CHECKOUT_ROOT/rules/progress-update.md"
expect "S3: the progress rule exists" "$([ -f "$RULE" ] && echo yes || echo no)" "yes"
for kind in 'decision' 'deviation' 'reject' 'open question'; do
    expect "S3: the progress rule names the '$kind' fact" "$(grep -qi -- "$kind" "$RULE" 2>/dev/null && echo yes || echo no)" "yes"
done
expect "S3: the progress rule no longer says to flush when a step ends" "$(grep -c 'Flush also when a step ends' "$RULE" 2>/dev/null)" "0"
LINES="$(wc -l < "$RULE" 2>/dev/null | tr -d ' ')"
expect "S3: the progress rule stays under 200 lines" "$([ "${LINES:-0}" -gt 0 ] && [ "$LINES" -lt 200 ] && echo yes || echo "no:${LINES:-missing}")" "yes"
case_end

case_begin "class-table-files-reset-from-under-e" "docs/architecture/claude-code/state-handoff-record.md"
DOC="$SCRIPT_CHECKOUT_ROOT/docs/architecture/claude-code/state-handoff-record.md"
expect "S4: the state handoff record doc exists" "$([ -f "$DOC" ] && echo yes || echo no)" "yes"
expect "S4: the class E row names RESET_FROM" "$(grep -E '^\| *E *\|' "$DOC" 2>/dev/null | grep -c 'RESET_FROM')" "1"
expect "S4: no other class row names RESET_FROM" "$(grep -E '^\| *[ABCDFG] *\|' "$DOC" 2>/dev/null | grep -c 'RESET_FROM')" "0"
expect "S4: the retired handoff-artifact.md is gone" "$([ -e "$SCRIPT_CHECKOUT_ROOT/docs/architecture/claude-code/handoff-artifact.md" ] && echo present || echo gone)" "gone"
case_end

# #2475: the supervisor codex engine became a second (read-only) handoff reader.
# #2594: the supervisor reads session-progress.md too (the PROGRESS block), so the renamed rule must
# not claim a single reader either.
case_begin "progress-rule-claims-no-single-reader" "rules/progress-update.md"
RULE="$SCRIPT_CHECKOUT_ROOT/rules/progress-update.md"
expect "S5: the progress rule exists" "$([ -f "$RULE" ] && echo yes || echo no)" "yes"
expect "S5: the progress rule does not say nothing else consumes the file" "$(grep -c 'nothing else consumes it' "$RULE" 2>/dev/null)" "0"
case_end

case_begin "handoff-doc-names-two-readers" "docs/architecture/claude-code/state-handoff-record.md"
DOC="$SCRIPT_CHECKOUT_ROOT/docs/architecture/claude-code/state-handoff-record.md"
expect "S5: the state handoff record doc exists" "$([ -f "$DOC" ] && echo yes || echo no)" "yes"
expect "S5: the doc does not call /resume-session the only reader" "$(grep -c "only reader is \`/resume-session\`" "$DOC" 2>/dev/null)" "0"
expect "S5: the doc names the supervisor codex engine" "$(grep -qiE 'supervisor.{0,40}codex|codex.{0,40}supervisor' "$DOC" 2>/dev/null && echo yes || echo no)" "yes"
case_end

case_begin "glossary-handoff-names-two-readers" "docs/glossary/user.md"
HA="$(entry "$GL_USER" 'state handoff record')"
expect "S5: glossary/user.md has a state handoff record entry" "$([ -n "$HA" ] && echo yes || echo no)" "yes"
expect "S5: the state handoff record entry names /resume-session" "$(printf '%s\n' "$HA" | grep -qF '/resume-session' && echo yes || echo no)" "yes"
expect "S5: the state handoff record entry names the supervisor" "$(printf '%s\n' "$HA" | grep -qi 'supervisor' && echo yes || echo no)" "yes"
expect "S5: glossary/user.md no longer has a handoff artifact entry" "$(grep -cx '### handoff artifact' "$GL_USER" 2>/dev/null)" "0"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
