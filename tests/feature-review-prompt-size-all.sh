#!/bin/bash
# Tests: bin/review-prompt-size, skills/_archived/., skills/_archived/old, skills/_archived/old/SKILL.md, skills/big, skills/big/SKILL.md, skills/small, skills/small/SKILL.md, rules/coding/test, agents/foo, skills/_shared/bar, rules/test
# Tags: skill, bin, tests, prompt
# Tests for bin/review-prompt-size --all mode.
#
# TC1: --all scans ALL existing skills/*/SKILL.md (not the diff); a 150-line
#      pre-existing SKILL.md is reported.
# TC2: bare invocation (no --all) unchanged — empty diff → SKIPPED.
# TC3: --base AND --all → SKIPPED with mutually-exclusive reason.
# TC4: --all excludes skills/_archived/.
# TC5: --all scans rules/*.md.
# TC6: --all scans agents/*.md.
# TC7: --all scans skills/_shared/*.md.
# TC8: --all with 201-line rules/*.md still exits 0 (audit-only contract).

set -u

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-prompt-size"
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
    echo "SKIP: bin/review-prompt-size not yet created (write-code step pending)"
    echo ""
    echo "Results: 0 passed, 0 failed (skipped)"
    exit 0
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

if echo "$OUT" | grep -q "## Prompt Size Review: SKIPPED"; then
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

# ---------------------------------------------------------------------------
# TC5: --all scans rules/*.md
# ---------------------------------------------------------------------------
REPO5=$(make_repo)
mkdir -p "$REPO5/rules/coding"
make_lines 150 > "$REPO5/rules/coding/test.md"
git -C "$REPO5" add rules/
git -C "$REPO5" commit -q -m "add pre-existing 150-line rules file"
git -C "$REPO5" checkout -q -b feature5

EXIT=0
OUT=$(cd "$REPO5" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT=$?

if [ "$EXIT" -eq 0 ]; then
    pass "TC5: --all scanning rules/*.md exits 0"
else
    fail "TC5: --all exit=$EXIT output=$OUT"
fi

if echo "$OUT" | grep -q "PERFORMED"; then
    pass "TC5: --all PERFORMED for rules/*.md"
else
    fail "TC5: PERFORMED not found. Output: $OUT"
fi

if echo "$OUT" | grep -q "exceeds 100-line safety net"; then
    pass "TC5: --all flags pre-existing 150-line rules/*.md"
else
    fail "TC5: 150-line warning missing for rules/*.md. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# TC6: --all scans agents/*.md
# ---------------------------------------------------------------------------
REPO6=$(make_repo)
mkdir -p "$REPO6/agents"
make_lines 150 > "$REPO6/agents/foo.md"
git -C "$REPO6" add agents/
git -C "$REPO6" commit -q -m "add pre-existing 150-line agents file"
git -C "$REPO6" checkout -q -b feature6

EXIT=0
OUT=$(cd "$REPO6" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT=$?

if [ "$EXIT" -eq 0 ]; then
    pass "TC6: --all scanning agents/*.md exits 0"
else
    fail "TC6: --all exit=$EXIT output=$OUT"
fi

if echo "$OUT" | grep -q "PERFORMED"; then
    pass "TC6: --all PERFORMED for agents/*.md"
else
    fail "TC6: PERFORMED not found. Output: $OUT"
fi

if echo "$OUT" | grep -q "exceeds 100-line safety net"; then
    pass "TC6: --all flags pre-existing 150-line agents/*.md"
else
    fail "TC6: 150-line warning missing for agents/*.md. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# TC7: --all scans skills/_shared/*.md
# ---------------------------------------------------------------------------
REPO7=$(make_repo)
mkdir -p "$REPO7/skills/_shared"
make_lines 150 > "$REPO7/skills/_shared/bar.md"
git -C "$REPO7" add skills/
git -C "$REPO7" commit -q -m "add pre-existing 150-line skills/_shared file"
git -C "$REPO7" checkout -q -b feature7

EXIT=0
OUT=$(cd "$REPO7" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT=$?

if [ "$EXIT" -eq 0 ]; then
    pass "TC7: --all scanning skills/_shared/*.md exits 0"
else
    fail "TC7: --all exit=$EXIT output=$OUT"
fi

if echo "$OUT" | grep -q "PERFORMED"; then
    pass "TC7: --all PERFORMED for skills/_shared/*.md"
else
    fail "TC7: PERFORMED not found. Output: $OUT"
fi

if echo "$OUT" | grep -q "exceeds 100-line safety net"; then
    pass "TC7: --all flags pre-existing 150-line skills/_shared/*.md"
else
    fail "TC7: 150-line warning missing for skills/_shared/*.md. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# TC8: --all with 201-line rules/*.md still exits 0 (audit-only contract)
# ---------------------------------------------------------------------------
REPO8=$(make_repo)
mkdir -p "$REPO8/rules"
make_lines 201 > "$REPO8/rules/test.md"
git -C "$REPO8" add rules/
git -C "$REPO8" commit -q -m "add pre-existing 201-line rules file"

EXIT=0
OUT=$(cd "$REPO8" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT=$?

if [ "$EXIT" -eq 0 ]; then
    pass "TC8: --all exits 0 for 201-line rules/*.md (audit-only, never blocks)"
else
    fail "TC8: expected exit 0 (--all never blocks), got $EXIT. Output: $OUT"
fi

if echo "$OUT" | grep -q "exceeds 200-line hard limit"; then
    pass "TC8: --all reports 'exceeds 200-line hard limit' for 201-line rules/*.md"
else
    fail "TC8: 'exceeds 200-line hard limit' not found. Output: $OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
