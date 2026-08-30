#!/bin/bash
# tests/feature-review-env-example/hard-violation-cases.sh
# Tests: bin/review-env-example
# Tags: env-example, bin, style-check, hard, scope:common
# Sourced by ../feature-review-env-example.sh — helpers come from there.
# The SKIPPED baseline plus the HARD classifications that block a commit:
# variable-name heading, issue reference, internal implementation detail,
# redundant Example: line, and an over-long comment block.

# ---------------------------------------------------------------------------
# Case 1: SKIPPED — no .env.example in diff
# ---------------------------------------------------------------------------
REPO1=$(make_repo)
git -C "$REPO1" checkout -q -b feature1
echo "some unrelated content" > "$REPO1/other.txt"
git -C "$REPO1" add "$REPO1/other.txt"
git -C "$REPO1" commit -q -m "add unrelated file"

EXIT_CODE=0
OUTPUT=$(cd "$REPO1" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 1: expected exit 0, got $EXIT_CODE"
else
    pass "Case 1: exits 0 when no .env.example changed"
fi

if echo "$OUTPUT" | grep -q "## Env-example Review: SKIPPED"; then
    pass "Case 1: output contains SKIPPED"
else
    fail "Case 1: SKIPPED not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 2: HARD — variable-name heading repeat
# ---------------------------------------------------------------------------
REPO2=$(make_repo)
git -C "$REPO2" checkout -q -b feature2
cat > "$REPO2/.env.example" <<'EOF'
# MYVAR — controls widget display
# What you can do: turn it on or off.
# Format: 0 or 1.
MYVAR=0
EOF
git -C "$REPO2" add "$REPO2/.env.example"
git -C "$REPO2" commit -q -m "add .env.example with variable-name heading"

EXIT_CODE=0
OUTPUT=$(cd "$REPO2" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 2: exits 1 for variable-name heading repeat"
else
    fail "Case 2: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "HARD"; then
    pass "Case 2: output contains HARD"
else
    fail "Case 2: HARD not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 3: HARD — issue reference (#123) in comment line
# ---------------------------------------------------------------------------
REPO3=$(make_repo)
git -C "$REPO3" checkout -q -b feature3
cat > "$REPO3/.env.example" <<'EOF'
# What you can do: enable widget mode (#123).
# What you can't do: affect anything else.
# Format: 0 or 1.
MYVAR=0
EOF
git -C "$REPO3" add "$REPO3/.env.example"
git -C "$REPO3" commit -q -m "add .env.example with issue reference"

EXIT_CODE=0
OUTPUT=$(cd "$REPO3" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 3: exits 1 for issue reference (#123)"
else
    fail "Case 3: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "HARD"; then
    pass "Case 3: output contains HARD"
else
    fail "Case 3: HARD not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 4: HARD — internal implementation detail variants
#   (path with /, bare .js filename, hook event name, protocol term)
# ---------------------------------------------------------------------------
REPO4=$(make_repo)
git -C "$REPO4" checkout -q -b feature4
cat > "$REPO4/.env.example" <<'EOF'
# What you can do: enable widget mode (used by hooks/foo.js).
# Read by workflow-state.js at PostToolUse; orchestrator-injects this value.
# Format: 0 or 1.
MYVAR=0
EOF
git -C "$REPO4" add "$REPO4/.env.example"
git -C "$REPO4" commit -q -m "add .env.example with internal implementation detail patterns"

EXIT_CODE=0
OUTPUT=$(cd "$REPO4" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 4: exits 1 for internal implementation detail"
else
    fail "Case 4: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "HARD"; then
    pass "Case 4: output contains HARD"
else
    fail "Case 4: HARD not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 8: HARD — redundant Example: line
# ---------------------------------------------------------------------------
REPO8=$(make_repo)
git -C "$REPO8" checkout -q -b feature8
cat > "$REPO8/.env.example" <<'EOF'
# What you can do: enable widget mode.
# What you can't do: affect anything else.
# Format: 0 or 1.
# Example: MYVAR=somevalue
MYVAR=0
EOF
git -C "$REPO8" add "$REPO8/.env.example"
git -C "$REPO8" commit -q -m "add .env.example with redundant Example: line"

EXIT_CODE=0
OUTPUT=$(cd "$REPO8" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 8: exits 1 for redundant Example: line"
else
    fail "Case 8: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "HARD"; then
    pass "Case 8: output contains HARD"
else
    fail "Case 8: HARD not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 9: HARD — comment block exceeds 5 lines (6 # lines before VAR=)
# ---------------------------------------------------------------------------
REPO9=$(make_repo)
git -C "$REPO9" checkout -q -b feature9
cat > "$REPO9/.env.example" <<'EOF'
# Comment line 1
# Comment line 2
# Comment line 3
# Comment line 4
# Comment line 5
# Comment line 6
MYVAR=0
EOF
git -C "$REPO9" add "$REPO9/.env.example"
git -C "$REPO9" commit -q -m "add .env.example with 6-line comment block"

EXIT_CODE=0
OUTPUT=$(cd "$REPO9" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 9: exits 1 for comment block > 5 lines"
else
    fail "Case 9: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "HARD"; then
    pass "Case 9: output contains HARD"
else
    fail "Case 9: HARD not found. Output: $OUTPUT"
fi
