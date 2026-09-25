#!/bin/bash
# tests/feature-review-env-example/scope-and-flag-cases.sh
# Tests: bin/review-env-example
# Tags: env-example, bin, style-check, cli, exclusion, scope:common
# Sourced by ../feature-review-env-example.sh — helpers come from there.
# What the checker looks AT rather than what it says: the _archived/ and
# node_modules/ exclusions, --base with an explicit SHA, --all as audit mode
# that never blocks, and a merge base that cannot be resolved at all.

# ---------------------------------------------------------------------------
# Case 13: _archived/ files excluded
# ---------------------------------------------------------------------------
REPO13=$(make_repo)
git -C "$REPO13" checkout -q -b feature13
mkdir -p "$REPO13/_archived"
cat > "$REPO13/_archived/.env.example" <<'EOF'
# MYVAR — controls widget display
# What you can do: turn it on or off (#123, hooks/foo.js).
# Format: 0 or 1.
# Example: MYVAR=somevalue
MYVAR=0
EOF
git -C "$REPO13" add "$REPO13/_archived/.env.example"
git -C "$REPO13" commit -q -m "add archived .env.example with violations"

EXIT_CODE=0
OUTPUT=$(cd "$REPO13" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 13: expected exit 0 for _archived/ exclusion, got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 13: exits 0 (HARD violations in _archived/ excluded)"
fi

# ---------------------------------------------------------------------------
# Case 14: node_modules/ files excluded
# ---------------------------------------------------------------------------
REPO14=$(make_repo)
git -C "$REPO14" checkout -q -b feature14
mkdir -p "$REPO14/node_modules/some-package"
cat > "$REPO14/node_modules/some-package/.env.example" <<'EOF'
# MYVAR — controls widget display
# What you can do: turn it on or off (#123, hooks/foo.js).
# Format: 0 or 1.
# Example: MYVAR=somevalue
MYVAR=0
EOF
git -C "$REPO14" add "$REPO14/node_modules/some-package/.env.example"
git -C "$REPO14" commit -q -m "add node_modules .env.example with violations"

EXIT_CODE=0
OUTPUT=$(cd "$REPO14" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 14: expected exit 0 for node_modules/ exclusion, got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 14: exits 0 (HARD violations in node_modules/ excluded)"
fi

# ---------------------------------------------------------------------------
# Case 15: --base <ref> explicit merge base works with explicit SHA
# ---------------------------------------------------------------------------
REPO15=$(make_repo)
BASE_SHA=$(git -C "$REPO15" rev-parse HEAD)
git -C "$REPO15" checkout -q -b feature15
write_compliant_entry "$REPO15/.env.example"
git -C "$REPO15" add "$REPO15/.env.example"
git -C "$REPO15" commit -q -m "add compliant .env.example on feature15"

EXIT_CODE=0
OUTPUT=$(cd "$REPO15" && run_with_timeout bash "$SCRIPT" --base "$BASE_SHA" 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 15: expected exit 0 with explicit SHA --base, got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 15: exits 0 with explicit SHA --base"
fi

if echo "$OUTPUT" | grep -q "## Env-example Review: PERFORMED"; then
    pass "Case 15: output contains PERFORMED with explicit SHA --base"
else
    fail "Case 15: PERFORMED not found with explicit SHA --base. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 16: --all never exits 1 even with HARD violations (audit mode)
# ---------------------------------------------------------------------------
REPO16=$(make_repo)
git -C "$REPO16" checkout -q -b feature16
cat > "$REPO16/.env.example" <<'EOF'
# MYVAR — controls widget display
# What you can do: turn it on or off (#123, hooks/foo.js).
# Format: 0 or 1.
# Example: MYVAR=somevalue
MYVAR=0
EOF
git -C "$REPO16" add "$REPO16/.env.example"
git -C "$REPO16" commit -q -m "add .env.example with HARD violations"

EXIT_CODE=0
OUTPUT=$(cd "$REPO16" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 16: expected exit 0 with --all even on HARD, got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 16: exits 0 with --all (audit mode never blocks)"
fi

# ---------------------------------------------------------------------------
# Case 17: merge-base resolution failure → SKIPPED gracefully (exit 0)
# ---------------------------------------------------------------------------
REPO17=$(make_repo)

EXIT_CODE=0
OUTPUT=$(cd "$REPO17" && run_with_timeout bash "$SCRIPT" --base nonexistent-xyz-ref-aaaaa 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 17: expected exit 0 when merge-base fails, got $EXIT_CODE"
else
    pass "Case 17: exits 0 when merge-base resolution fails"
fi

if echo "$OUTPUT" | grep -q "## Env-example Review: SKIPPED"; then
    pass "Case 17: output contains SKIPPED for bad base ref"
else
    fail "Case 17: SKIPPED not found. Output: $OUTPUT"
fi
