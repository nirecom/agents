# Tests: bin/review-plan-codex, bin/run-codex-review-loop, skills/_shared/codex-review-loop.md, skills/make-detail-plan/SKILL.md, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, detail, codex, review, scope:common
# ===========================================================================
# Format-specific verdicts: detail-plan and outline-plan APPROVED/NEEDS_REVISION/MISSING_ALTERNATIVE
# ===========================================================================

# ---------------------------------------------------------------------------
# 15. PERFORMED with --format detail-plan, mock returns APPROVED
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "APPROVED"
echo "plan is good"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

EXIT_CODE=0
OUTPUT=$(run_script "$MOCK_BIN:$PATH" --format detail-plan --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "detail-plan APPROVED: expected exit 0, got $EXIT_CODE"
else
    pass "detail-plan APPROVED: exits 0"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review: PERFORMED"; then
    pass "detail-plan APPROVED: PERFORMED label present"
else
    fail "detail-plan APPROVED: PERFORMED label missing. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "APPROVED"; then
    pass "detail-plan APPROVED: APPROVED verdict in output"
else
    fail "detail-plan APPROVED: APPROVED not in output. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 16. PERFORMED with --format detail-plan, mock returns NEEDS_REVISION
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "NEEDS_REVISION"
echo "1. Missing test step for edge cases"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

EXIT_CODE=0
OUTPUT=$(run_script "$MOCK_BIN:$PATH" --format detail-plan --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "detail-plan NEEDS_REVISION: expected exit 0, got $EXIT_CODE"
else
    pass "detail-plan NEEDS_REVISION: exits 0"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review: PERFORMED"; then
    pass "detail-plan NEEDS_REVISION: PERFORMED label present"
else
    fail "detail-plan NEEDS_REVISION: PERFORMED label missing. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "NEEDS_REVISION"; then
    pass "detail-plan NEEDS_REVISION: verdict in output"
else
    fail "detail-plan NEEDS_REVISION: verdict not in output. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 17. PERFORMED with --format outline-plan, mock returns APPROVED
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "APPROVED directionally sound"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

EXIT_CODE=0
OUTPUT=$(run_script "$MOCK_BIN:$PATH" --format outline-plan --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "outline-plan APPROVED: expected exit 0, got $EXIT_CODE"
else
    pass "outline-plan APPROVED: exits 0"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review: PERFORMED"; then
    pass "outline-plan APPROVED: PERFORMED label present"
else
    fail "outline-plan APPROVED: PERFORMED label missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 18. PERFORMED with --format outline-plan, mock returns MISSING_ALTERNATIVE
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "MISSING_ALTERNATIVE: consider event-driven design"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

EXIT_CODE=0
OUTPUT=$(run_script "$MOCK_BIN:$PATH" --format outline-plan --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "outline-plan MISSING_ALTERNATIVE: expected exit 0, got $EXIT_CODE"
else
    pass "outline-plan MISSING_ALTERNATIVE: exits 0"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review: PERFORMED"; then
    pass "outline-plan MISSING_ALTERNATIVE: PERFORMED label present"
else
    fail "outline-plan MISSING_ALTERNATIVE: PERFORMED label missing. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "MISSING_ALTERNATIVE"; then
    pass "outline-plan MISSING_ALTERNATIVE: verdict in output"
else
    fail "outline-plan MISSING_ALTERNATIVE: verdict not in output. Output: $OUTPUT"
fi

