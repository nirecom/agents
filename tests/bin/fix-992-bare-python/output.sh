# O1: violation → "## Bare Python Review: PERFORMED" heading
REPO_O1=$(make_repo)
git -C "$REPO_O1" checkout -q -b featureO1
mkdir -p "$REPO_O1/tests"
cat > "$REPO_O1/tests/o1.sh" <<'EOF'
#!/bin/bash
python3 -c "print('violation')"
EOF
git -C "$REPO_O1" add "$REPO_O1/tests/o1.sh"
git -C "$REPO_O1" commit -q -m "add violation .sh"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_O1" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if echo "$OUTPUT" | grep -q "## Bare Python Review: PERFORMED"; then pass "O1: output contains PERFORMED heading when violations exist"; else fail "O1: PERFORMED heading not found. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -qE "^Changed .sh files scanned: [0-9]+"; then pass "O1: output contains scanned-count line"; else fail "O1: scanned-count line not found. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "HARD findings block the workflow"; then pass "O1: output contains HARD-findings footer"; else fail "O1: HARD-findings footer not found. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "Checked: bare"; then pass "O1: output contains Checked footer"; else fail "O1: Checked footer not found. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -qE "^HARD: [^:]+:[0-9]+: "; then pass "O1/O3: HARD line format is 'HARD: path:LINE: content'"; else fail "O1/O3: HARD line format mismatch. Output: $OUTPUT"; fi

# O2: empty diff → "## Bare Python Review: SKIPPED" heading
REPO_O2=$(make_repo)
EXIT_CODE=0
OUTPUT=$(cd "$REPO_O2" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if echo "$OUTPUT" | grep -q "## Bare Python Review: SKIPPED"; then pass "O2: output contains SKIPPED heading on empty diff"; else fail "O2: SKIPPED heading not found. Output: $OUTPUT"; fi
