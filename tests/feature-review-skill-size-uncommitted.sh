#!/bin/bash
# Tests: bin/review-skill-size
# Tags: skill-size, review, bin, uncommitted
# Tests for bin/review-skill-size — 3-source union diff detection
# Verifies that staged, unstaged, and untracked SKILL.md files are all detected
# (not just committed diffs), and that all cases exit 0.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-skill-size"
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
# Case 1: Staged SKILL.md 150 lines (uncommitted, 3-source union)
# ---------------------------------------------------------------------------
REPO1=$(make_repo)
git -C "$REPO1" checkout -q -b feature1
mkdir -p "$REPO1/skills/foo"
make_lines 150 > "$REPO1/skills/foo/SKILL.md"
git -C "$REPO1" add "$REPO1/skills/foo/SKILL.md"
# DO NOT commit — file is only staged

EXIT_CODE=0
OUTPUT=$(cd "$REPO1" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 1: expected exit 0, got $EXIT_CODE"
else
    pass "Case 1: exits 0 for staged SKILL.md"
fi

if echo "$OUTPUT" | grep -q "## Skill Size Review: PERFORMED"; then
    pass "Case 1: PERFORMED for staged SKILL.md"
else
    fail "Case 1: PERFORMED not found for staged SKILL.md. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "exceeds 100-line safety net"; then
    pass "Case 1: line-count warning present for staged 150-line SKILL.md"
else
    fail "Case 1: 'exceeds 100-line safety net' warning missing for staged file. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 2: Unstaged modified SKILL.md 150 lines (3-source union)
# ---------------------------------------------------------------------------
REPO2=$(make_repo)
git -C "$REPO2" checkout -q -b feature2
mkdir -p "$REPO2/skills/bar"
# Create and commit a small SKILL.md first
echo "# Small skill" > "$REPO2/skills/bar/SKILL.md"
git -C "$REPO2" add "$REPO2/skills/bar/SKILL.md"
git -C "$REPO2" commit -q -m "add small SKILL.md"
# Now overwrite with 150 lines WITHOUT staging
make_lines 150 > "$REPO2/skills/bar/SKILL.md"
# DO NOT git add — file is modified but unstaged

EXIT_CODE=0
OUTPUT=$(cd "$REPO2" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 2: expected exit 0, got $EXIT_CODE"
else
    pass "Case 2: exits 0 for unstaged modified SKILL.md"
fi

if echo "$OUTPUT" | grep -q "## Skill Size Review: PERFORMED"; then
    pass "Case 2: PERFORMED for unstaged SKILL.md"
else
    fail "Case 2: PERFORMED not found for unstaged SKILL.md. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "exceeds 100-line safety net"; then
    pass "Case 2: line-count warning present for unstaged 150-line SKILL.md"
else
    fail "Case 2: 'exceeds 100-line safety net' warning missing for unstaged file. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 3: Untracked SKILL.md 150 lines (3-source union)
# ---------------------------------------------------------------------------
REPO3=$(make_repo)
git -C "$REPO3" checkout -q -b feature3
mkdir -p "$REPO3/skills/baz"
# Create with NO git add
make_lines 150 > "$REPO3/skills/baz/SKILL.md"

EXIT_CODE=0
OUTPUT=$(cd "$REPO3" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 3: expected exit 0, got $EXIT_CODE"
else
    pass "Case 3: exits 0 for untracked SKILL.md"
fi

if echo "$OUTPUT" | grep -q "## Skill Size Review: PERFORMED"; then
    pass "Case 3: PERFORMED for untracked SKILL.md"
else
    fail "Case 3: PERFORMED not found for untracked SKILL.md. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "exceeds 100-line safety net"; then
    pass "Case 3: line-count warning present for untracked 150-line SKILL.md"
else
    fail "Case 3: 'exceeds 100-line safety net' warning missing for untracked file. Output: $OUTPUT"
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
