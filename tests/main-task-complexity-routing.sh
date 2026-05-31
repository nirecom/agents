#!/usr/bin/env bash
# Tests: skills/_shared/judge-task-complexity.md, skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md
# Tags: task-complexity-routing
# Structural tests for judge-task-complexity routing implementation.
# Grep-only — no LLM calls.

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

check() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc — pattern not found: $pattern"
  fi
}

check_re() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc — pattern not found: $pattern"
  fi
}

# ---------------------------------------------------------------------------
# judge-task-complexity/SKILL.md
# ---------------------------------------------------------------------------

JUDGE="$AGENTS_DIR/skills/_shared/judge-task-complexity.md"

check "judge: file exists" "Shared rubric" "$JUDGE"
check "judge: signal S1-multi-file" "S1-multi-file" "$JUDGE"
check "judge: signal S2-architecture" "S2-architecture" "$JUDGE"
check "judge: signal S3-security" "S3-security" "$JUDGE"
check "judge: signal S4-installer" "S4-installer" "$JUDGE"
check "judge: signal S5-breaking" "S5-breaking" "$JUDGE"
check "judge: signal S6-long-plan" "S6-long-plan" "$JUDGE"
check "judge: output format opus" "VERDICT: opus |" "$JUDGE"
check "judge: output format sonnet" "VERDICT: sonnet | none" "$JUDGE"
check "judge: parse failure → opus" "err toward higher capability" "$JUDGE"
check "judge: S3 covers docs-only" "regardless of whether the change is code-only, docs-only" "$JUDGE"

# ---------------------------------------------------------------------------
# make-detail-plan/SKILL.md
# ---------------------------------------------------------------------------

MDP="$AGENTS_DIR/skills/make-detail-plan/SKILL.md"

check "make-detail-plan: judge-task-complexity invocation" "judge-task-complexity" "$MDP"
check "make-detail-plan: Model selected output" "Model selected:" "$MDP"
check "make-detail-plan: model: param in Agent step" "model: <model from step 2>" "$MDP"
check "make-detail-plan: skip judge in skip conditions" "skip \`judge-task-complexity\`" "$MDP"

# Steps 1-6 present with no gap
for n in 1 2 3 4 5 6; do
  check_re "make-detail-plan: step $n present" "^$n\." "$MDP"
done

# Preserved sections
check "make-detail-plan: Research Escalation preserved" "## Research Escalation" "$MDP"
check "make-detail-plan: Round counters preserved" "revision_rounds" "$MDP"
check "make-detail-plan: Re-prompt template preserved" "Re-prompt template" "$MDP"
check "make-detail-plan: Skip Conditions preserved" "## Skip Conditions" "$MDP"
check "make-detail-plan: Skipping the Plan Step preserved" "## Skipping the Plan Step Entirely" "$MDP"
check "make-detail-plan: Rules preserved" "## Rules" "$MDP"
check "make-detail-plan: Completion preserved" "## Completion" "$MDP"

# ---------------------------------------------------------------------------
# write-tests/SKILL.md
# ---------------------------------------------------------------------------

WT="$AGENTS_DIR/skills/write-tests/SKILL.md"

check "write-tests: judge-task-complexity invocation" "judge-task-complexity" "$WT"
check "write-tests: Model selected output" "Model selected:" "$WT"

for n in 5 6 7; do
  check_re "write-tests: step $n present" "^$n\." "$WT"
done


# Edge cases
check "judge: err toward higher capability (parse failure)" "err toward higher capability" "$JUDGE"

# ---------------------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
