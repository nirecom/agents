#!/usr/bin/env bash
# Static validation tests for copilot/prompts/*.prompt.md
# All tests are skipped when the prompts directory does not yet exist.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROMPTS_DIR="$REPO_ROOT/copilot/prompts"

ERRORS=0
SKIPPED=0

pass()  { echo "PASS: $1"; }
fail()  { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
skip()  { echo "SKIP: $1"; SKIPPED=$((SKIPPED + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

EXPECTED_FILES=(
    "commit-push.prompt.md"
    "update-docs.prompt.md"
    "review-code-security.prompt.md"
    "review-plan-security.prompt.md"
    "survey-code.prompt.md"
    "write-tests.prompt.md"
    "make-plan.prompt.md"
    "deep-research.prompt.md"
)

echo "=== copilot/prompts static validation ==="
echo ""

# Guard: skip everything if prompts directory is absent
if [ ! -d "$PROMPTS_DIR" ]; then
    skip "Normal 9:  all 8 prompt files exist (prompts dir absent)"
    skip "Normal 10: frontmatter has name and description (prompts dir absent)"
    skip "Security 11: no Claude-only tool references in prompt bodies (prompts dir absent)"
    echo ""
    echo "=== Results ==="
    echo "All tests skipped (copilot/prompts not yet created)."
    exit 0
fi

# --- Normal 9: all 8 files present ---
echo "=== Normal 9: all 8 expected prompt files exist ==="
ALL_PRESENT=1
for fname in "${EXPECTED_FILES[@]}"; do
    fpath="$PROMPTS_DIR/$fname"
    if [ ! -f "$fpath" ]; then
        fail "Normal 9: missing file '$fname'"
        ALL_PRESENT=0
    fi
done
[ "$ALL_PRESENT" -eq 1 ] && pass "Normal 9: all 8 prompt files present"

# --- Normal 10: frontmatter has name and description ---
echo ""
echo "=== Normal 10: each file has frontmatter with name and description ==="
FM_ERRORS=0
for fname in "${EXPECTED_FILES[@]}"; do
    fpath="$PROMPTS_DIR/$fname"
    [ ! -f "$fpath" ] && continue

    # Extract content between first pair of --- delimiters
    FRONTMATTER=$(awk '/^---/{found++; if(found==2) exit; next} found==1{print}' "$fpath")

    if ! echo "$FRONTMATTER" | grep -q "^name:"; then
        fail "Normal 10: '$fname' frontmatter missing 'name:'"
        FM_ERRORS=$((FM_ERRORS + 1))
    fi
    if ! echo "$FRONTMATTER" | grep -q "^description:"; then
        fail "Normal 10: '$fname' frontmatter missing 'description:'"
        FM_ERRORS=$((FM_ERRORS + 1))
    fi
done
[ "$FM_ERRORS" -eq 0 ] && pass "Normal 10: all files have name and description in frontmatter"

# --- Security 11: no Claude-only tool references ---
echo ""
echo "=== Security 11: no Claude-only tool references (Agent, TodoWrite, AskUserQuestion, ExitPlanMode) ==="
BANNED_PATTERN='\b(Agent|TodoWrite|AskUserQuestion|ExitPlanMode)\b'
SEC_ERRORS=0
for fname in "${EXPECTED_FILES[@]}"; do
    fpath="$PROMPTS_DIR/$fname"
    [ ! -f "$fpath" ] && continue

    MATCHES=$(grep -En "$BANNED_PATTERN" "$fpath" 2>/dev/null || true)
    if [ -n "$MATCHES" ]; then
        fail "Security 11: '$fname' contains banned Claude tool reference:"
        echo "$MATCHES" | while IFS= read -r line; do echo "    $line"; done
        SEC_ERRORS=$((SEC_ERRORS + 1))
    fi
done
[ "$SEC_ERRORS" -eq 0 ] && pass "Security 11: no banned tool references found"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ] && [ "$SKIPPED" -eq 0 ]; then
    echo "All tests passed."
    exit 0
elif [ "$ERRORS" -eq 0 ]; then
    echo "$SKIPPED test(s) skipped."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
