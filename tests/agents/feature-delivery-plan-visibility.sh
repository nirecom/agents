#!/usr/bin/env bash
# Tests: agents/detail-planner.md, agents/outline-planner.md, skills/clarify-intent/SKILL.md, skills/make-detail-plan/SKILL.md, skills/make-outline-plan/SKILL.md
# Tags: clarify-intent, planning, outline, detail, intent
set -uo pipefail

REPO=$(git rev-parse --show-toplevel)
PASS=0
FAIL=0

assert() {
  local desc="$1"
  local result="$2"
  if [ "$result" = "0" ]; then
    echo "OK: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc"
    ((FAIL++))
  fi
}

# Assertion 10 (checked first): all 6 target files must exist
TARGET_FILES=(
  "agents/outline-planner.md"
  "agents/detail-planner.md"
  "skills/make-outline-plan/SKILL.md"
  "skills/make-detail-plan/SKILL.md"
  "skills/clarify-intent/SKILL.md"
  "rules/docs.md"
)
MISSING=0
for f in "${TARGET_FILES[@]}"; do
  if [ ! -f "$REPO/$f" ]; then
    echo "FAIL: missing required target file: $f"
    ((MISSING++))
  fi
done
if [ "$MISSING" -gt 0 ]; then
  FAIL=$((FAIL + MISSING))
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  echo "ERROR: $MISSING required target file(s) missing — aborting remaining assertions."
  exit 1
fi
echo "OK: all 6 target files exist"
((PASS++))

# Assertion 1: agents/outline-planner.md contains **Delivery plan:**
grep -qF '**Delivery plan:**' "$REPO/agents/outline-planner.md"; assert "outline-planner.md contains '**Delivery plan:**'" "$?"

# Assertion 2: SINGLE_APPROACH_JUSTIFIED section contains DELIVERY_PLAN: within 20 lines
DELIVERY_PLAN_DIST=$(awk '
  /SINGLE_APPROACH_JUSTIFIED:/ { start=NR }
  start && /DELIVERY_PLAN:/ { print NR - start; start=0 }
' "$REPO/agents/outline-planner.md" | head -1)
if [ -n "$DELIVERY_PLAN_DIST" ] && [ "$DELIVERY_PLAN_DIST" -le 20 ]; then
  echo "OK: outline-planner.md SINGLE_APPROACH_JUSTIFIED has DELIVERY_PLAN: within $DELIVERY_PLAN_DIST line(s)"
  ((PASS++))
else
  echo "FAIL: outline-planner.md SINGLE_APPROACH_JUSTIFIED does not have DELIVERY_PLAN: within 20 lines (got: '${DELIVERY_PLAN_DIST:-not found}')"
  ((FAIL++))
fi

# Assertion 3: detail-planner.md has **Delivery plan** before **Background** in step-3 block
DP_LINE=$(awk '/Produce a plan/{found=1} found && /^##/{exit} found && /\*\*Delivery plan/{print NR; exit}' "$REPO/agents/detail-planner.md")
BG_LINE=$(awk '/Produce a plan/{found=1} found && /^##/{exit} found && /\*\*Background/{print NR; exit}' "$REPO/agents/detail-planner.md")
if [ -n "$DP_LINE" ] && [ -n "$BG_LINE" ] && [ "$DP_LINE" -lt "$BG_LINE" ]; then
  echo "OK: detail-planner.md has **Delivery plan** (line $DP_LINE) before **Background** (line $BG_LINE) in step-3 block"
  ((PASS++))
else
  echo "FAIL: detail-planner.md **Delivery plan** not found before **Background** in step-3 block (Delivery plan line: '${DP_LINE:-not found}', Background line: '${BG_LINE:-not found}')"
  ((FAIL++))
fi

# Assertion 4: make-outline-plan/SKILL.md contains DELIVERY_PLAN:
grep -qF 'DELIVERY_PLAN:' "$REPO/skills/make-outline-plan/SKILL.md"; assert "make-outline-plan/SKILL.md contains 'DELIVERY_PLAN:'" "$?"

# Assertion 5: make-outline-plan/SKILL.md Output Schema section mentions Delivery plan
grep -A 20 '## Output Schema' "$REPO/skills/make-outline-plan/SKILL.md" | grep -qE 'Delivery plan'; assert "make-outline-plan/SKILL.md Output Schema mentions 'Delivery plan'" "$?"

# Assertion 6: make-outline-plan/SKILL.md contains prose preamble instruction
grep -qiE '(prose|preamble)' "$REPO/skills/make-outline-plan/SKILL.md"; assert "make-outline-plan/SKILL.md contains prose/preamble instruction" "$?"

# Assertion 7: make-detail-plan/SKILL.md has 'delivery plan' before first AskUserQuestion
DP_DETAIL_LINE=$(grep -in 'delivery plan' "$REPO/skills/make-detail-plan/SKILL.md" | head -1 | cut -d: -f1)
AUQ_LINE=$(grep -in 'AskUserQuestion' "$REPO/skills/make-detail-plan/SKILL.md" | head -1 | cut -d: -f1)
if [ -n "$DP_DETAIL_LINE" ] && [ -n "$AUQ_LINE" ] && [ "$DP_DETAIL_LINE" -lt "$AUQ_LINE" ]; then
  echo "OK: make-detail-plan/SKILL.md has 'delivery plan' (line $DP_DETAIL_LINE) before first AskUserQuestion (line $AUQ_LINE)"
  ((PASS++))
else
  echo "FAIL: make-detail-plan/SKILL.md 'delivery plan' not found before AskUserQuestion (delivery plan line: '${DP_DETAIL_LINE:-not found}', AskUserQuestion line: '${AUQ_LINE:-not found}')"
  ((FAIL++))
fi

# Assertion 8: clarify-intent/SKILL.md contains CONFIRM_OUTLINE
grep -q 'CONFIRM_OUTLINE' "$REPO/skills/clarify-intent/SKILL.md"; assert "clarify-intent/SKILL.md contains 'CONFIRM_OUTLINE'" "$?"

# Assertion 9: none of the 6 target files contain 配送単位
FORBIDDEN_FOUND=0
for f in "${TARGET_FILES[@]}"; do
  if grep -q '配送単位' "$REPO/$f"; then
    echo "FAIL: forbidden term '配送単位' found in $f"
    ((FORBIDDEN_FOUND++))
    ((FAIL++))
  fi
done
if [ "$FORBIDDEN_FOUND" -eq 0 ]; then
  echo "OK: no target files contain forbidden term '配送単位'"
  ((PASS++))
fi

# Summary
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
