#!/bin/bash
# tests/feature-review-env-example/endif-blank-line-cases.sh
# Tests: bin/review-env-example
# Tags: env-example, bin, style-check, conditional-block, scope:common
# Sourced by ../feature-review-env-example.sh — helpers come from there.
# One check and its three negative controls: the blank line before #@endif.

# ---------------------------------------------------------------------------
# Case 18: HARD — blank line immediately before #@endif
# ---------------------------------------------------------------------------
REPO18=$(make_repo)
git -C "$REPO18" checkout -q -b feature18
cat > "$REPO18/.env.example" <<'EOF'
#@if windows
# Control this on Windows.
# Format: path-style value.
MYVAR=C:\example

#@endif
EOF
git -C "$REPO18" add "$REPO18/.env.example"
git -C "$REPO18" commit -q -m "add .env.example with blank line before #@endif"

EXIT_CODE=0
OUTPUT=$(cd "$REPO18" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 18: exits 1 for blank line before #@endif"
else
    fail "Case 18: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -qE '^HARD:'; then
    pass "Case 18: output contains a HARD: finding"
else
    fail "Case 18: no HARD: finding line found. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "blank line before #@endif"; then
    pass "Case 18: output contains 'blank line before #@endif'"
else
    fail "Case 18: 'blank line before #@endif' not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 19: Clean path — #@endif with no blank line before it (no false positive)
# ---------------------------------------------------------------------------
REPO19=$(make_repo)
git -C "$REPO19" checkout -q -b feature19
cat > "$REPO19/.env.example" <<'EOF'
#@if windows
# Control this on Windows.
# Format: path-style value.
MYVAR=C:\example
#@endif
EOF
git -C "$REPO19" add "$REPO19/.env.example"
git -C "$REPO19" commit -q -m "add .env.example with #@endif and no blank line before it"

EXIT_CODE=0
OUTPUT=$(cd "$REPO19" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 19: expected exit 0 for clean #@endif (no blank before), got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 19: exits 0 when no blank line before #@endif"
fi

if echo "$OUTPUT" | grep -q "blank line before #@endif"; then
    fail "Case 19: unexpected 'blank line before #@endif' in output. Output: $OUTPUT"
else
    pass "Case 19: output does not contain 'blank line before #@endif'"
fi

# ---------------------------------------------------------------------------
# Case 20: Edge — blank line before #@if (block separator) is allowed
# ---------------------------------------------------------------------------
REPO20=$(make_repo)
git -C "$REPO20" checkout -q -b feature20
cat > "$REPO20/.env.example" <<'EOF'
# Control widget display.
# You can't do: does not affect server-side behavior.
# Format: 0 (off) | 1 (on). Default: 0.
MYVAR=default

#@if windows
# Control this on Windows.
# Format: path-style value.
MYVAR=C:\example
#@endif
EOF
git -C "$REPO20" add "$REPO20/.env.example"
git -C "$REPO20" commit -q -m "add .env.example with blank line before #@if (allowed)"

EXIT_CODE=0
OUTPUT=$(cd "$REPO20" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 20: expected exit 0 for blank before #@if (allowed), got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 20: exits 0 when blank line is before #@if (not #@endif)"
fi

if echo "$OUTPUT" | grep -q "blank line before #@endif"; then
    fail "Case 20: unexpected 'blank line before #@endif' finding for blank-before-#@if case. Output: $OUTPUT"
else
    pass "Case 20: no false positive for blank line before #@if"
fi

# ---------------------------------------------------------------------------
# Case 21: Edge — file starts with #@endif as first line (prev_was_blank=0 init)
# ---------------------------------------------------------------------------
REPO21=$(make_repo)
git -C "$REPO21" checkout -q -b feature21
cat > "$REPO21/.env.example" <<'EOF'
#@endif
# Control widget display.
# You can't do: does not affect server-side behavior.
# Format: 0 (off) | 1 (on).
MYVAR=default
EOF
git -C "$REPO21" add "$REPO21/.env.example"
git -C "$REPO21" commit -q -m "add .env.example with #@endif as first line"

EXIT_CODE=0
OUTPUT=$(cd "$REPO21" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 21: expected exit 0 for #@endif as first line (no false positive), got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 21: exits 0 when #@endif is first line (prev_was_blank=0 initial value)"
fi

if echo "$OUTPUT" | grep -q "blank line before #@endif"; then
    fail "Case 21: unexpected 'blank line before #@endif' finding for first-line #@endif. Output: $OUTPUT"
else
    pass "Case 21: no false positive for #@endif as first line"
fi
