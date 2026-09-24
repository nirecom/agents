# H1: bare python3 -c "..." → exit 1, HARD
REPO_H1=$(make_repo)
git -C "$REPO_H1" checkout -q -b featureH1
mkdir -p "$REPO_H1/tests"
cat > "$REPO_H1/tests/h1.sh" <<'EOF'
#!/bin/bash
python3 -c "import sys; print(sys.version)"
EOF
git -C "$REPO_H1" add "$REPO_H1/tests/h1.sh"
git -C "$REPO_H1" commit -q -m "add .sh with bare python3 -c"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_H1" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]]; then pass "H1: exits 1 for bare python3 -c"; else fail "H1: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "HARD"; then pass "H1: output contains HARD"; else fail "H1: HARD not found. Output: $OUTPUT"; fi

# H2: bare python -c "..." → exit 1, HARD
REPO_H2=$(make_repo)
git -C "$REPO_H2" checkout -q -b featureH2
mkdir -p "$REPO_H2/tests"
cat > "$REPO_H2/tests/h2.sh" <<'EOF'
#!/bin/bash
python -c "print('hi')"
EOF
git -C "$REPO_H2" add "$REPO_H2/tests/h2.sh"
git -C "$REPO_H2" commit -q -m "add .sh with bare python -c"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_H2" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]]; then pass "H2: exits 1 for bare python -c"; else fail "H2: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "HARD"; then pass "H2: output contains HARD"; else fail "H2: HARD not found. Output: $OUTPUT"; fi

# H3: --base mode, staged bare python → exit 1
REPO_H3=$(make_repo)
git -C "$REPO_H3" checkout -q -b featureH3
mkdir -p "$REPO_H3/tests"
cat > "$REPO_H3/tests/h3.sh" <<'EOF'
#!/bin/bash
python3 -c "import os; print(os.getcwd())"
EOF
git -C "$REPO_H3" add "$REPO_H3/tests/h3.sh"
git -C "$REPO_H3" commit -q -m "add staged bare python3 to feature branch"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_H3" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]]; then pass "H3: exits 1 with --base for staged bare python"; else fail "H3: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"; fi

# Case H5: single-quote body — python3 -c '...' → exit 1, HARD
REPO_H5=$(make_repo)
git -C "$REPO_H5" checkout -q -b featureH5
mkdir -p "$REPO_H5/tests"
printf "#!/bin/bash\npython3 -c 'import sys; print(sys.version)'\n" > "$REPO_H5/tests/h5.sh"
git -C "$REPO_H5" add "$REPO_H5/tests/h5.sh"
git -C "$REPO_H5" commit -q -m "add bare python3 single-quote"
EXIT_CODE=0
OUTPUT=$(cd "$REPO_H5" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]]; then pass "H5: exits 1 for python3 -c with single quotes"; else fail "H5: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "HARD"; then pass "H5: output contains HARD (single quote)"; else fail "H5: HARD not found. Output: $OUTPUT"; fi

# Case H6: unstaged tracked file with bare python3 -c → exit 1, HARD
REPO_H6=$(make_repo)
git -C "$REPO_H6" checkout -q -b featureH6
mkdir -p "$REPO_H6/tests"
# Create the file but DON'T commit or stage it (untracked new .sh)
printf '#!/bin/bash\npython3 -c "import os; print(os.getcwd())"\n' > "$REPO_H6/tests/h6.sh"
EXIT_CODE=0
OUTPUT=$(cd "$REPO_H6" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]]; then pass "H6: exits 1 for untracked .sh with bare python3"; else fail "H6: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "HARD"; then pass "H6: HARD found for untracked file"; else fail "H6: HARD not found. Output: $OUTPUT"; fi

# Case H7: multiple violations in one file → exit 1, two HARD lines
REPO_H7=$(make_repo)
git -C "$REPO_H7" checkout -q -b featureH7
mkdir -p "$REPO_H7/tests"
cat > "$REPO_H7/tests/h7.sh" <<'EOF'
#!/bin/bash
python3 -c "import sys; print(sys.version)"
python3 -c "import os; print(os.getcwd())"
EOF
git -C "$REPO_H7" add "$REPO_H7/tests/h7.sh"
git -C "$REPO_H7" commit -q -m "two violations"
EXIT_CODE=0
OUTPUT=$(cd "$REPO_H7" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]]; then pass "H7: exits 1 for multiple violations"; else fail "H7: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"; fi
HARD_COUNT=$(echo "$OUTPUT" | grep -cE "^HARD:" || true)
if [[ "$HARD_COUNT" -eq 2 ]]; then pass "H7: exactly 2 HARD lines emitted"; else fail "H7: expected 2 HARD lines, got $HARD_COUNT. Output: $OUTPUT"; fi

# H4: --all mode with violations → exit 0 (--all always exits 0), HARD in output
# Reuses REPO_H1 from above
EXIT_CODE=0
OUTPUT=$(cd "$REPO_H1" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "H4: --all exits 0 with violations"; else fail "H4: expected exit 0 in --all, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "HARD"; then pass "H4: --all shows HARD in output"; else fail "H4: HARD not found in --all output. Output: $OUTPUT"; fi
