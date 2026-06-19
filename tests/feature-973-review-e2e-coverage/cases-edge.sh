# Cases 6–8: edge cases (no-hook diff, mixed coverage, self-contamination).

# Case 6: Diff has no hooks/*.js changes → SKIPPED, exit 0.
REPO6=$(make_repo)
git -C "$REPO6" checkout -q -b feature6
echo "unrelated" > "$REPO6/other.txt"
git -C "$REPO6" add other.txt
git -C "$REPO6" commit -q -m "non-hook change"

EXIT_CODE=0
OUTPUT=$(run_script "$REPO6" --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 6: exits 0 when no hook changes"
else
    fail "Case 6: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -qE "## E2E-Coverage Review:.*SKIPPED"; then
    pass "Case 6: SKIPPED status emitted when no hook changes"
else
    fail "Case 6: expected SKIPPED status. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "WARN"; then
    fail "Case 6: no WARN should appear when no hooks changed. Output: $OUTPUT"
else
    pass "Case 6: no WARN emitted"
fi

# Case 7: Multiple hooks in diff — mix of covered and uncovered.
REPO7=$(make_repo)
git -C "$REPO7" checkout -q -b feature7
write_hook_stub "$REPO7" "session-start.js"
write_e2e_test_for_hook "$REPO7/tests/feature-772-session-start-e2e.sh" "session-start"
write_hook_stub "$REPO7" "stop-confirm-plan-guard.js"
write_hook_stub "$REPO7" "post-compact.js"
git -C "$REPO7" add hooks/ tests/
git -C "$REPO7" commit -q -m "mixed coverage"

EXIT_CODE=0
OUTPUT=$(run_script "$REPO7" --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 7: exits 0 with mixed coverage"
else
    fail "Case 7: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi

WARN_COUNT=$(echo "$OUTPUT" | grep -c "^WARN:" || true)
if [[ "$WARN_COUNT" -eq 2 ]]; then
    pass "Case 7: exactly 2 WARN lines (uncovered hooks only)"
else
    fail "Case 7: expected 2 WARN lines, got $WARN_COUNT. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "WARN.*session-start"; then
    fail "Case 7: covered session-start must not WARN. Output: $OUTPUT"
else
    pass "Case 7: covered session-start not WARNed"
fi
if echo "$OUTPUT" | grep -q "WARN.*stop-confirm-plan-guard" && \
   echo "$OUTPUT" | grep -q "WARN.*post-compact"; then
    pass "Case 7: both uncovered hooks WARNed"
else
    fail "Case 7: uncovered hooks not all WARNed. Output: $OUTPUT"
fi

# Case 8: SELF_TEST_PATH exclusion — review-e2e-coverage's own test file must
# not count as coverage for any hooks it mentions as fixtures.
REPO8=$(make_repo)
git -C "$REPO8" checkout -q -b feature8
write_hook_stub "$REPO8" "stop-confirm-plan-guard.js"
mkdir -p "$REPO8/tests"
cat > "$REPO8/tests/feature-973-review-e2e-coverage.sh" <<'EOF'
#!/bin/bash
# Tests: bin/review-e2e-coverage
# Tags: scope:issue-specific, lint
echo "claude -p RUN_E2E hooks/stop-confirm-plan-guard.js"
EOF
git -C "$REPO8" add hooks/ tests/
git -C "$REPO8" commit -q -m "hook change + self-test file present"

EXIT_CODE=0
OUTPUT=$(run_script "$REPO8" --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 8: exits 0 with self-test present"
else
    fail "Case 8: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "WARN.*stop-confirm-plan-guard"; then
    pass "Case 8: WARN still emitted — self-test correctly excluded"
else
    fail "Case 8: self-test must not silence WARN (self-contamination guard). Output: $OUTPUT"
fi
