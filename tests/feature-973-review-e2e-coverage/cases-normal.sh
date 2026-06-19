# Cases 1–5: normal-path priority handling.

# Case 1: P1 hook in diff, NO E2E test → WARN, exit 0.
REPO1=$(make_repo)
git -C "$REPO1" checkout -q -b feature1
write_hook_stub "$REPO1" "stop-confirm-plan-guard.js"
git -C "$REPO1" add hooks/stop-confirm-plan-guard.js
git -C "$REPO1" commit -q -m "add stop-confirm-plan-guard hook (no E2E)"

EXIT_CODE=0
OUTPUT=$(run_script "$REPO1" --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 1: exits 0 even with WARN (soft-warn invariant)"
else
    fail "Case 1: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "WARN.*stop-confirm-plan-guard"; then
    pass "Case 1: WARN emitted for P1 hook without E2E"
else
    fail "Case 1: missing WARN for P1 hook without E2E. Output: $OUTPUT"
fi

# Case 2: P2 hook in diff WITH matching E2E test → no WARN, exit 0.
REPO2=$(make_repo)
git -C "$REPO2" checkout -q -b feature2
write_hook_stub "$REPO2" "stop-final-report-guard.js"
write_e2e_test_for_hook "$REPO2/tests/feature-534-stop-final-report-guard-e2e.sh" "stop-final-report-guard"
git -C "$REPO2" add hooks/stop-final-report-guard.js tests/feature-534-stop-final-report-guard-e2e.sh
git -C "$REPO2" commit -q -m "add stop-final-report-guard hook with E2E coverage"

EXIT_CODE=0
OUTPUT=$(run_script "$REPO2" --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 2: exits 0 when P2 hook has matching E2E"
else
    fail "Case 2: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "WARN.*stop-final-report-guard"; then
    fail "Case 2: unexpected WARN for covered hook. Output: $OUTPUT"
else
    pass "Case 2: no WARN for P2 hook with E2E coverage"
fi

# Case 3: P3 hook in diff, NO E2E test → WARN, exit 0.
REPO3=$(make_repo)
git -C "$REPO3" checkout -q -b feature3
write_hook_stub "$REPO3" "subagent-start.js"
git -C "$REPO3" add hooks/subagent-start.js
git -C "$REPO3" commit -q -m "add subagent-start hook (no E2E)"

EXIT_CODE=0
OUTPUT=$(run_script "$REPO3" --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 3: exits 0 with WARN for P3 hook"
else
    fail "Case 3: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "WARN.*subagent-start"; then
    pass "Case 3: WARN emitted for P3 hook without E2E"
else
    fail "Case 3: missing WARN for P3 hook without E2E. Output: $OUTPUT"
fi

# Case 4: OUT-defer hook in diff, NO E2E → INFO (not WARN), exit 0.
REPO4=$(make_repo)
git -C "$REPO4" checkout -q -b feature4
write_hook_stub "$REPO4" "supervisor-guard.js"
git -C "$REPO4" add hooks/supervisor-guard.js
git -C "$REPO4" commit -q -m "modify supervisor-guard hook (OUT-defer)"

EXIT_CODE=0
OUTPUT=$(run_script "$REPO4" --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 4: exits 0 for OUT-defer hook"
else
    fail "Case 4: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "WARN.*supervisor-guard"; then
    fail "Case 4: WARN must NOT be emitted for OUT-defer hook. Output: $OUTPUT"
else
    pass "Case 4: no WARN for OUT-defer hook"
fi
if echo "$OUTPUT" | grep -q "INFO.*supervisor-guard"; then
    pass "Case 4: INFO emitted for OUT-defer hook"
else
    fail "Case 4: expected INFO for OUT-defer hook. Output: $OUTPUT"
fi

# Case 5: Hook in diff NOT listed in Hook Audit → silent pass, no WARN.
REPO5=$(make_repo)
git -C "$REPO5" checkout -q -b feature5
write_hook_stub "$REPO5" "block-credentials.js"
git -C "$REPO5" add hooks/block-credentials.js
git -C "$REPO5" commit -q -m "add unlisted hook"

EXIT_CODE=0
OUTPUT=$(run_script "$REPO5" --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 5: exits 0 for unlisted hook"
else
    fail "Case 5: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "WARN.*block-credentials"; then
    fail "Case 5: must NOT WARN for unlisted hook (avoid false positive). Output: $OUTPUT"
else
    pass "Case 5: no WARN for hook absent from Hook Audit table"
fi
