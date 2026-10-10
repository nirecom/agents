#!/usr/bin/env bash
# tests/bin/feat-2430-step-terminology.sh
# Tests: docs/glossary.md, docs/architecture/claude-code/workflow.md, docs/architecture/claude-code/workflow-runtime.md, docs/architecture/claude-code/settings/hooks.md, README.md, CLAUDE.md, rules/handoff-emergency-flush.md, docs/architecture/claude-code/handoff-artifact.md
# Tags: terminology, glossary, docs, handoff, static-check, regression-2430, scope:issue-specific, pwsh-not-required, TL1

# Issue #2430 — "step" drifted between three meanings (a workflow step, a numbered line inside a skill procedure, a conversational turn) and the docs disagreed on how many workflow steps exist (16 vs 17). The glossary becomes the one owner of the three terms, the prose stops restating a count that VALID_STEPS already owns (CPR-SSOT), the flush rule owns "What to record", and the handoff class table files a RESET_FROM under class E (a sentinel emitted).

# TDD (write_code has not run): every case is expected to FAIL until the docs are updated.

set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$3 got=${2:0:300}"; fi; }

# section <file> <level-2 heading> — the body of one "## " section.
section() { awk -v h="## $2" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$1"; }

case_begin "glossary-owns-the-three-terms" "docs/glossary.md"
WF="$(section "$SCRIPT_CHECKOUT_ROOT/docs/glossary.md" Workflow)"
for term in 'workflow step' 'in-skill step' 'turn'; do
    expect "S1: glossary ## Workflow has a '### $term' entry" "$(printf '%s\n' "$WF" | grep -cx "### $term")" "1"
done
case_end

# A count of the whole step set (16 or 17, the two values that disagreed) in
# prose that should point at VALID_STEPS instead of restating its length.
COUNT_RE='\b1[67][- ](workflow[- ])?(steps?|units)\b'
no_count() { expect "S2: $1 states no workflow-step count" "$(grep -nEi "$COUNT_RE" "$SCRIPT_CHECKOUT_ROOT/$1" 2>/dev/null)" ""; }

case_begin "glossary-states-no-step-count" "docs/glossary.md"
no_count docs/glossary.md
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

case_begin "flush-rule-owns-what-to-record" "rules/handoff-emergency-flush.md"
RULE="$SCRIPT_CHECKOUT_ROOT/rules/handoff-emergency-flush.md"
expect "S3: the flush rule has a '## What to record' section" "$(grep -cx '## What to record' "$RULE")" "1"
WHAT="$(section "$RULE" 'What to record')"
for cls in C D F; do
    expect "S3: 'What to record' names class $cls" "$(printf '%s\n' "$WHAT" | grep -qE "(^|[^A-Za-z])$cls([^A-Za-z]|$)" && echo yes || echo no)" "yes"
done
expect "S3: the flush rule no longer says to flush when a step ends" "$(grep -c 'Flush also when a step ends' "$RULE")" "0"
LINES="$(wc -l < "$RULE" | tr -d ' ')"
expect "S3: the flush rule stays under 100 lines" "$([ "$LINES" -lt 100 ] && echo yes || echo "no:$LINES")" "yes"
case_end

case_begin "class-table-files-reset-from-under-e" "docs/architecture/claude-code/handoff-artifact.md"
DOC="$SCRIPT_CHECKOUT_ROOT/docs/architecture/claude-code/handoff-artifact.md"
expect "S4: the class E row names RESET_FROM" "$(grep -E '^\| *E *\|' "$DOC" | grep -c 'RESET_FROM')" "1"
expect "S4: no other class row names RESET_FROM" "$(grep -E '^\| *[ABCDFG] *\|' "$DOC" | grep -c 'RESET_FROM')" "0"
case_end

# #2475: the supervisor codex engine became a second (read-only) handoff reader.
case_begin "flush-rule-names-two-handoff-readers" "rules/handoff-emergency-flush.md"
RULE="$SCRIPT_CHECKOUT_ROOT/rules/handoff-emergency-flush.md"
expect "S5: the flush rule no longer says nothing else consumes the artifact" "$(grep -c 'nothing else consumes it' "$RULE")" "0"
expect "S5: the flush rule names the supervisor as a reader" "$(grep -qi 'supervisor' "$RULE" && echo yes || echo no)" "yes"
case_end

case_begin "handoff-doc-names-two-readers" "docs/architecture/claude-code/handoff-artifact.md"
DOC="$SCRIPT_CHECKOUT_ROOT/docs/architecture/claude-code/handoff-artifact.md"
expect "S5: the handoff doc no longer calls /resume-session the only reader" "$(grep -c "only reader is \`/resume-session\`" "$DOC")" "0"
expect "S5: the handoff doc names the supervisor codex engine" "$(grep -qiE 'supervisor.{0,40}codex|codex.{0,40}supervisor' "$DOC" && echo yes || echo no)" "yes"
case_end

case_begin "glossary-handoff-names-two-readers" "docs/glossary.md"
GL_LINE="$(grep -F -- '-handoff.md`' "$SCRIPT_CHECKOUT_ROOT/docs/glossary.md" | grep -F 'resume-session')"
expect "S5: glossary handoff definition names the supervisor as a reader" "$(printf '%s\n' "$GL_LINE" | grep -qi 'supervisor' && echo yes || echo no)" "yes"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
