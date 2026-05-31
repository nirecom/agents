#!/bin/bash
# Tests: bin/review-skill-size, skills/_archived/., skills/_archived/old, skills/_archived/old/SKILL.md, skills/big, skills/big/SKILL.md, skills/small, skills/small/SKILL.md
# Tags: review-skill-size-all
# Tests for issue #602 PR1 — bin/review-skill-size --all mode.
#
# TC1: --all scans ALL existing skills/*/SKILL.md (not the diff); a 150-line
#      pre-existing SKILL.md is reported.
# TC2: bare invocation (no --all) unchanged — empty diff → SKIPPED.
# TC3: --base AND --all → SKIPPED with mutually-exclusive reason.
# TC4: --all excludes skills/_archived/.
#
# RED until PR1 lands.

set -u

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-skill-size"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# --- Existence gate ---------------------------------------------------------
if [ ! -f "$SCRIPT" ]; then
    echo "FAIL: precondition missing — bin/review-skill-size"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

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

make_lines() {
    local n="$1"
    local i
    for ((i = 1; i <= n; i++)); do
        echo "line $i"
    done
}

# ---------------------------------------------------------------------------
# TC1: --all scans ALL existing SKILL.md (pre-existing 150-line file reported)
# ---------------------------------------------------------------------------
REPO1=$(make_repo)
mkdir -p "$REPO1/skills/small" "$REPO1/skills/big"
make_lines 50  > "$REPO1/skills/small/SKILL.md"
make_lines 150 > "$REPO1/skills/big/SKILL.md"
git -C "$REPO1" add skills/
git -C "$REPO1" commit -q -m "add pre-existing skills"
git -C "$REPO1" checkout -q -b feature1
# Modify nothing — diff against main is empty.

EXIT=0
OUT=$(cd "$REPO1" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT=$?

if [ "$EXIT" -eq 0 ]; then
    pass "TC1: --all exits 0"
else
    fail "TC1: --all exit=$EXIT output=$OUT"
fi

if echo "$OUT" | grep -q "PERFORMED"; then
    pass "TC1: --all PERFORMED (not SKIPPED) despite empty diff"
else
    fail "TC1: PERFORMED not found. Output: $OUT"
fi

if echo "$OUT" | grep -q "exceeds 100-line safety net"; then
    pass "TC1: --all flags pre-existing 150-line SKILL.md"
else
    fail "TC1: 150-line warning missing. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# TC2: bare invocation (no --all) — empty diff → SKIPPED (regression)
# ---------------------------------------------------------------------------
REPO2=$(make_repo)
mkdir -p "$REPO2/skills/big"
make_lines 150 > "$REPO2/skills/big/SKILL.md"
git -C "$REPO2" add skills/
git -C "$REPO2" commit -q -m "add pre-existing 150-line skill"
git -C "$REPO2" checkout -q -b feature2

EXIT=0
OUT=$(cd "$REPO2" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT=$?

if [ "$EXIT" -eq 0 ]; then
    pass "TC2: bare mode exits 0"
else
    fail "TC2: bare mode exit=$EXIT output=$OUT"
fi

if echo "$OUT" | grep -q "## Skill Size Review: SKIPPED"; then
    pass "TC2: bare mode SKIPPED on empty diff (unchanged behavior)"
else
    fail "TC2: expected SKIPPED, got: $OUT"
fi

# ---------------------------------------------------------------------------
# TC3: --base AND --all → SKIPPED with mutually-exclusive reason
# ---------------------------------------------------------------------------
REPO3=$(make_repo)
git -C "$REPO3" checkout -q -b feature3

EXIT=0
OUT=$(cd "$REPO3" && run_with_timeout bash "$SCRIPT" --base main --all 2>&1) || EXIT=$?

if [ "$EXIT" -eq 0 ]; then
    pass "TC3: --base + --all exits 0"
else
    fail "TC3: --base + --all exit=$EXIT output=$OUT"
fi

if echo "$OUT" | grep -q "SKIPPED"; then
    pass "TC3: --base + --all → SKIPPED"
else
    fail "TC3: expected SKIPPED. Output: $OUT"
fi

if echo "$OUT" | grep -iqE "mutually exclusive|cannot.*combine|conflict"; then
    pass "TC3: --base + --all SKIPPED reason mentions mutual exclusion"
else
    fail "TC3: mutual-exclusion reason missing. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# TC4: --all excludes _archived/
# ---------------------------------------------------------------------------
REPO4=$(make_repo)
mkdir -p "$REPO4/skills/_archived/old"
make_lines 150 > "$REPO4/skills/_archived/old/SKILL.md"
git -C "$REPO4" add skills/
git -C "$REPO4" commit -q -m "add archived 150-line skill"
git -C "$REPO4" checkout -q -b feature4

EXIT=0
OUT=$(cd "$REPO4" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT=$?

if [ "$EXIT" -eq 0 ]; then
    pass "TC4: --all w/ only archived exits 0"
else
    fail "TC4: --all exit=$EXIT output=$OUT"
fi

if echo "$OUT" | grep -q "exceeds 100-line safety net"; then
    fail "TC4: _archived/ SKILL.md was NOT excluded. Output: $OUT"
else
    pass "TC4: _archived/ excluded under --all"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
