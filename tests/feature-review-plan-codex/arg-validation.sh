# Tests: bin/review-plan-codex, bin/run-codex-review-loop, skills/_shared/codex-review-loop.md, skills/make-detail-plan/SKILL.md, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, detail, codex, review, scope:common
# ===========================================================================
# Argument validation: missing/garbage --format, missing/nonexistent/empty --input
# ===========================================================================

# ---------------------------------------------------------------------------
# 10. Error — --input not provided
# ---------------------------------------------------------------------------
EXIT_CODE=0
OUTPUT=$(PATH="$MINIMAL_PATH" HOME="$TMPDIR_BASE" bash "$SCRIPT" --format detail-plan --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "--input missing: expected exit 0, got $EXIT_CODE"
else
    pass "--input missing: exits 0"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review: FAILED"; then
    pass "--input missing: FAILED status label present"
else
    fail "--input missing: status label missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 11. Error — --format not provided
# ---------------------------------------------------------------------------
EXIT_CODE=0
OUTPUT=$(PATH="$MINIMAL_PATH" HOME="$TMPDIR_BASE" bash "$SCRIPT" --input "$PLAN_FILE" --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "--format missing: expected exit 0, got $EXIT_CODE"
else
    pass "--format missing: exits 0"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review: FAILED"; then
    pass "--format missing: FAILED status label present"
else
    fail "--format missing: status label missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 12. Error — --format garbage value
# ---------------------------------------------------------------------------
EXIT_CODE=0
OUTPUT=$(PATH="$MINIMAL_PATH" HOME="$TMPDIR_BASE" bash "$SCRIPT" --input "$PLAN_FILE" --format garbage --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "--format garbage: expected exit 0, got $EXIT_CODE"
else
    pass "--format garbage: exits 0"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review: FAILED"; then
    pass "--format garbage: FAILED status label present"
else
    fail "--format garbage: status label missing. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "invalid --format"; then
    pass "--format garbage: error message mentions invalid --format"
else
    fail "--format garbage: error message missing 'invalid --format'. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 13. Error — --input nonexistent file
# ---------------------------------------------------------------------------
EXIT_CODE=0
OUTPUT=$(PATH="$MINIMAL_PATH" HOME="$TMPDIR_BASE" bash "$SCRIPT" --input "$TMPDIR_BASE/nonexistent.md" --format detail-plan --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "--input nonexistent: expected exit 0, got $EXIT_CODE"
else
    pass "--input nonexistent: exits 0"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review: FAILED"; then
    pass "--input nonexistent: FAILED status label present"
else
    fail "--input nonexistent: status label missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 14. Error — --input empty file
# ---------------------------------------------------------------------------
EMPTY_FILE="$TMPDIR_BASE/empty.md"
touch "$EMPTY_FILE"

EXIT_CODE=0
OUTPUT=$(PATH="$MINIMAL_PATH" HOME="$TMPDIR_BASE" bash "$SCRIPT" --input "$EMPTY_FILE" --format detail-plan --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "--input empty file: expected exit 0, got $EXIT_CODE"
else
    pass "--input empty file: exits 0"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review: FAILED"; then
    pass "--input empty file: FAILED status label present"
else
    fail "--input empty file: status label missing. Output: $OUTPUT"
fi

