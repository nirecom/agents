#!/bin/bash
# Tests: bin/review-prompt-size
# Tags: prompt-size, review, bin, uncommitted
# Tests for bin/review-prompt-size — 3-source union diff detection
# Verifies that staged, unstaged, and untracked prompt files are all detected
# (not just committed diffs), across SKILL.md, rules/*.md, agents/*.md,
# and skills/_shared/*.md.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-prompt-size"
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

# --- Existence gate ---------------------------------------------------------
if [ ! -f "$SCRIPT" ]; then
    echo "SKIP: bin/review-prompt-size not yet created (write-code step pending)"
    echo ""
    echo "Results: 0 passed, 0 failed (skipped)"
    exit 0
fi

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

if echo "$OUTPUT" | grep -q "## Prompt Size Review: PERFORMED"; then
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

if echo "$OUTPUT" | grep -q "## Prompt Size Review: PERFORMED"; then
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

if echo "$OUTPUT" | grep -q "## Prompt Size Review: PERFORMED"; then
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
# Case 4: Staged rules/coding/test.md 150 lines → detected (WARN)
# ---------------------------------------------------------------------------
REPO4=$(make_repo)
git -C "$REPO4" checkout -q -b feature4
mkdir -p "$REPO4/rules/coding"
make_lines 150 > "$REPO4/rules/coding/test.md"
git -C "$REPO4" add "$REPO4/rules/coding/test.md"
# DO NOT commit — file is only staged

EXIT_CODE=0
OUTPUT=$(cd "$REPO4" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 4: expected exit 0, got $EXIT_CODE"
else
    pass "Case 4: exits 0 for staged rules/*.md"
fi

if echo "$OUTPUT" | grep -q "## Prompt Size Review: PERFORMED"; then
    pass "Case 4: PERFORMED for staged rules/*.md"
else
    fail "Case 4: PERFORMED not found for staged rules/*.md. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "exceeds 100-line safety net"; then
    pass "Case 4: line-count warning present for staged 150-line rules/*.md"
else
    fail "Case 4: 'exceeds 100-line safety net' warning missing for staged rules/*.md. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 5: Staged agents/foo.md 150 lines → detected (WARN)
# ---------------------------------------------------------------------------
REPO5=$(make_repo)
git -C "$REPO5" checkout -q -b feature5
mkdir -p "$REPO5/agents"
make_lines 150 > "$REPO5/agents/foo.md"
git -C "$REPO5" add "$REPO5/agents/foo.md"
# DO NOT commit — file is only staged

EXIT_CODE=0
OUTPUT=$(cd "$REPO5" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 5: expected exit 0, got $EXIT_CODE"
else
    pass "Case 5: exits 0 for staged agents/*.md"
fi

if echo "$OUTPUT" | grep -q "## Prompt Size Review: PERFORMED"; then
    pass "Case 5: PERFORMED for staged agents/*.md"
else
    fail "Case 5: PERFORMED not found for staged agents/*.md. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "exceeds 100-line safety net"; then
    pass "Case 5: line-count warning present for staged 150-line agents/*.md"
else
    fail "Case 5: 'exceeds 100-line safety net' warning missing for staged agents/*.md. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 6: Staged skills/_shared/bar.md 201 lines → HARD (exit 1)
# ---------------------------------------------------------------------------
REPO6=$(make_repo)
git -C "$REPO6" checkout -q -b feature6
mkdir -p "$REPO6/skills/_shared"
make_lines 201 > "$REPO6/skills/_shared/bar.md"
git -C "$REPO6" add "$REPO6/skills/_shared/bar.md"
# DO NOT commit — file is only staged

EXIT_CODE=0
OUTPUT=$(cd "$REPO6" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 6: exits 1 for staged 201-line skills/_shared/*.md (HARD)"
else
    fail "Case 6: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "exceeds 200-line hard limit"; then
    pass "Case 6: output contains 'exceeds 200-line hard limit'"
else
    fail "Case 6: 'exceeds 200-line hard limit' not found. Output: $OUTPUT"
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
