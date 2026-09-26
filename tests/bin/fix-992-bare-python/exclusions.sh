# E1: fix-277 probe (excluded file) → exit 0
REPO_E1=$(make_repo)
git -C "$REPO_E1" checkout -q -b featureE1
mkdir -p "$REPO_E1/tests"
cat > "$REPO_E1/tests/fix-277-doc-append-merge-union.sh" <<'EOF'
#!/bin/bash
# Intentional Store-stub probe — must use bare python3 to detect real Python.
python3 -c "import sys; sys.exit(0)"
EOF
git -C "$REPO_E1" add "$REPO_E1/tests/fix-277-doc-append-merge-union.sh"
git -C "$REPO_E1" commit -q -m "add fix-277 probe (excluded fixture)"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_E1" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "E1: exits 0 — fix-277 probe excluded"; else fail "E1: expected exit 0 (fix-277 excluded), got $EXIT_CODE. Output: $OUTPUT"; fi

# E2: fixture-string file (excluded) → exit 0
REPO_E2=$(make_repo)
git -C "$REPO_E2" checkout -q -b featureE2
mkdir -p "$REPO_E2/tests"
cat > "$REPO_E2/tests/enforce-worktree-bash-c-cd-scope.sh" <<'EOF'
#!/bin/bash
# Fixture: command strings used as test input — not actually executed as python.
FIXTURE='python3 -c "print(1)"'
echo "$FIXTURE"
EOF
git -C "$REPO_E2" add "$REPO_E2/tests/enforce-worktree-bash-c-cd-scope.sh"
git -C "$REPO_E2" commit -q -m "add fixture-string test (excluded)"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_E2" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "E2: exits 0 — fixture-string file excluded"; else fail "E2: expected exit 0 (fixture excluded), got $EXIT_CODE. Output: $OUTPUT"; fi

# EG1: no diff → SKIPPED, exit 0
REPO_EG1=$(make_repo)
EXIT_CODE=0
OUTPUT=$(cd "$REPO_EG1" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "EG1: exits 0 when no diff"; else fail "EG1: expected exit 0 for empty diff, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "## Bare Python Review: SKIPPED"; then pass "EG1: output contains SKIPPED heading for empty diff"; else fail "EG1: SKIPPED heading not found. Output: $OUTPUT"; fi

# EG2: extensionless bin/ file → exit 0 (not in scope)
REPO_EG2=$(make_repo)
git -C "$REPO_EG2" checkout -q -b featureEG2
mkdir -p "$REPO_EG2/bin"
cat > "$REPO_EG2/bin/some-tool" <<'EOF'
#!/bin/bash
python3 -c "import json; print('{}')"
EOF
chmod +x "$REPO_EG2/bin/some-tool"
git -C "$REPO_EG2" add "$REPO_EG2/bin/some-tool"
git -C "$REPO_EG2" commit -q -m "add extensionless bin/ tool with bare python"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_EG2" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "EG2: exits 0 — extensionless bin/ file out of scope"; else fail "EG2: expected exit 0 (.sh-only scope), got $EXIT_CODE. Output: $OUTPUT"; fi

# EG3: bin/helper.sh (with .sh) containing bare python3 -c → exit 1, HARD
REPO_EG3=$(make_repo)
git -C "$REPO_EG3" checkout -q -b featureEG3
mkdir -p "$REPO_EG3/bin"
cat > "$REPO_EG3/bin/helper.sh" <<'EOF'
#!/bin/bash
python3 -c "import sys; print(sys.version)"
EOF
git -C "$REPO_EG3" add "$REPO_EG3/bin/helper.sh"
git -C "$REPO_EG3" commit -q -m "add bin/helper.sh with bare python3 -c"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_EG3" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]]; then pass "EG3: exits 1 for bin/helper.sh with bare python3 -c"; else fail "EG3: expected exit 1 for .sh in bin/, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "HARD"; then pass "EG3: output contains HARD for bin/helper.sh"; else fail "EG3: HARD not found for bin/helper.sh. Output: $OUTPUT"; fi

# EG4: --all on repo with no .sh files → "No .sh files tracked.", exit 0
REPO_EG4=$(make_repo)
EXIT_CODE=0
OUTPUT=$(cd "$REPO_EG4" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "EG4: exits 0 (no .sh files)"; else fail "EG4: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "No .sh files tracked"; then pass "EG4: 'No .sh files tracked'"; else fail "EG4: message absent. Output: $OUTPUT"; fi

# Case EG5: .sh file in a directory with spaces in its name → handled correctly
REPO_EG5=$(make_repo)
git -C "$REPO_EG5" checkout -q -b featureEG5
mkdir -p "$REPO_EG5/my tests"
cat > "$REPO_EG5/my tests/eg5.sh" <<'EOF'
#!/bin/bash
python3 -c "import sys"
EOF
git -C "$REPO_EG5" add "$REPO_EG5/my tests/eg5.sh"
git -C "$REPO_EG5" commit -q -m "add .sh in spaced dir"
EXIT_CODE=0
OUTPUT=$(cd "$REPO_EG5" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]]; then pass "EG5: exits 1 for .sh in spaced dir (HARD detected)"; else fail "EG5: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "HARD"; then pass "EG5: HARD found for spaced-path file"; else fail "EG5: HARD not found. Output: $OUTPUT"; fi

# Case EG6: python3 -c"..." (no space before quote) → out of scope by design, exits 0
REPO_EG6=$(make_repo)
git -C "$REPO_EG6" checkout -q -b featureEG6
mkdir -p "$REPO_EG6/tests"
cat > "$REPO_EG6/tests/eg6.sh" <<'EOF'
#!/bin/bash
python3 -c"import sys; print(sys.version)"
EOF
git -C "$REPO_EG6" add "$REPO_EG6/tests/eg6.sh"
git -C "$REPO_EG6" commit -q -m "add no-space python3 -c form"
EXIT_CODE=0
OUTPUT=$(cd "$REPO_EG6" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
# DETECT_RE requires [[:space:]]+ between -c and quote — no-space form is out of scope.
if [[ $EXIT_CODE -eq 0 ]]; then pass "EG6: python3 -c\"...\" (no space) exits 0 (out of scope by design)"; else fail "EG6: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi

# Case EG7: versioned python3.11 -c → out of scope by design, exits 0
REPO_EG7=$(make_repo)
git -C "$REPO_EG7" checkout -q -b featureEG7
mkdir -p "$REPO_EG7/tests"
cat > "$REPO_EG7/tests/eg7.sh" <<'EOF'
#!/bin/bash
python3.11 -c "import sys; print(sys.version)"
EOF
git -C "$REPO_EG7" add "$REPO_EG7/tests/eg7.sh"
git -C "$REPO_EG7" commit -q -m "versioned python binary"
EXIT_CODE=0
OUTPUT=$(cd "$REPO_EG7" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
# DETECT_RE: python3? matches only 'python' and 'python3'; 'python3.11' is out of scope.
if [[ $EXIT_CODE -eq 0 ]]; then pass "EG7: python3.11 -c exits 0 (versioned binary out of scope)"; else fail "EG7: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi

# Case EG8: pip/pip3 invocations → out of scope (DETECT_RE targets python3? -c only), exits 0
REPO_EG8=$(make_repo)
git -C "$REPO_EG8" checkout -q -b featureEG8
mkdir -p "$REPO_EG8/tests"
cat > "$REPO_EG8/tests/eg8.sh" <<'EOF'
#!/bin/bash
pip install requests
pip3 install flask
EOF
git -C "$REPO_EG8" add "$REPO_EG8/tests/eg8.sh"
git -C "$REPO_EG8" commit -q -m "pip not in scope"
EXIT_CODE=0
OUTPUT=$(cd "$REPO_EG8" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "EG8: pip/pip3 exits 0 (out of scope by design)"; else fail "EG8: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi

# Case E3: tests/fix-992-bare-python.sh is in EXCLUDED_FILES → not flagged
REPO_E3=$(make_repo)
git -C "$REPO_E3" checkout -q -b featureE3
mkdir -p "$REPO_E3/tests"
cat > "$REPO_E3/tests/fix-992-bare-python.sh" <<'EOF'
#!/bin/bash
python3 -c "import sys"
EOF
git -C "$REPO_E3" add "$REPO_E3/tests/fix-992-bare-python.sh"
git -C "$REPO_E3" commit -q -m "self-exclusion test"
EXIT_CODE=0
OUTPUT=$(cd "$REPO_E3" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "E3: tests/fix-992-bare-python.sh is excluded (self-exclusion)"; else fail "E3: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi

# Case E4: --all mode with excluded file → is_excluded() works in all-scan mode
REPO_E4=$(make_repo)
git -C "$REPO_E4" checkout -q -b featureE4
mkdir -p "$REPO_E4/tests"
cat > "$REPO_E4/tests/fix-277-doc-append-merge-union.sh" <<'EOF'
#!/bin/bash
python3 -c "import sys; sys.exit(0)"
EOF
git -C "$REPO_E4" add "$REPO_E4/tests/fix-277-doc-append-merge-union.sh"
git -C "$REPO_E4" commit -q -m "excluded file in all-scan"
EXIT_CODE=0
OUTPUT=$(cd "$REPO_E4" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "E4: --all skips excluded file (is_excluded in all-scan mode)"; else fail "E4: expected exit 0 in --all with excluded file, got $EXIT_CODE. Output: $OUTPUT"; fi

# Case EG9: .py file in diff → not scanned (grep on .sh extension), exits 0
REPO_EG9=$(make_repo)
git -C "$REPO_EG9" checkout -q -b featureEG9
cat > "$REPO_EG9/script.py" <<'EOF'
python3 -c "import sys"
EOF
git -C "$REPO_EG9" add "$REPO_EG9/script.py"
git -C "$REPO_EG9" commit -q -m "add .py with bare python3"
EXIT_CODE=0
OUTPUT=$(cd "$REPO_EG9" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "EG9: .py file exits 0 (only .sh files in scope)"; else fail "EG9: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"; fi
if echo "$OUTPUT" | grep -q "SKIPPED"; then pass "EG9: .py file → SKIPPED (no .sh files changed)"; else fail "EG9: SKIPPED heading not found. Output: $OUTPUT"; fi
