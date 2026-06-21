# S1: --base without argument → SKIPPED, exit 0
EXIT_CODE=0
OUTPUT=$(run_with_timeout bash "$SCRIPT" --base 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "S1: exits 0 for --base without argument"; else fail "S1: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "## Bare Python Review: SKIPPED — --base requires an argument"; then pass "S1: output contains correct SKIPPED message"; else fail "S1: expected SKIPPED message for missing arg. Output: $OUTPUT"; fi

# S2: --base + --all → SKIPPED (mutually exclusive), exit 0
REPO_S2=$(make_repo)
EXIT_CODE=0
OUTPUT=$(cd "$REPO_S2" && run_with_timeout bash "$SCRIPT" --base main --all 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "S2: exits 0 for --base + --all"; else fail "S2: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "## Bare Python Review: SKIPPED — --base and --all are mutually exclusive"; then pass "S2: output contains mutually exclusive SKIPPED message"; else fail "S2: expected mutually exclusive SKIPPED message. Output: $OUTPUT"; fi

# Case ARG1: unknown argument → script continues (ignores unknown flag)
REPO_ARG1=$(make_repo)
EXIT_CODE=0
OUTPUT=$(cd "$REPO_ARG1" && run_with_timeout bash "$SCRIPT" --unknown-flag 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "ARG1: unknown flag exits 0 (script continues)"; else fail "ARG1: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi

# S3: unresolvable base ref → SKIPPED, exit 0
REPO_S3=$(make_repo)
git -C "$REPO_S3" checkout -q -b featureS3
echo "something" > "$REPO_S3/file.sh"
git -C "$REPO_S3" add "$REPO_S3/file.sh"
git -C "$REPO_S3" commit -q -m "add file"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_S3" && run_with_timeout bash "$SCRIPT" --base nonexistent-branch-xyz 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "S3: exits 0 for unresolvable base ref"; else fail "S3: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "## Bare Python Review: SKIPPED"; then pass "S3: output contains SKIPPED for unresolvable ref"; else fail "S3: expected SKIPPED message for unresolvable ref. Output: $OUTPUT"; fi
