# Cases 15–17: --all scan mode.

# Case 15: --all with hooks present → PERFORMED (all-scan mode), exit 0.
# Hooks in table: some have E2E (INFO), some don't (WARN in diff mode;
# in --all mode, unlisted hooks get INFO too).
REPO15=$(make_repo)
# No feature branch needed for --all (scans hooks/ directly, not diff).
write_hook_stub "$REPO15" "stop-confirm-plan-guard.js"   # P1, no E2E
write_hook_stub "$REPO15" "supervisor-guard.js"           # OUT-defer

EXIT_CODE=0
OUTPUT=$(run_script "$REPO15" --all) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 15: --all exits 0"
else
    fail "Case 15: --all expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -qE "## E2E-Coverage Review: PERFORMED \(all-scan mode\)"; then
    pass "Case 15: --all emits PERFORMED (all-scan mode) header"
else
    fail "Case 15: missing PERFORMED (all-scan mode) header. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "WARN.*stop-confirm-plan-guard"; then
    pass "Case 15: --all WARN for uncovered P1 hook"
else
    fail "Case 15: expected WARN for stop-confirm-plan-guard in --all. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "OUT-defer.*supervisor-guard\|supervisor-guard.*OUT-defer"; then
    pass "Case 15: --all INFO for OUT-defer hook"
else
    fail "Case 15: expected INFO/OUT-defer for supervisor-guard in --all. Output: $OUTPUT"
fi

# Case 16: --all with no hooks/*.js files → "No hooks" message, exit 0.
REPO16=$(make_repo)
# hooks/ dir exists but empty (make_repo creates it).

EXIT_CODE=0
OUTPUT=$(run_script "$REPO16" --all) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 16: --all exits 0 when hooks/ is empty"
else
    fail "Case 16: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -qiE "No hooks.*found|No hooks"; then
    pass "Case 16: --all reports no hooks when dir is empty"
else
    fail "Case 16: expected 'No hooks' message. Output: $OUTPUT"
fi

# Case 17: --all and --base together → SKIPPED "mutually exclusive", exit 0.
REPO17=$(make_repo)

EXIT_CODE=0
OUTPUT=$(run_script "$REPO17" --all --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 17: --all --base exits 0"
else
    fail "Case 17: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -qE "SKIPPED.*(mutually exclusive|exclusive)"; then
    pass "Case 17: SKIPPED with 'mutually exclusive' for --all --base"
else
    fail "Case 17: expected SKIPPED mutually-exclusive message. Output: $OUTPUT"
fi
