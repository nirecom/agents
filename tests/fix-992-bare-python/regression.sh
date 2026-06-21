# GAP1: comment-only occurrence — .sh with python3 -c "..." only in a # comment line
# Source behavior: comment lines are not filtered; this documents current behavior.
REPO_GAP1=$(make_repo)
git -C "$REPO_GAP1" checkout -q -b featureGAP1
mkdir -p "$REPO_GAP1/tests"
cat > "$REPO_GAP1/tests/gap1.sh" <<'EOF'
#!/bin/bash
# python3 -c "import sys; print(sys.version)" — comment only, no live call
echo "done"
EOF
git -C "$REPO_GAP1" add "$REPO_GAP1/tests/gap1.sh"
git -C "$REPO_GAP1" commit -q -m "add .sh with python3 only in comment"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_GAP1" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?
# Current source flags comment lines as HARD (grep matches the pattern in # lines).
if [[ $EXIT_CODE -eq 1 ]]; then pass "GAP1: comment-line python3 -c flagged as HARD (current behavior)"; else fail "GAP1: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"; fi

# GAP2: security — metacharacter in --base value → git fails → SKIPPED, exit 0, no injection
REPO_SEC=$(make_repo)
git -C "$REPO_SEC" checkout -q -b featureSEC
mkdir -p "$REPO_SEC/tests"
printf '#!/bin/bash\necho hi\n' > "$REPO_SEC/tests/sec.sh"
git -C "$REPO_SEC" add "$REPO_SEC/tests/sec.sh"
git -C "$REPO_SEC" commit -q -m "sec test"

EXIT_CODE=0
OUTPUT=$(cd "$REPO_SEC" && run_with_timeout bash "$SCRIPT" --base 'main; echo injected' 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then pass "GAP2: metachar in --base exits 0"; else fail "GAP2: expected exit 0, got $EXIT_CODE"; fi
if ! echo "$OUTPUT" | grep -qx "injected"; then pass "GAP2: injection not executed"; else fail "GAP2: injection detected in output. Output: $OUTPUT"; fi

# GAP3: regression — --all on real worktree must not flag known-clean files
EXIT_CODE=0
OUTPUT=$(cd "$AGENTS_ROOT" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT_CODE=$?
if ! echo "$OUTPUT" | grep -qE '^HARD: bin/audit-tests\.sh:'; then pass "REG1: audit-tests.sh clean"; else fail "REG1: audit-tests.sh has HARD finding. Output: $OUTPUT"; fi
if ! echo "$OUTPUT" | grep -qE '^HARD: tests/feature-mcp-fs-server\.sh:'; then pass "REG2: feature-mcp-fs-server.sh clean"; else fail "REG2: feature-mcp-fs-server.sh has HARD finding"; fi
if ! echo "$OUTPUT" | grep -qE '^HARD: tests/feature-test-cleanup-944\.sh:'; then pass "REG3: feature-test-cleanup-944.sh clean"; else fail "REG3: feature-test-cleanup-944.sh has HARD finding"; fi

# Case IDP1: idempotency — running twice yields identical output (stateless script)
REPO_IDP=$(make_repo)
git -C "$REPO_IDP" checkout -q -b featureIDP
mkdir -p "$REPO_IDP/tests"
printf '#!/bin/bash\nuv run python -c "print(1)"\n' > "$REPO_IDP/tests/idp.sh"
git -C "$REPO_IDP" add "$REPO_IDP/tests/idp.sh"
git -C "$REPO_IDP" commit -q -m "idp"
OUT1=$(cd "$REPO_IDP" && run_with_timeout bash "$SCRIPT" --all 2>&1)
OUT2=$(cd "$REPO_IDP" && run_with_timeout bash "$SCRIPT" --all 2>&1)
if [[ "$OUT1" = "$OUT2" ]]; then pass "IDP1: identical output on second run"; else fail "IDP1: output differs between runs"; fi
