#!/usr/bin/env bash
# tests/fix-774-worktree-auto-backup.sh
# Tests: skills/worktree-end/SKILL.md
# Tags: worktree-end, backup, auto-backup, ux
#
# Static analysis tests for fix/774: auto-backup UX simplification.
# Verifies that Step WE-8 in SKILL.md no longer asks the user to choose
# "Back up / discard / abort" (auto-backup now runs unconditionally for
# non-zero-file cases) and that the skill retains required machinery
# (dry_run / execute pass structure, error-handling, summary reporting).
#
# T01–T02 FAIL until SKILL.md is updated (expected before implementation).
# T03–T07 PASS from the start (spec elements already present).
# T08     PASS from the start (backup/inventory scripts exist).

if [ -z "$_TIMEOUT_WRAPPED" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="$REPO_ROOT/skills/worktree-end/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Helper: extract the Step WE-8 section from SKILL.md.
# Returns lines from "### Step WE-8" up to (but not including) "### Step WE-9".
# ---------------------------------------------------------------------------
extract_step_we8() {
    awk '/^### Step WE-8/{flag=1; next} /^### Step WE-9/{flag=0} flag' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# T01 — Step WE-8 must NOT contain a "discard or abort" AskUserQuestion
#
# Before fix: Pass 1 ends with:
#   AskUserQuestion "Back up ..., discard, or abort?"
# After fix: auto-backup runs without asking; AskUserQuestion is gone from WE-8.
#
# NOTE: Step WE-10 also has AskUserQuestion — we scope to WE-8 only.
# We exclude lines whose ONLY mention of abort/discard is in the context of
# a non-backup error handler (e.g. "surface summary ... and stop").
# Specifically we look for a line that has BOTH:
#   - "AskUserQuestion" (or ask_user_question / AskUser)
#   - AND ("discard" OR "abort")
# within the WE-8 block.
# ---------------------------------------------------------------------------
echo "=== T01: Step WE-8 has NO 'discard or abort' AskUserQuestion ==="
if [ ! -f "$SKILL_MD" ]; then
    fail "T01: SKILL.md not found at $SKILL_MD"
else
    section="$(extract_step_we8)"
    # Check for a line combining AskUserQuestion with 'discard' or 'abort'
    if echo "$section" | grep -qiE 'AskUserQuestion.*\b(discard|abort)\b|\b(discard|abort)\b.*AskUserQuestion'; then
        fail "T01: Step WE-8 still contains 'discard or abort' AskUserQuestion (fix not yet applied)"
    else
        pass "T01: Step WE-8 has no 'discard or abort' AskUserQuestion"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# T02 — SKILL.md must NOT contain "only when user chose"
#
# Before fix: Pass 2 is gated with "only when user chose 'back up'".
# After fix: Pass 2 runs automatically (no user-choice gate).
# ---------------------------------------------------------------------------
echo "=== T02: SKILL.md has no 'only when user chose' gate ==="
if [ ! -f "$SKILL_MD" ]; then
    fail "T02: SKILL.md not found at $SKILL_MD"
else
    if grep -qF 'only when user chose' "$SKILL_MD"; then
        fail "T02: SKILL.md still contains 'only when user chose' (fix not yet applied)"
    else
        pass "T02: SKILL.md has no 'only when user chose' gate"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# T03 — Step WE-8 must contain BACKUP_MANIFEST_PATH=(none)
#
# The zero-files case sets BACKUP_MANIFEST_PATH=(none).
# This sentinel must remain in the WE-8 section after the fix.
# ---------------------------------------------------------------------------
echo "=== T03: Step WE-8 contains BACKUP_MANIFEST_PATH=(none) ==="
if [ ! -f "$SKILL_MD" ]; then
    fail "T03: SKILL.md not found at $SKILL_MD"
else
    section="$(extract_step_we8)"
    if echo "$section" | grep -qF 'BACKUP_MANIFEST_PATH=(none)'; then
        pass "T03: Step WE-8 contains 'BACKUP_MANIFEST_PATH=(none)'"
    else
        fail "T03: Step WE-8 missing 'BACKUP_MANIFEST_PATH=(none)'"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# T04 — SKILL.md contains mode: "dry_run"
#
# Pass 1 (dry-run inventory) must still be present.
# ---------------------------------------------------------------------------
echo "=== T04: SKILL.md contains mode: \"dry_run\" ==="
if [ ! -f "$SKILL_MD" ]; then
    fail "T04: SKILL.md not found at $SKILL_MD"
else
    if grep -qF 'mode: "dry_run"' "$SKILL_MD"; then
        pass "T04: SKILL.md contains 'mode: \"dry_run\"'"
    else
        fail "T04: SKILL.md missing 'mode: \"dry_run\"'"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# T05 — SKILL.md contains mode: "execute"
#
# Pass 2 (execute backup) must still be present.
# ---------------------------------------------------------------------------
echo "=== T05: SKILL.md contains mode: \"execute\" ==="
if [ ! -f "$SKILL_MD" ]; then
    fail "T05: SKILL.md not found at $SKILL_MD"
else
    if grep -qF 'mode: "execute"' "$SKILL_MD"; then
        pass "T05: SKILL.md contains 'mode: \"execute\"'"
    else
        fail "T05: SKILL.md missing 'mode: \"execute\"'"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# T06 — Step WE-8 contains status: failed error handling
#
# Both passes must handle status: failed — surface summary + artifact_path and stop.
# ---------------------------------------------------------------------------
echo "=== T06: Step WE-8 contains status: failed error handling ==="
if [ ! -f "$SKILL_MD" ]; then
    fail "T06: SKILL.md not found at $SKILL_MD"
else
    section="$(extract_step_we8)"
    if echo "$section" | grep -qF 'status: failed'; then
        pass "T06: Step WE-8 contains 'status: failed' error handling"
    else
        fail "T06: Step WE-8 missing 'status: failed' error handling"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# T07 — Step WE-8 contains summary: reference for orchestrator output
#
# The orchestrator-facing "summary:" line must appear in WE-8 so the caller
# can surface context to the user on failure or completion.
# ---------------------------------------------------------------------------
echo "=== T07: Step WE-8 contains summary: reference ==="
if [ ! -f "$SKILL_MD" ]; then
    fail "T07: SKILL.md not found at $SKILL_MD"
else
    section="$(extract_step_we8)"
    if echo "$section" | grep -qF 'summary:'; then
        pass "T07: Step WE-8 contains 'summary:' reference"
    else
        fail "T07: Step WE-8 missing 'summary:' reference"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# T08 — worktree-end scripts directory and capture-env.sh exist
#
# Verifies that the backup/inventory infrastructure files are present.
# This test should PASS before any implementation changes.
# ---------------------------------------------------------------------------
echo "=== T08: worktree-end scripts and capture-env.sh exist ==="
SCRIPTS_DIR="$REPO_ROOT/skills/worktree-end/scripts"
CAPTURE_ENV="$SCRIPTS_DIR/capture-env.sh"

any_fail=0
if [ ! -d "$SCRIPTS_DIR" ]; then
    fail "T08: skills/worktree-end/scripts/ directory not found"
    any_fail=1
fi
if [ ! -f "$CAPTURE_ENV" ]; then
    fail "T08: skills/worktree-end/scripts/capture-env.sh not found"
    any_fail=1
fi
if [ "$any_fail" -eq 0 ]; then
    pass "T08: worktree-end/scripts/ and capture-env.sh exist"
fi
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
