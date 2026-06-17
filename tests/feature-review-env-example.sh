#!/bin/bash
# Tests: bin/review-env-example
# Tags: env-example, bin, style-check
# Tests for bin/review-env-example
# Verifies: SKIPPED/PERFORMED status labels, HARD/WARN classification,
# _archived/ and node_modules/ exclusion, --base flag, --all flag,
# merge-base failure handling.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-env-example"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper (from rules/test/macos-timeout.md)
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Helper: create a fresh isolated temp git repo with a main branch + initial commit
# Uses an empty hooksPath to avoid inheriting global git hooks (e.g. ENFORCE_WORKTREE).
# ---------------------------------------------------------------------------
EMPTY_HOOKS_DIR="$TMPDIR_BASE/no-hooks"
mkdir -p "$EMPTY_HOOKS_DIR"
EMPTY_EXCLUDES="$TMPDIR_BASE/empty-excludes"
: > "$EMPTY_EXCLUDES"

make_repo() {
    local repo
    repo=$(mktemp -d -p "$TMPDIR_BASE")
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath "$EMPTY_HOOKS_DIR"
    git -C "$repo" config core.excludesFile "$EMPTY_EXCLUDES"
    git -C "$repo" config core.autocrlf false
    git -C "$repo" checkout -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

# Helper: write a compliant .env.example entry (3 comment lines within 1-5 cap, no banned content)
write_compliant_entry() {
    local path="$1"
    cat > "$path" <<'EOF'
MYVAR=default
# What you can do: control widget display.
# What you can't do: affect server-side behavior.
# Format: 0 (off) or 1 (on). Default: 0.
EOF
}

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

# ---------------------------------------------------------------------------
# Case 10: WARN-only — architecture rationale phrase ("eliminates race condition")
# ---------------------------------------------------------------------------
REPO10=$(make_repo)
git -C "$REPO10" checkout -q -b feature10
cat > "$REPO10/.env.example" <<'EOF'
# What you can do: enable widget mode (eliminates race condition on startup).
# What you can't do: affect anything else.
# Format: 0 or 1.
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
# What you can do: enable widget mode. Run bash to set this up.
# What you can't do: affect anything else.
# Format: 0 or 1.
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

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ $ERRORS -gt 0 ]]; then echo ""; echo "FAILED: $ERRORS test(s) failed"; exit 1; else echo ""; echo "All tests passed"; fi
