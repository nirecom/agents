#!/bin/bash
# Tests: bin/review-skill-size, bin/review-code-size
# Tags: skill-size, code-size, review, bin, hard-block
# Tests for issue #741: HARD-blocking exit 1 behavior in diff mode
# Verifies: review-skill-size HARD at >200 lines exits 1, --all always exits 0;
#           review-code-size HARD at >500 lines exits 1, --all always exits 0;
#           boundary conditions (exactly 200 / 500 lines → exit 0).
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_SKILL="$AGENTS_ROOT/bin/review-skill-size"
SCRIPT_CODE="$AGENTS_ROOT/bin/review-code-size"
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

make_repo() {
    local repo
    repo=$(mktemp -d)
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath "$EMPTY_HOOKS_DIR"
    git -C "$repo" config core.autocrlf false
    git -C "$repo" checkout -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

# Helper: generate a file with exactly N lines
make_lines() {
    local n="$1"
    local i
    for ((i = 1; i <= n; i++)); do
        echo "line $i"
    done
}

# ---------------------------------------------------------------------------
# Case 1: review-skill-size — 201-line SKILL.md in diff mode → exit 1
# ---------------------------------------------------------------------------
REPO=$(make_repo)
git -C "$REPO" checkout -q -b feature-c1
mkdir -p "$REPO/skills/somename"
make_lines 201 > "$REPO/skills/somename/SKILL.md"
git -C "$REPO" add "$REPO/skills/somename/SKILL.md"
git -C "$REPO" commit -q -m "add 201-line SKILL.md"

EXIT_CODE=0
OUTPUT=$(cd "$REPO" && run_with_timeout bash "$SCRIPT_SKILL" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 1: review-skill-size exits 1 for 201-line SKILL.md in diff mode"
else
    fail "Case 1: expected exit 1, got $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# Case 2: review-skill-size — HARD output contains expected message and path reference
# (reuse output from Case 1)
# ---------------------------------------------------------------------------
if echo "$OUTPUT" | grep -q "exceeds 200-line hard limit"; then
    pass "Case 2: HARD output contains 'exceeds 200-line hard limit'"
else
    fail "Case 2: 'exceeds 200-line hard limit' not found. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "skills/"; then
    pass "Case 2: HARD output contains 'skills/' path reference"
else
    fail "Case 2: 'skills/' path reference not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 3: review-skill-size — 201-line SKILL.md in --all mode → exit 0
# ---------------------------------------------------------------------------
REPO=$(make_repo)
mkdir -p "$REPO/skills/somename"
make_lines 201 > "$REPO/skills/somename/SKILL.md"

EXIT_CODE=0
OUTPUT=$(cd "$REPO" && run_with_timeout bash "$SCRIPT_SKILL" --all 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 3: review-skill-size exits 0 for 201-line SKILL.md in --all mode"
else
    fail "Case 3: expected exit 0 (--all never blocks), got $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# Case 4: review-skill-size — 150-line SKILL.md in diff mode → exit 0 (WARN only)
# ---------------------------------------------------------------------------
REPO=$(make_repo)
git -C "$REPO" checkout -q -b feature-c4
mkdir -p "$REPO/skills/somename"
make_lines 150 > "$REPO/skills/somename/SKILL.md"
git -C "$REPO" add "$REPO/skills/somename/SKILL.md"
git -C "$REPO" commit -q -m "add 150-line SKILL.md"

EXIT_CODE=0
OUTPUT=$(cd "$REPO" && run_with_timeout bash "$SCRIPT_SKILL" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 4: review-skill-size exits 0 for 150-line SKILL.md (WARN only)"
else
    fail "Case 4: expected exit 0 for WARN threshold, got $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# Case 5: review-skill-size — exactly 200 lines → exit 0 (boundary: >200, not >=200)
# ---------------------------------------------------------------------------
REPO=$(make_repo)
git -C "$REPO" checkout -q -b feature-c5
mkdir -p "$REPO/skills/somename"
make_lines 200 > "$REPO/skills/somename/SKILL.md"
git -C "$REPO" add "$REPO/skills/somename/SKILL.md"
git -C "$REPO" commit -q -m "add 200-line SKILL.md"

EXIT_CODE=0
OUTPUT=$(cd "$REPO" && run_with_timeout bash "$SCRIPT_SKILL" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 5: review-skill-size exits 0 for exactly 200 lines (boundary: >200 triggers HARD)"
else
    fail "Case 5: expected exit 0 for exactly 200 lines, got $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# Case 6: review-code-size — 501-line JS in diff mode → exit 1
# ---------------------------------------------------------------------------
REPO=$(make_repo)
git -C "$REPO" checkout -q -b feature-c6
mkdir -p "$REPO/bin"
make_lines 501 > "$REPO/bin/somefile.js"
git -C "$REPO" add "$REPO/bin/somefile.js"
git -C "$REPO" commit -q -m "add 501-line JS file"

EXIT_CODE=0
OUTPUT=$(cd "$REPO" && run_with_timeout bash "$SCRIPT_CODE" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 6: review-code-size exits 1 for 501-line JS in diff mode"
else
    fail "Case 6: expected exit 1, got $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# Case 7: review-code-size — HARD output contains expected message and file-split.md reference
# (reuse output from Case 6)
# ---------------------------------------------------------------------------
if echo "$OUTPUT" | grep -q "exceeds 500-line hard limit"; then
    pass "Case 7: HARD output contains 'exceeds 500-line hard limit'"
else
    fail "Case 7: 'exceeds 500-line hard limit' not found. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "file-split.md"; then
    pass "Case 7: HARD output contains 'file-split.md' reference"
else
    fail "Case 7: 'file-split.md' reference not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 8: review-code-size — 501-line JS in --all mode → exit 0
# ---------------------------------------------------------------------------
REPO=$(make_repo)
mkdir -p "$REPO/bin"
make_lines 501 > "$REPO/bin/somefile.js"

EXIT_CODE=0
OUTPUT=$(cd "$REPO" && run_with_timeout bash "$SCRIPT_CODE" --all 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 8: review-code-size exits 0 for 501-line JS in --all mode"
else
    fail "Case 8: expected exit 0 (--all never blocks), got $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# Case 9: review-code-size — 350-line JS in diff mode → exit 0 (WARN only)
# ---------------------------------------------------------------------------
REPO=$(make_repo)
git -C "$REPO" checkout -q -b feature-c9
mkdir -p "$REPO/bin"
make_lines 350 > "$REPO/bin/somefile.js"
git -C "$REPO" add "$REPO/bin/somefile.js"
git -C "$REPO" commit -q -m "add 350-line JS file"

EXIT_CODE=0
OUTPUT=$(cd "$REPO" && run_with_timeout bash "$SCRIPT_CODE" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 9: review-code-size exits 0 for 350-line JS (WARN only)"
else
    fail "Case 9: expected exit 0 for WARN threshold, got $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# Case 10: review-code-size — exactly 500 lines → exit 0 (boundary: >500, not >=500)
# ---------------------------------------------------------------------------
REPO=$(make_repo)
git -C "$REPO" checkout -q -b feature-c10
mkdir -p "$REPO/bin"
make_lines 500 > "$REPO/bin/somefile.js"
git -C "$REPO" add "$REPO/bin/somefile.js"
git -C "$REPO" commit -q -m "add 500-line JS file"

EXIT_CODE=0
OUTPUT=$(cd "$REPO" && run_with_timeout bash "$SCRIPT_CODE" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 10: review-code-size exits 0 for exactly 500 lines (boundary: >500 triggers HARD)"
else
    fail "Case 10: expected exit 0 for exactly 500 lines, got $EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit "$ERRORS"
fi
