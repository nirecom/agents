#!/usr/bin/env bash
# Tests: skills/review-tests/SKILL.md
# Tags: frontmatter, tests, review, scope:common
# Structural tests for skills/review-tests/SKILL.md
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$SCRIPT_CHECKOUT_ROOT"
PASS=0
FAIL=0
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SKILL="$ROOT/skills/review-tests/SKILL.md"

echo "=== review-tests skill structural tests ==="

case_begin "skill-file-exists" "skills/review-tests/SKILL.md"
# --- Normal case 1: SKILL.md exists ---
if [ -f "$SKILL" ]; then
    pass "SKILL.md exists"
else
    fail "SKILL.md does not exist"
fi
case_end

case_begin "frontmatter-required-fields" "skills/review-tests/SKILL.md"
# --- Normal case 2: frontmatter has required fields ---
for field in name description model; do
    if [ -f "$SKILL" ] && grep -qE "^${field}:" "$SKILL" 2>/dev/null; then
        pass "frontmatter has '$field'"
    else
        fail "frontmatter missing '$field'"
    fi
done
case_end

case_begin "name-field-correct" "skills/review-tests/SKILL.md"
# --- Normal case 3: name field is review-tests ---
if [ -f "$SKILL" ] && grep -qE '^name: review-tests$' "$SKILL" 2>/dev/null; then
    pass "name is 'review-tests'"
else
    fail "name is not 'review-tests'"
fi
case_end

case_begin "model-is-sonnet" "skills/review-tests/SKILL.md"
# --- Normal case 4: model is sonnet ---
if [ -f "$SKILL" ] && grep -qE '^model: sonnet$' "$SKILL" 2>/dev/null; then
    pass "frontmatter model is 'sonnet'"
else
    fail "frontmatter model is not 'sonnet'"
fi
case_end

case_begin "frontmatter-effort-absent" "skills/review-tests/SKILL.md"
# --- Normal case 5: effort is ABSENT (effort: line removed in #2100) ---
# Requires write_code to delete 'effort:' from frontmatter — FAILS until then.
if [ -f "$SKILL" ] && grep -qE '^effort:' "$SKILL" 2>/dev/null; then
    fail "frontmatter 'effort:' must be absent (was not yet removed)"
else
    pass "frontmatter 'effort:' is absent"
fi
case_end

case_begin "procedure-section-present" "skills/review-tests/SKILL.md"
# --- Normal case 6: has ## Procedure section ---
if [ -f "$SKILL" ] && grep -qE '^## Procedure' "$SKILL" 2>/dev/null; then
    pass "has ## Procedure section"
else
    fail "missing ## Procedure section"
fi
case_end

case_begin "rules-section-present" "skills/review-tests/SKILL.md"
# --- Normal case 7: has ## Rules section ---
if [ -f "$SKILL" ] && grep -qE '^## Rules' "$SKILL" 2>/dev/null; then
    pass "has ## Rules section"
else
    fail "missing ## Rules section"
fi
case_end

case_begin "step-labels-present" "skills/review-tests/SKILL.md"
# --- Normal case 8: step labels RT-1 through RT-5 present ---
for label in RT-1 RT-2 RT-3 RT-4 RT-5; do
    if [ -f "$SKILL" ] && grep -qF "$label" "$SKILL" 2>/dev/null; then
        pass "step label '$label' present"
    else
        fail "step label '$label' missing"
    fi
done
case_end

case_begin "run-codex-loop-reference" "skills/review-tests/SKILL.md"
# --- Normal case 9: drives Codex via run-codex-review-loop.sh ---
if [ -f "$SKILL" ] && grep -qF 'run-codex-review-loop.sh' "$SKILL" 2>/dev/null; then
    pass "SKILL.md references run-codex-review-loop.sh"
else
    fail "SKILL.md does not reference run-codex-review-loop.sh"
fi
case_end

case_begin "test-reviewer-launch-model" "skills/review-tests/SKILL.md"
# --- Normal case 9b (#2100 Step 5): the exit 3 test-reviewer launch passes the
# reviewer model resolved by resolve-role-model --role reviewer. FAILS until then.
spawn="$(grep -E '^- exit 3 .*test-reviewer' "$SKILL" 2>/dev/null || true)"
if [ -z "$spawn" ]; then
    fail "9b: no '- exit 3' test-reviewer launch line found"
elif ! printf '%s' "$spawn" | grep -qF 'resolve-role-model'; then
    fail "9b: test-reviewer launch does not resolve its model via resolve-role-model — line: $spawn"
elif ! printf '%s' "$spawn" | grep -qE -- '--role reviewer([^-a-z]|$)'; then
    fail "9b: test-reviewer launch does not use --role reviewer — line: $spawn"
elif ! printf '%s' "$spawn" | grep -qE 'model[=:]'; then
    fail "9b: test-reviewer launch does not pass a model: parameter — line: $spawn"
else
    pass "9b: test-reviewer launch passes model= from resolve-role-model --role reviewer"
fi
case_end

case_begin "references-test-design" "skills/review-tests/SKILL.md"
# --- Normal case 10: references test-design.md ---
if [ -f "$SKILL" ] && grep -qF 'test-design.md' "$SKILL" 2>/dev/null; then
    pass "SKILL.md references test-design.md"
else
    fail "SKILL.md does not reference test-design.md"
fi
case_end

case_begin "review-tests-complete-sentinel" "skills/review-tests/SKILL.md"
# --- Normal case 11: WORKFLOW_REVIEW_TESTS_COMPLETE sentinel present ---
if [ -f "$SKILL" ] && grep -qF 'WORKFLOW_REVIEW_TESTS_COMPLETE' "$SKILL" 2>/dev/null; then
    pass "WORKFLOW_REVIEW_TESTS_COMPLETE sentinel present"
else
    fail "WORKFLOW_REVIEW_TESTS_COMPLETE sentinel missing"
fi
case_end

case_begin "review-tests-warnings-sentinel" "skills/review-tests/SKILL.md"
# --- Normal case 12: WORKFLOW_REVIEW_TESTS_WARNINGS sentinel present ---
if [ -f "$SKILL" ] && grep -qF 'WORKFLOW_REVIEW_TESTS_WARNINGS' "$SKILL" 2>/dev/null; then
    pass "WORKFLOW_REVIEW_TESTS_WARNINGS sentinel present"
else
    fail "WORKFLOW_REVIEW_TESTS_WARNINGS sentinel missing"
fi
case_end

case_begin "no-absolute-paths" "skills/review-tests/SKILL.md"
# --- Edge case 13: no absolute paths (public repo leak check) ---
if [ -f "$SKILL" ] && grep -qiE '(^|[^a-zA-Z])(c:/|/home/|/Users/)' "$SKILL" 2>/dev/null; then
    fail "absolute path found in SKILL.md (public repo leak)"
else
    pass "no absolute paths in SKILL.md"
fi
case_end

case_begin "no-private-repo-references" "skills/review-tests/SKILL.md"
# --- Edge case 14: no references to my-private-repo/ ---
if [ -f "$SKILL" ] && grep -qF 'my-private-repo/' "$SKILL" 2>/dev/null; then
    fail "SKILL.md references my-private-repo/ (private repo leak)"
else
    pass "no references to my-private-repo/ in SKILL.md"
fi
case_end

echo ""
echo "--- P: feature-2327 review-tests SKILL.md checks ---"

# P1: RT-6 has the second-review line (write_code complete: follow next-step, no re-run /write-code)
# Stop the awk block at the next RT-N. or ## header to avoid capturing Rules section.
if [ -f "$SKILL" ]; then
  RT6_BLOCK=$(awk '/^RT-6\./{f=1} f && (/^RT-[0-9]/ || /^## /) && !/^RT-6/{exit} f{print}' "$SKILL")
  if echo "$RT6_BLOCK" | grep -qiE "/write-code|write_code"; then
    pass "P1a RT-6 references write-code in second-review guidance"
  else
    fail "P1a RT-6 does not mention write-code (expected second-review guidance)"
  fi
  if echo "$RT6_BLOCK" | grep -qiE "do not re.run|not re-run|not re.run"; then
    pass "P1b RT-6 says do not re-run /write-code after second review"
  else
    fail "P1b RT-6 missing do-not-re-run /write-code guidance"
  fi
fi

# P2: RT-3 exit 8 line says "review scope unchanged" not "test files unchanged"
if [ -f "$SKILL" ]; then
  EXIT8_LINES=$(grep -i "exit 8" "$SKILL")
  if echo "$EXIT8_LINES" | grep -qi "review scope unchanged"; then
    pass "P2a RT-3 exit 8 uses 'review scope unchanged'"
  else
    fail "P2a RT-3 exit 8 missing 'review scope unchanged'"
  fi
  if echo "$EXIT8_LINES" | grep -qi "test files unchanged"; then
    fail "P2b RT-3 exit 8 still contains 'test files unchanged' (must be updated)"
  else
    pass "P2b RT-3 exit 8 does not say 'test files unchanged'"
  fi
fi

# P3: RT-5a uses bin/compute-review-scope-fingerprint.js and mentions HALT on non-zero
if [ -f "$SKILL" ]; then
  RT5A_BLOCK=$(awk '/^RT-5a\./{f=1} f && /^RT-[0-9]/ && !/^RT-5a/{exit} f{print}' "$SKILL")
  if echo "$RT5A_BLOCK" | grep -qF "compute-review-scope-fingerprint"; then
    pass "P3a RT-5a references compute-review-scope-fingerprint.js"
  else
    fail "P3a RT-5a does not reference compute-review-scope-fingerprint.js"
  fi
  if echo "$RT5A_BLOCK" | grep -qiE "HALT|halt|non.zero"; then
    pass "P3b RT-5a mentions HALT on non-zero"
  else
    fail "P3b RT-5a missing HALT on non-zero"
  fi
fi

# P4: RT-5b/5c payload uses fingerprint= not token=
if [ -f "$SKILL" ]; then
  SENTINEL_LINES=$(grep -E "WORKFLOW_REVIEW_TESTS_(COMPLETE|WARNINGS)" "$SKILL")
  if echo "$SENTINEL_LINES" | grep -qE "fingerprint=\\\$\{FINGERPRINT\}|fingerprint=\${FINGERPRINT}"; then
    pass "P4a RT-5b/5c payload uses fingerprint=\${FINGERPRINT}"
  else
    fail "P4a RT-5b/5c payload does not use fingerprint=\${FINGERPRINT}"
  fi
  if echo "$SENTINEL_LINES" | grep -qF "token="; then
    fail "P4b RT-5b/5c sentinel still uses token= (must use fingerprint=)"
  else
    pass "P4b RT-5b/5c sentinel does not use token="
  fi
fi

# P5: RT-2 references bin/select-review-scope.js
if [ -f "$SKILL" ] && grep -qF "select-review-scope" "$SKILL"; then
  pass "P5 RT-2 references bin/select-review-scope.js"
else
  fail "P5 RT-2 missing reference to bin/select-review-scope.js"
fi

# P6: RT-2 Round-2 LOW items preserved
if [ -f "$SKILL" ]; then
  if grep -qF "EXTENSIONS_USED=0" "$SKILL"; then
    pass "P6a RT-2 has Initialize EXTENSIONS_USED=0"
  else
    fail "P6a RT-2 missing Initialize EXTENSIONS_USED=0"
  fi
  if grep -qF "resolve-plans-dir" "$SKILL"; then
    pass "P6b RT-2 references resolve-plans-dir.md for PLANS_DIR"
  else
    fail "P6b RT-2 missing resolve-plans-dir.md reference"
  fi
  if grep -qiE "Write tool|Write-tool" "$SKILL"; then
    pass "P6c RT-2 mentions Write tool (no Bash assembly)"
  else
    fail "P6c RT-2 missing Write-tool-only instruction"
  fi
fi

# P7: Rules section delegates scope to bin/select-review-scope.js
if [ -f "$SKILL" ]; then
  RULES_BLOCK=$(awk '/^## Rules/{f=1} f && /^## / && !/^## Rules/{exit} f{print}' "$SKILL")
  if echo "$RULES_BLOCK" | grep -qF "select-review-scope"; then
    pass "P7 Rules section delegates scope to bin/select-review-scope.js"
  else
    fail "P7 Rules section does not delegate scope to bin/select-review-scope.js"
  fi
fi

# P8: SKILL.md <=100 lines
if [ -f "$SKILL" ]; then
  LINES_P8=$(wc -l < "$SKILL")
  if [ "$LINES_P8" -le 100 ]; then
    pass "P8 review-tests SKILL.md is $LINES_P8 lines (<=100)"
  else
    fail "P8 review-tests SKILL.md is $LINES_P8 lines, exceeds 100"
  fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
