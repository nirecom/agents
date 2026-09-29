#!/usr/bin/env bash
# Tests: skills/review-tests/SKILL.md
# Tags: frontmatter, tests, review, scope:common
# Structural tests for skills/review-tests/SKILL.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENTS_DIR="$ROOT"
PASS=0
FAIL=0
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
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
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
