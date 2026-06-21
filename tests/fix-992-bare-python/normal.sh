# N1: uv run python -c → CLEAN
REPO_N1=$(make_repo)
git -C "$REPO_N1" checkout -q -b featureN1
mkdir -p "$REPO_N1/tests"
cat > "$REPO_N1/tests/n1.sh" <<'EOF'
#!/bin/bash
uv run python -c "import sys; print(sys.version)"
EOF
git -C "$REPO_N1" add "$REPO_N1/tests/n1.sh"
git -C "$REPO_N1" commit -q -m "add .sh using uv run python"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_N1" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "N1: exits 0 for uv run python -c"; else fail "N1: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi

# N2: no python → CLEAN
REPO_N2=$(make_repo)
git -C "$REPO_N2" checkout -q -b featureN2
mkdir -p "$REPO_N2/tests"
cat > "$REPO_N2/tests/n2.sh" <<'EOF'
#!/bin/bash
echo "hello world"
ls -la
EOF
git -C "$REPO_N2" add "$REPO_N2/tests/n2.sh"
git -C "$REPO_N2" commit -q -m "add .sh with no python"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_N2" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "N2: exits 0 for .sh with no python"; else fail "N2: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "No bare python"; then pass "N2: clean-output footer present"; else fail "N2: 'No bare python' footer not found. Output: $OUTPUT"; fi

# N3: --all mode on clean tree → exit 0
REPO_N3=$(make_repo)
git -C "$REPO_N3" checkout -q -b featureN3
mkdir -p "$REPO_N3/tests"
cat > "$REPO_N3/tests/clean.sh" <<'EOF'
#!/bin/bash
echo "clean"
uv run python -c "print('ok')"
EOF
git -C "$REPO_N3" add "$REPO_N3/tests/clean.sh"
git -C "$REPO_N3" commit -q -m "add clean .sh"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_N3" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "N3: exits 0 in --all mode on clean tree"; else fail "N3: expected exit 0 in --all, got $EXIT_CODE. Output: $OUTPUT"; fi

# N3b: --all heading text = "## Bare Python Review: PERFORMED (all-scan mode)"
EXIT_CODE=0
OUTPUT=$(cd "$REPO_N3" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT_CODE=$?
if echo "$OUTPUT" | grep -q "## Bare Python Review: PERFORMED (all-scan mode)"; then pass "N3b: output contains PERFORMED (all-scan mode) heading"; else fail "N3b: PERFORMED (all-scan mode) heading not found. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "No bare python"; then pass "N3b: --all clean-output body present"; else fail "N3b: 'No bare python' body line not found. Output: $OUTPUT"; fi

# N4: python3 myscript.py (no -c) → exit 0, no HARD
REPO_N4=$(make_repo)
git -C "$REPO_N4" checkout -q -b featureN4
mkdir -p "$REPO_N4/tests"
cat > "$REPO_N4/tests/n4.sh" <<'EOF'
#!/bin/bash
python3 myscript.py
python myscript.py
EOF
git -C "$REPO_N4" add "$REPO_N4/tests/n4.sh"
git -C "$REPO_N4" commit -q -m "add .sh with python3 without -c"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_N4" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "N4: exits 0 for python3 without -c"; else fail "N4: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -qE "^HARD:"; then fail "N4: HARD finding found unexpectedly. Output: $OUTPUT"; else pass "N4: no HARD finding in output for python3 without -c"; fi

# N5: uv run python3 -c (python3 suffix) → CLEAN
REPO_N5=$(make_repo)
git -C "$REPO_N5" checkout -q -b featureN5
mkdir -p "$REPO_N5/tests"
printf '#!/bin/bash\nuv run python3 -c "import sys; print(sys.version)"\n' > "$REPO_N5/tests/n5.sh"
git -C "$REPO_N5" add "$REPO_N5/tests/n5.sh"
git -C "$REPO_N5" commit -q -m "uv run python3"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_N5" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "N5: exits 0 for uv run python3 -c"; else fail "N5: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi

# Case N6: no-args default invocation → BASE_REF defaults to origin/main → SKIPPED (no remote), exit 0
REPO_N6=$(make_repo)
EXIT_CODE=0
OUTPUT=$(cd "$REPO_N6" && run_with_timeout bash "$SCRIPT" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "N6: no-args exits 0 (origin/main not found → SKIPPED)"; else fail "N6: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "## Bare Python Review: SKIPPED"; then pass "N6: no-args emits SKIPPED heading"; else fail "N6: SKIPPED heading not found. Output: $OUTPUT"; fi

# Case N7: $(uv run python -c "...") in command substitution → CLEAN
REPO_N7=$(make_repo)
git -C "$REPO_N7" checkout -q -b featureN7
mkdir -p "$REPO_N7/tests"
cat > "$REPO_N7/tests/n7.sh" <<'EOF'
#!/bin/bash
VERSION=$(uv run python -c "import sys; print(sys.version)")
echo "$VERSION"
EOF
git -C "$REPO_N7" add "$REPO_N7/tests/n7.sh"
git -C "$REPO_N7" commit -q -m "command substitution uv run python"
EXIT_CODE=0
OUTPUT=$(cd "$REPO_N7" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "N7: \$(uv run python -c) exits 0 (SANCTION_RE handles subshell)"; else fail "N7: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi
