#!/bin/bash
# Tests for bin/review-skill-size
# Verifies: SKIPPED/PERFORMED status labels, line-count warnings,
# _archived/ exclusion, non-SKILL.md exclusion, --base flag, merge-base failure.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-skill-size"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper (from rules/test-rules/macos-timeout.md)
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
# Case 1: SKIPPED — no SKILL.md changed
# ---------------------------------------------------------------------------
REPO1=$(make_repo)
git -C "$REPO1" checkout -q -b feature1
mkdir -p "$REPO1/skills/foo"
echo "readme content" > "$REPO1/skills/foo/README.md"
git -C "$REPO1" add "$REPO1/skills/foo/README.md"
git -C "$REPO1" commit -q -m "add README only"

EXIT_CODE=0
OUTPUT=$(cd "$REPO1" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 1: expected exit 0, got $EXIT_CODE"
else
    pass "Case 1: exits 0 when no SKILL.md changed"
fi

if echo "$OUTPUT" | grep -q "## Skill Size Review: SKIPPED"; then
    pass "Case 1: output contains SKIPPED"
else
    fail "Case 1: SKIPPED not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 2: PERFORMED — 50-line SKILL.md (no line warning)
# ---------------------------------------------------------------------------
REPO2=$(make_repo)
git -C "$REPO2" checkout -q -b feature2
mkdir -p "$REPO2/skills/foo"
make_lines 50 > "$REPO2/skills/foo/SKILL.md"
git -C "$REPO2" add "$REPO2/skills/foo/SKILL.md"
git -C "$REPO2" commit -q -m "add 50-line SKILL.md"

EXIT_CODE=0
OUTPUT=$(cd "$REPO2" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 2: expected exit 0, got $EXIT_CODE"
else
    pass "Case 2: exits 0 for 50-line SKILL.md"
fi

if echo "$OUTPUT" | grep -q "## Skill Size Review: PERFORMED"; then
    pass "Case 2: output contains PERFORMED"
else
    fail "Case 2: PERFORMED not found. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "exceeds 100 lines"; then
    fail "Case 2: unexpected 'exceeds 100 lines' warning for 50-line file"
else
    pass "Case 2: no line-count warning for 50-line file"
fi

if echo "$OUTPUT" | grep -q "Manual review checklist"; then
    pass "Case 2: fixed quality guidance block present"
else
    fail "Case 2: quality guidance block missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 3: PERFORMED — 150-line SKILL.md (line warning expected)
# ---------------------------------------------------------------------------
REPO3=$(make_repo)
git -C "$REPO3" checkout -q -b feature3
mkdir -p "$REPO3/skills/foo"
make_lines 150 > "$REPO3/skills/foo/SKILL.md"
git -C "$REPO3" add "$REPO3/skills/foo/SKILL.md"
git -C "$REPO3" commit -q -m "add 150-line SKILL.md"

EXIT_CODE=0
OUTPUT=$(cd "$REPO3" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 3: expected exit 0, got $EXIT_CODE"
else
    pass "Case 3: exits 0 for 150-line SKILL.md"
fi

if echo "$OUTPUT" | grep -q "## Skill Size Review: PERFORMED"; then
    pass "Case 3: output contains PERFORMED"
else
    fail "Case 3: PERFORMED not found. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "exceeds 100 lines"; then
    pass "Case 3: line-count warning present for 150-line file"
else
    fail "Case 3: 'exceeds 100 lines' warning missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 4: _archived/ excluded
# ---------------------------------------------------------------------------
REPO4=$(make_repo)
git -C "$REPO4" checkout -q -b feature4
mkdir -p "$REPO4/skills/_archived/old"
make_lines 150 > "$REPO4/skills/_archived/old/SKILL.md"
git -C "$REPO4" add "$REPO4/skills/_archived/old/SKILL.md"
git -C "$REPO4" commit -q -m "add archived SKILL.md"

EXIT_CODE=0
OUTPUT=$(cd "$REPO4" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 4: expected exit 0, got $EXIT_CODE"
else
    pass "Case 4: exits 0 for _archived/ SKILL.md"
fi

if echo "$OUTPUT" | grep -q "SKIPPED"; then
    pass "Case 4: _archived/ SKILL.md excluded (SKIPPED)"
else
    fail "Case 4: _archived/ SKILL.md was not excluded. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 5: non-SKILL.md excluded
# ---------------------------------------------------------------------------
REPO5=$(make_repo)
git -C "$REPO5" checkout -q -b feature5
mkdir -p "$REPO5/skills/foo"
make_lines 150 > "$REPO5/skills/foo/README.md"
git -C "$REPO5" add "$REPO5/skills/foo/README.md"
git -C "$REPO5" commit -q -m "add skills/foo/README.md (not SKILL.md)"

EXIT_CODE=0
OUTPUT=$(cd "$REPO5" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 5: expected exit 0, got $EXIT_CODE"
else
    pass "Case 5: exits 0 for non-SKILL.md file"
fi

if echo "$OUTPUT" | grep -q "SKIPPED"; then
    pass "Case 5: non-SKILL.md excluded (SKIPPED)"
else
    fail "Case 5: non-SKILL.md was not excluded. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 6: --base option (explicit ref works)
# ---------------------------------------------------------------------------
REPO6=$(make_repo)
git -C "$REPO6" checkout -q -b feature6
mkdir -p "$REPO6/skills/bar"
make_lines 150 > "$REPO6/skills/bar/SKILL.md"
git -C "$REPO6" add "$REPO6/skills/bar/SKILL.md"
git -C "$REPO6" commit -q -m "add 150-line SKILL.md on feature6"

EXIT_CODE=0
OUTPUT=$(cd "$REPO6" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 6: expected exit 0, got $EXIT_CODE"
else
    pass "Case 6: exits 0 with explicit --base main"
fi

if echo "$OUTPUT" | grep -q "## Skill Size Review: PERFORMED"; then
    pass "Case 6: output contains PERFORMED with explicit --base"
else
    fail "Case 6: PERFORMED not found. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "exceeds 100 lines"; then
    pass "Case 6: line-count warning present with explicit --base"
else
    fail "Case 6: 'exceeds 100 lines' warning missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 7: merge-base resolution failure
# ---------------------------------------------------------------------------
REPO7=$(make_repo)

EXIT_CODE=0
OUTPUT=$(cd "$REPO7" && run_with_timeout bash "$SCRIPT" --base nonexistent-xyz-ref-aaaaa 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 7: expected exit 0, got $EXIT_CODE"
else
    pass "Case 7: exits 0 when merge-base resolution fails"
fi

if echo "$OUTPUT" | grep -q "## Skill Size Review: SKIPPED"; then
    pass "Case 7: output contains SKIPPED for bad base ref"
else
    fail "Case 7: SKIPPED not found. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -iq "merge-base unresolved"; then
    pass "Case 7: output contains 'merge-base unresolved'"
else
    fail "Case 7: 'merge-base unresolved' not found. Output: $OUTPUT"
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
