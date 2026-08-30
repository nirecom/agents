#!/bin/bash
# tests/feature-review-env-example/warn-and-clean-cases.sh
# Tests: bin/review-env-example
# Tags: env-example, bin, style-check, warn, scope:common
# Sourced by ../feature-review-env-example.sh — helpers come from there.
# The other side of the classification: findings that WARN without blocking,
# and the fully compliant entry that reports PERFORMED with no finding at all.

# ---------------------------------------------------------------------------
# Case 10: WARN-only — architecture rationale phrase ("eliminates race condition")
# ---------------------------------------------------------------------------
REPO10=$(make_repo)
git -C "$REPO10" checkout -q -b feature10
cat > "$REPO10/.env.example" <<'EOF'
# Enable widget mode, which eliminates race condition on startup.
# You can't do: does not affect anything else.
# Format: 0 (off) | 1 (on).
MYVAR=0
EOF
git -C "$REPO10" add "$REPO10/.env.example"
git -C "$REPO10" commit -q -m "add .env.example with architecture rationale"

EXIT_CODE=0
OUTPUT=$(cd "$REPO10" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 10: expected exit 0 (WARN-only), got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 10: exits 0 for WARN-only (architecture rationale)"
fi

if echo "$OUTPUT" | grep -q "WARN"; then
    pass "Case 10: output contains WARN"
else
    fail "Case 10: WARN not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 11: WARN-only — command reference ("Run bash")
# ---------------------------------------------------------------------------
REPO11=$(make_repo)
git -C "$REPO11" checkout -q -b feature11
cat > "$REPO11/.env.example" <<'EOF'
# Enable widget mode. Run bash to set this up.
# You can't do: does not affect anything else.
# Format: 0 (off) | 1 (on).
MYVAR=0
EOF
git -C "$REPO11" add "$REPO11/.env.example"
git -C "$REPO11" commit -q -m "add .env.example with command reference"

EXIT_CODE=0
OUTPUT=$(cd "$REPO11" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 11: expected exit 0 (WARN-only), got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 11: exits 0 for WARN-only (command reference)"
fi

if echo "$OUTPUT" | grep -q "WARN"; then
    pass "Case 11: output contains WARN"
else
    fail "Case 11: WARN not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 12: Clean compliant case — PERFORMED, exit 0
# ---------------------------------------------------------------------------
REPO12=$(make_repo)
git -C "$REPO12" checkout -q -b feature12
write_compliant_entry "$REPO12/.env.example"
git -C "$REPO12" add "$REPO12/.env.example"
git -C "$REPO12" commit -q -m "add compliant .env.example"

EXIT_CODE=0
OUTPUT=$(cd "$REPO12" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 12: expected exit 0 for clean compliant case, got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 12: exits 0 for clean compliant case"
fi

if echo "$OUTPUT" | grep -q "## Env-example Review: PERFORMED"; then
    pass "Case 12: output contains PERFORMED header"
else
    fail "Case 12: PERFORMED header not found. Output: $OUTPUT"
fi
