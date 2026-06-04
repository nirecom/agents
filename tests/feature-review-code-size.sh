#!/bin/bash
# Tests: bin/review-code-size
# Tags: code-size, review, bin
# Tests for bin/review-code-size
# Verifies: SKIPPED/PERFORMED status labels, line-count WARN/HARD thresholds,
# 3-source union diff detection (committed/staged/unstaged/untracked),
# node_modules/_archived exclusions, --all mode, --base/--all mutual exclusion,
# filename-with-space handling, deleted file handling, exit 0 always.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-code-size"
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
# Case 1: SKIPPED — only README changed (no JS/SH/PY)
# ---------------------------------------------------------------------------
REPO1=$(make_repo)
git -C "$REPO1" checkout -q -b feature1
echo "updated readme" >> "$REPO1/README.md"
git -C "$REPO1" add README.md
git -C "$REPO1" commit -q -m "update readme"

EXIT_CODE=0
OUTPUT=$(cd "$REPO1" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 1: expected exit 0, got $EXIT_CODE"
else
    pass "Case 1: exits 0 when no code files changed"
fi

if echo "$OUTPUT" | grep -q "## Code-size Review: SKIPPED"; then
    pass "Case 1: output contains SKIPPED"
else
    fail "Case 1: SKIPPED not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 2: WARN — committed JS file with 350 lines
# ---------------------------------------------------------------------------
REPO2=$(make_repo)
git -C "$REPO2" checkout -q -b feature2
mkdir -p "$REPO2/bin"
make_lines 350 > "$REPO2/bin/foo.js"
git -C "$REPO2" add "$REPO2/bin/foo.js"
git -C "$REPO2" commit -q -m "add 350-line JS file"

EXIT_CODE=0
OUTPUT=$(cd "$REPO2" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 2: expected exit 0, got $EXIT_CODE"
else
    pass "Case 2: exits 0 for committed 350-line JS"
fi

if echo "$OUTPUT" | grep -q "## Code-size Review: PERFORMED"; then
    pass "Case 2: output contains PERFORMED"
else
    fail "Case 2: PERFORMED not found. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "WARN:"; then
    pass "Case 2: WARN present for 350-line file"
else
    fail "Case 2: WARN not found. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "exceeds 300-line warn threshold"; then
    pass "Case 2: warn threshold message present"
else
    fail "Case 2: warn threshold message missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 3: WARN — staged JS 350 lines (uncommitted, 3-source union)
# ---------------------------------------------------------------------------
REPO3=$(make_repo)
git -C "$REPO3" checkout -q -b feature3
mkdir -p "$REPO3/bin"
make_lines 350 > "$REPO3/bin/staged.js"
git -C "$REPO3" add "$REPO3/bin/staged.js"
# DO NOT commit — file is only staged

EXIT_CODE=0
OUTPUT=$(cd "$REPO3" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 3: expected exit 0, got $EXIT_CODE"
else
    pass "Case 3: exits 0 for staged 350-line JS"
fi

if echo "$OUTPUT" | grep -q "## Code-size Review: PERFORMED"; then
    pass "Case 3: PERFORMED for staged file"
else
    fail "Case 3: PERFORMED not found for staged file. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "WARN:"; then
    pass "Case 3: WARN present for staged 350-line file"
else
    fail "Case 3: WARN not found for staged file. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 4: WARN — unstaged modified SH 350 lines (3-source union)
# ---------------------------------------------------------------------------
REPO4=$(make_repo)
git -C "$REPO4" checkout -q -b feature4
mkdir -p "$REPO4/bin"
# Create and commit the file first (small)
echo "#!/bin/bash" > "$REPO4/bin/myscript.sh"
git -C "$REPO4" add "$REPO4/bin/myscript.sh"
git -C "$REPO4" commit -q -m "add small script"
# Now overwrite with 350 lines WITHOUT staging
make_lines 350 > "$REPO4/bin/myscript.sh"
# DO NOT git add — file is modified but unstaged

EXIT_CODE=0
OUTPUT=$(cd "$REPO4" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 4: expected exit 0, got $EXIT_CODE"
else
    pass "Case 4: exits 0 for unstaged modified SH"
fi

if echo "$OUTPUT" | grep -q "## Code-size Review: PERFORMED"; then
    pass "Case 4: PERFORMED for unstaged modified SH"
else
    fail "Case 4: PERFORMED not found for unstaged modified SH. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "WARN:"; then
    pass "Case 4: WARN present for unstaged 350-line SH"
else
    fail "Case 4: WARN not found for unstaged SH. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 5: WARN — untracked PY 350 lines (3-source union)
# ---------------------------------------------------------------------------
REPO5=$(make_repo)
git -C "$REPO5" checkout -q -b feature5
mkdir -p "$REPO5/bin"
# Create the file with NO git add
make_lines 350 > "$REPO5/bin/untracked.py"

EXIT_CODE=0
OUTPUT=$(cd "$REPO5" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 5: expected exit 0, got $EXIT_CODE"
else
    pass "Case 5: exits 0 for untracked PY"
fi

if echo "$OUTPUT" | grep -q "## Code-size Review: PERFORMED"; then
    pass "Case 5: PERFORMED for untracked PY"
else
    fail "Case 5: PERFORMED not found for untracked PY. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "WARN:"; then
    pass "Case 5: WARN present for untracked 350-line PY"
else
    fail "Case 5: WARN not found for untracked PY. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 6: HARD — committed JS 600 lines
# ---------------------------------------------------------------------------
REPO6=$(make_repo)
git -C "$REPO6" checkout -q -b feature6
mkdir -p "$REPO6/bin"
make_lines 600 > "$REPO6/bin/huge.js"
git -C "$REPO6" add "$REPO6/bin/huge.js"
git -C "$REPO6" commit -q -m "add 600-line JS file"

EXIT_CODE=0
OUTPUT=$(cd "$REPO6" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 1 ]]; then
    fail "Case 6: expected exit 1 (HARD block), got $EXIT_CODE"
else
    pass "Case 6: exits 1 for 600-line JS (HARD block)"
fi

if echo "$OUTPUT" | grep -q "## Code-size Review: PERFORMED"; then
    pass "Case 6: PERFORMED for 600-line JS"
else
    fail "Case 6: PERFORMED not found. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "HARD:"; then
    pass "Case 6: HARD present for 600-line file"
else
    fail "Case 6: HARD not found. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "exceeds 500-line hard limit"; then
    pass "Case 6: hard limit message present"
else
    fail "Case 6: hard limit message missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 7: Deleted file only — no wc -l error, SKIPPED or PERFORMED with no file listed
# (--diff-filter=ACMRT excludes D, so deleted files do not appear in targets)
# ---------------------------------------------------------------------------
REPO7=$(make_repo)
git -C "$REPO7" checkout -q -b feature7
mkdir -p "$REPO7/bin"
make_lines 350 > "$REPO7/bin/todelete.js"
git -C "$REPO7" add "$REPO7/bin/todelete.js"
git -C "$REPO7" commit -q -m "add JS file"
# Now delete it
git -C "$REPO7" rm -q "$REPO7/bin/todelete.js"
git -C "$REPO7" commit -q -m "delete JS file"

EXIT_CODE=0
OUTPUT=$(cd "$REPO7" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 7: expected exit 0, got $EXIT_CODE"
else
    pass "Case 7: exits 0 for deleted-file-only diff"
fi

if echo "$OUTPUT" | grep -q "^wc:"; then
    fail "Case 7: unexpected wc error for deleted file. Output: $OUTPUT"
else
    pass "Case 7: no wc error for deleted file"
fi

# Expect SKIPPED (no remaining targets after --diff-filter=ACMRT excludes D)
if echo "$OUTPUT" | grep -qE "SKIPPED|PERFORMED"; then
    pass "Case 7: output has valid status line"
else
    fail "Case 7: no valid status line. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 8: Filename with space — staged (IFS-safe)
# ---------------------------------------------------------------------------
REPO8=$(make_repo)
git -C "$REPO8" checkout -q -b feature8
mkdir -p "$REPO8/bin"
make_lines 350 > "$REPO8/bin/my tool.sh"
git -C "$REPO8" add "$REPO8/bin/my tool.sh"
# DO NOT commit

EXIT_CODE=0
OUTPUT=$(cd "$REPO8" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 8: expected exit 0, got $EXIT_CODE"
else
    pass "Case 8: exits 0 for filename with space"
fi

if echo "$OUTPUT" | grep -q "WARN:"; then
    pass "Case 8: WARN present for staged file with space in name"
else
    fail "Case 8: WARN not found for file with space. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 9: node_modules/ exclusion
# ---------------------------------------------------------------------------
REPO9=$(make_repo)
git -C "$REPO9" checkout -q -b feature9
mkdir -p "$REPO9/node_modules/foo"
make_lines 350 > "$REPO9/node_modules/foo/bar.js"
# Force-add since node_modules may be gitignored
git -C "$REPO9" add -f "$REPO9/node_modules/foo/bar.js"
git -C "$REPO9" commit -q -m "add node_modules JS (force)"

EXIT_CODE=0
OUTPUT=$(cd "$REPO9" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 9: expected exit 0, got $EXIT_CODE"
else
    pass "Case 9: exits 0 for node_modules file"
fi

if echo "$OUTPUT" | grep -q "SKIPPED"; then
    pass "Case 9: node_modules/ file excluded (SKIPPED)"
else
    fail "Case 9: node_modules/ file was not excluded. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 10: _archived/ exclusion
# ---------------------------------------------------------------------------
REPO10=$(make_repo)
git -C "$REPO10" checkout -q -b feature10
mkdir -p "$REPO10/skills/_archived"
make_lines 350 > "$REPO10/skills/_archived/old.sh"
git -C "$REPO10" add "$REPO10/skills/_archived/old.sh"
git -C "$REPO10" commit -q -m "add _archived SH file"

EXIT_CODE=0
OUTPUT=$(cd "$REPO10" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 10: expected exit 0, got $EXIT_CODE"
else
    pass "Case 10: exits 0 for _archived/ file"
fi

if echo "$OUTPUT" | grep -q "SKIPPED"; then
    pass "Case 10: _archived/ file excluded (SKIPPED)"
else
    fail "Case 10: _archived/ file was not excluded. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 11: Only .md/.json changed — SKIPPED
# ---------------------------------------------------------------------------
REPO11=$(make_repo)
git -C "$REPO11" checkout -q -b feature11
make_lines 350 > "$REPO11/docs.md"
git -C "$REPO11" add "$REPO11/docs.md"
git -C "$REPO11" commit -q -m "add large md file"

EXIT_CODE=0
OUTPUT=$(cd "$REPO11" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 11: expected exit 0, got $EXIT_CODE"
else
    pass "Case 11: exits 0 when only .md changed"
fi

if echo "$OUTPUT" | grep -q "SKIPPED"; then
    pass "Case 11: SKIPPED when only .md/.json changed"
else
    fail "Case 11: SKIPPED not found for .md-only change. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 12: --all mode
# ---------------------------------------------------------------------------
REPO12=$(make_repo)
git -C "$REPO12" checkout -q -b feature12
mkdir -p "$REPO12/lib"
make_lines 50 > "$REPO12/lib/helper.js"
git -C "$REPO12" add "$REPO12/lib/helper.js"
git -C "$REPO12" commit -q -m "add helper JS"

EXIT_CODE=0
OUTPUT=$(cd "$REPO12" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 12: expected exit 0, got $EXIT_CODE"
else
    pass "Case 12: exits 0 in --all mode"
fi

if echo "$OUTPUT" | grep -q "## Code-size Review: PERFORMED (all-scan mode)"; then
    pass "Case 12: PERFORMED (all-scan mode) found"
else
    fail "Case 12: PERFORMED (all-scan mode) not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 13: --base and --all mutually exclusive
# ---------------------------------------------------------------------------
REPO13=$(make_repo)

EXIT_CODE=0
OUTPUT=$(cd "$REPO13" && run_with_timeout bash "$SCRIPT" --base main --all 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 13: expected exit 0, got $EXIT_CODE"
else
    pass "Case 13: exits 0 for --base + --all conflict"
fi

if echo "$OUTPUT" | grep -q "SKIPPED"; then
    pass "Case 13: SKIPPED when --base and --all are both given"
else
    fail "Case 13: SKIPPED not found for --base+--all conflict. Output: $OUTPUT"
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
