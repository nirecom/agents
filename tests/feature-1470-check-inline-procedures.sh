#!/bin/bash
# Tests: bin/check-inline-procedures, skills/review-code-security/scripts/run-quality-gates.sh
# Tags: prompt, bin, quality-gate, inline-procedure, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - bin/check-inline-procedures integrated into run-quality-gates.sh firing in a real WF-CODE-6 session
# - run-quality-gates.sh PATH resolution ($AGENTS_CONFIG_DIR/bin on PATH) confirmed live
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/check-inline-procedures"
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
    echo "SKIP: bin/check-inline-procedures not yet created (write-code step pending)"
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

# Helper: emit a block of N consecutive column-0 numbered lines
make_numbered() {
    local n="$1"
    local i
    for ((i = 1; i <= n; i++)); do
        echo "$i. step $i"
    done
}

# Helper: count how many WARN: lines are in the output
count_warns() {
    printf '%s\n' "$1" | grep -c "^WARN:" || true
}

# ---------------------------------------------------------------------------
# T1: committed detection — commit skills/foo/SKILL.md with 3 numbered lines
# ---------------------------------------------------------------------------
REPO1=$(make_repo)
git -C "$REPO1" checkout -q -b feature1
mkdir -p "$REPO1/skills/foo"
{ echo "# Foo skill"; echo ""; make_numbered 3; } > "$REPO1/skills/foo/SKILL.md"
git -C "$REPO1" add "$REPO1/skills/foo/SKILL.md"
git -C "$REPO1" commit -q -m "add SKILL.md with 3 numbered steps"

EXIT_CODE=0
OUTPUT=$(cd "$REPO1" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "T1: expected exit 0, got $EXIT_CODE"
else
    pass "T1: exits 0 for committed 3-step block"
fi

if echo "$OUTPUT" | grep -q "## Inline Procedure Review: PERFORMED"; then
    pass "T1: output contains PERFORMED"
else
    fail "T1: PERFORMED not found. Output: $OUTPUT"
fi

if [[ "$(count_warns "$OUTPUT")" -eq 1 ]]; then
    pass "T1: exactly 1 WARN hit"
else
    fail "T1: expected 1 WARN, got $(count_warns "$OUTPUT"). Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# T2: staged detection — git add only, no commit
# ---------------------------------------------------------------------------
REPO2=$(make_repo)
git -C "$REPO2" checkout -q -b feature2
mkdir -p "$REPO2/skills/foo"
{ echo "# Foo skill"; echo ""; make_numbered 3; } > "$REPO2/skills/foo/SKILL.md"
git -C "$REPO2" add "$REPO2/skills/foo/SKILL.md"

EXIT_CODE=0
OUTPUT=$(cd "$REPO2" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "T2: expected exit 0, got $EXIT_CODE"
else
    pass "T2: exits 0 for staged 3-step block"
fi

if echo "$OUTPUT" | grep -q "## Inline Procedure Review: PERFORMED"; then
    pass "T2: output contains PERFORMED"
else
    fail "T2: PERFORMED not found. Output: $OUTPUT"
fi

if [[ "$(count_warns "$OUTPUT")" -eq 1 ]]; then
    pass "T2: exactly 1 WARN hit"
else
    fail "T2: expected 1 WARN, got $(count_warns "$OUTPUT"). Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# T3: unstaged detection — edit committed file to add 3 numbered lines, no add
# ---------------------------------------------------------------------------
REPO3=$(make_repo)
git -C "$REPO3" checkout -q -b feature3
mkdir -p "$REPO3/skills/foo"
echo "# Foo skill (baseline, no procedure)" > "$REPO3/skills/foo/SKILL.md"
git -C "$REPO3" add "$REPO3/skills/foo/SKILL.md"
git -C "$REPO3" commit -q -m "add baseline SKILL.md"
# Now edit in place, do NOT stage.
{ echo "# Foo skill"; echo ""; make_numbered 3; } > "$REPO3/skills/foo/SKILL.md"

EXIT_CODE=0
OUTPUT=$(cd "$REPO3" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "T3: expected exit 0, got $EXIT_CODE"
else
    pass "T3: exits 0 for unstaged 3-step block"
fi

if echo "$OUTPUT" | grep -q "## Inline Procedure Review: PERFORMED"; then
    pass "T3: output contains PERFORMED"
else
    fail "T3: PERFORMED not found. Output: $OUTPUT"
fi

if [[ "$(count_warns "$OUTPUT")" -eq 1 ]]; then
    pass "T3: exactly 1 WARN hit"
else
    fail "T3: expected 1 WARN, got $(count_warns "$OUTPUT"). Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# T4: untracked detection — new skills/foo/SKILL.md with 3 numbered lines, no add
# ---------------------------------------------------------------------------
REPO4=$(make_repo)
git -C "$REPO4" checkout -q -b feature4
mkdir -p "$REPO4/skills/foo"
{ echo "# Foo skill"; echo ""; make_numbered 3; } > "$REPO4/skills/foo/SKILL.md"
# Do NOT stage — leave untracked.

EXIT_CODE=0
OUTPUT=$(cd "$REPO4" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "T4: expected exit 0, got $EXIT_CODE"
else
    pass "T4: exits 0 for untracked 3-step block"
fi

if echo "$OUTPUT" | grep -q "## Inline Procedure Review: PERFORMED"; then
    pass "T4: output contains PERFORMED"
else
    fail "T4: PERFORMED not found. Output: $OUTPUT"
fi

if [[ "$(count_warns "$OUTPUT")" -eq 1 ]]; then
    pass "T4: exactly 1 WARN hit"
else
    fail "T4: expected 1 WARN, got $(count_warns "$OUTPUT"). Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# T5: threshold under 3 (2 consecutive numbered lines) → no WARN
# ---------------------------------------------------------------------------
REPO5=$(make_repo)
git -C "$REPO5" checkout -q -b feature5
mkdir -p "$REPO5/skills/foo"
{ echo "# Foo skill"; echo ""; make_numbered 2; } > "$REPO5/skills/foo/SKILL.md"
git -C "$REPO5" add "$REPO5/skills/foo/SKILL.md"
git -C "$REPO5" commit -q -m "add SKILL.md with 2 numbered steps"

EXIT_CODE=0
OUTPUT=$(cd "$REPO5" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "T5: expected exit 0, got $EXIT_CODE"
else
    pass "T5: exits 0 for 2-step block"
fi

if [[ "$(count_warns "$OUTPUT")" -eq 0 ]]; then
    pass "T5: no WARN for 2 consecutive numbered lines"
else
    fail "T5: expected 0 WARN, got $(count_warns "$OUTPUT"). Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# T6: interrupted re-count (1./2./non-numbered/1./2.) → no WARN
# ---------------------------------------------------------------------------
REPO6=$(make_repo)
git -C "$REPO6" checkout -q -b feature6
mkdir -p "$REPO6/skills/foo"
{
    echo "# Foo skill"
    echo ""
    echo "1. first"
    echo "2. second"
    echo "some prose interrupts the run"
    echo "1. first again"
    echo "2. second again"
} > "$REPO6/skills/foo/SKILL.md"
git -C "$REPO6" add "$REPO6/skills/foo/SKILL.md"
git -C "$REPO6" commit -q -m "add SKILL.md with interrupted numbered runs"

EXIT_CODE=0
OUTPUT=$(cd "$REPO6" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "T6: expected exit 0, got $EXIT_CODE"
else
    pass "T6: exits 0 for interrupted numbered runs"
fi

if [[ "$(count_warns "$OUTPUT")" -eq 0 ]]; then
    pass "T6: no WARN when run resets on non-numbered line"
else
    fail "T6: expected 0 WARN, got $(count_warns "$OUTPUT"). Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# T7: _archived/ exclusion — untracked skills/_archived/old/SKILL.md
#     Path has 2 segments after skills/, so it must NOT match the scope regex.
# ---------------------------------------------------------------------------
REPO7=$(make_repo)
git -C "$REPO7" checkout -q -b feature7
mkdir -p "$REPO7/skills/_archived/old"
{ echo "# Archived skill"; echo ""; make_numbered 4; } > "$REPO7/skills/_archived/old/SKILL.md"
git -C "$REPO7" add "$REPO7/skills/_archived/old/SKILL.md"
git -C "$REPO7" commit -q -m "add archived SKILL.md with 4 numbered steps"

EXIT_CODE=0
OUTPUT=$(cd "$REPO7" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "T7: expected exit 0, got $EXIT_CODE"
else
    pass "T7: exits 0 for _archived/ file"
fi

if [[ "$(count_warns "$OUTPUT")" -eq 0 ]]; then
    pass "T7: _archived/ SKILL.md not scanned (no WARN)"
else
    fail "T7: _archived/ file was scanned. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "## Inline Procedure Review: SKIPPED"; then
    pass "T7: output contains SKIPPED (no in-scope prompt files)"
else
    fail "T7: SKIPPED not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# T8: nested depth filtered — skills/_shared/sub/deep.md (2 segments after _shared)
# ---------------------------------------------------------------------------
REPO8=$(make_repo)
git -C "$REPO8" checkout -q -b feature8
mkdir -p "$REPO8/skills/_shared/sub"
{ echo "# Deep shared"; echo ""; make_numbered 4; } > "$REPO8/skills/_shared/sub/deep.md"
git -C "$REPO8" add "$REPO8/skills/_shared/sub/deep.md"
git -C "$REPO8" commit -q -m "add nested skills/_shared/sub/deep.md with 4 numbered steps"

EXIT_CODE=0
OUTPUT=$(cd "$REPO8" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "T8: expected exit 0, got $EXIT_CODE"
else
    pass "T8: exits 0 for nested skills/_shared/sub/deep.md"
fi

if [[ "$(count_warns "$OUTPUT")" -eq 0 ]]; then
    pass "T8: nested-depth file out of scope (no WARN)"
else
    fail "T8: nested-depth file was scanned. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "## Inline Procedure Review: SKIPPED"; then
    pass "T8: output contains SKIPPED (nested file filtered out)"
else
    fail "T8: SKIPPED not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# T9: --all audit mode — agents/x.md with 3 numbered lines → WARN
# ---------------------------------------------------------------------------
REPO9=$(make_repo)
git -C "$REPO9" checkout -q -b feature9
mkdir -p "$REPO9/agents"
{ echo "# Agent x"; echo ""; make_numbered 3; } > "$REPO9/agents/x.md"
git -C "$REPO9" add "$REPO9/agents/x.md"
git -C "$REPO9" commit -q -m "add agents/x.md with 3 numbered steps"

EXIT_CODE=0
OUTPUT=$(cd "$REPO9" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "T9: expected exit 0, got $EXIT_CODE"
else
    pass "T9: exits 0 in --all audit mode"
fi

if echo "$OUTPUT" | grep -q "## Inline Procedure Review: PERFORMED (all-scan mode)"; then
    pass "T9: output contains PERFORMED (all-scan mode)"
else
    fail "T9: all-scan mode header not found. Output: $OUTPUT"
fi

if [[ "$(count_warns "$OUTPUT")" -ge 1 ]]; then
    pass "T9: WARN present for agents/x.md 3-step block"
else
    fail "T9: expected >=1 WARN, got $(count_warns "$OUTPUT"). Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# T10: --base/--all mutual exclusion → SKIPPED
# ---------------------------------------------------------------------------
REPO10=$(make_repo)
git -C "$REPO10" checkout -q -b feature10

EXIT_CODE=0
OUTPUT=$(cd "$REPO10" && run_with_timeout bash "$SCRIPT" --base main --all 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "T10: expected exit 0, got $EXIT_CODE"
else
    pass "T10: exits 0 when --base and --all both given"
fi

if echo "$OUTPUT" | grep -q "## Inline Procedure Review: SKIPPED"; then
    pass "T10: output contains SKIPPED for mutually-exclusive flags"
else
    fail "T10: SKIPPED not found. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -iq "mutually exclusive"; then
    pass "T10: output states 'mutually exclusive'"
else
    fail "T10: 'mutually exclusive' not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# T11: always exit 0 — even with WARNs, exit code must be 0
# ---------------------------------------------------------------------------
REPO11=$(make_repo)
git -C "$REPO11" checkout -q -b feature11
mkdir -p "$REPO11/skills/foo"
{ echo "# Foo skill"; echo ""; make_numbered 5; } > "$REPO11/skills/foo/SKILL.md"
git -C "$REPO11" add "$REPO11/skills/foo/SKILL.md"
git -C "$REPO11" commit -q -m "add SKILL.md with 5 numbered steps (WARN)"

EXIT_CODE=0
OUTPUT=$(cd "$REPO11" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "T11: exits 0 even when WARN fired"
else
    fail "T11: expected exit 0 with WARN present, got $EXIT_CODE. Output: $OUTPUT"
fi

if [[ "$(count_warns "$OUTPUT")" -ge 1 ]]; then
    pass "T11: WARN present (advisory, non-blocking)"
else
    fail "T11: expected >=1 WARN, got $(count_warns "$OUTPUT"). Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# T12: agents/*.md scope inclusion in diff mode (committed)
# ---------------------------------------------------------------------------
REPO12=$(make_repo)
git -C "$REPO12" checkout -q -b feature12
mkdir -p "$REPO12/agents"
{ echo "# Agent x"; echo ""; make_numbered 3; } > "$REPO12/agents/x.md"
git -C "$REPO12" add "$REPO12/agents/x.md"
git -C "$REPO12" commit -q -m "add agents/x.md with 3 numbered steps"

EXIT_CODE=0
OUTPUT=$(cd "$REPO12" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "T12: expected exit 0, got $EXIT_CODE"
else
    pass "T12: exits 0 for committed agents/*.md"
fi

if echo "$OUTPUT" | grep -q "## Inline Procedure Review: PERFORMED"; then
    pass "T12: agents/*.md picked up in diff mode (PERFORMED)"
else
    fail "T12: PERFORMED not found for agents/*.md. Output: $OUTPUT"
fi

if [[ "$(count_warns "$OUTPUT")" -eq 1 ]]; then
    pass "T12: exactly 1 WARN for agents/*.md 3-step block"
else
    fail "T12: expected 1 WARN, got $(count_warns "$OUTPUT"). Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# T13: skills/_shared/*.md scope inclusion in diff mode (committed)
# ---------------------------------------------------------------------------
REPO13=$(make_repo)
git -C "$REPO13" checkout -q -b feature13
mkdir -p "$REPO13/skills/_shared"
{ echo "# Shared doc"; echo ""; make_numbered 3; } > "$REPO13/skills/_shared/foo.md"
git -C "$REPO13" add "$REPO13/skills/_shared/foo.md"
git -C "$REPO13" commit -q -m "add skills/_shared/foo.md with 3 numbered steps"

EXIT_CODE=0
OUTPUT=$(cd "$REPO13" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "T13: expected exit 0, got $EXIT_CODE"
else
    pass "T13: exits 0 for committed skills/_shared/*.md"
fi

if echo "$OUTPUT" | grep -q "## Inline Procedure Review: PERFORMED"; then
    pass "T13: skills/_shared/*.md picked up in diff mode (PERFORMED)"
else
    fail "T13: PERFORMED not found for skills/_shared/*.md. Output: $OUTPUT"
fi

if [[ "$(count_warns "$OUTPUT")" -eq 1 ]]; then
    pass "T13: exactly 1 WARN for skills/_shared/*.md 3-step block"
else
    fail "T13: expected 1 WARN, got $(count_warns "$OUTPUT"). Output: $OUTPUT"
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
