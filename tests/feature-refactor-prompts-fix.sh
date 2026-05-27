#!/bin/bash
# Tests for issue #602 PR1 — skills/refactor-prompts/SKILL.md content fixes.
#
# Asserts static SKILL.md content:
#   TC1: NO `/tmp/rp-scan.json` redirect (Windows-unsafe pattern; the current bug).
#   TC2: USES `SCAN_JSON=$(...)` variable-capture form.
#   TC3: worktree-start invocation includes `--task-name` (non-interactive).
#   TC4: worktree-start invocation includes `--branch-type`.
#
# RED until PR1 lands (the SKILL.md is still in the old form today).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="$AGENTS_DIR/skills/refactor-prompts/SKILL.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Existence gate ---------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    echo "FAIL: precondition missing — skills/refactor-prompts/SKILL.md"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# --- TC1: no /tmp/rp-scan.json redirect -------------------------------------
if grep -qE '/tmp/rp-scan\.json' "$SKILL_MD"; then
    fail "TC1: /tmp/rp-scan.json redirect still present (Windows-unsafe)"
else
    pass "TC1: no /tmp/rp-scan.json redirect"
fi

# --- TC2: SCAN_JSON=$( variable capture form -------------------------------
if grep -qE 'SCAN_JSON=\$\(' "$SKILL_MD"; then
    pass "TC2: SCAN_JSON=\$(...) capture form present"
else
    fail "TC2: SCAN_JSON=\$(...) capture form missing"
fi

# --- TC3: --task-name flag in worktree-start invocation --------------------
if grep -qE '/worktree-start[^\n]*--task-name' "$SKILL_MD"; then
    pass "TC3: /worktree-start --task-name present"
else
    fail "TC3: /worktree-start --task-name not found"
fi

# --- TC4: --branch-type flag in worktree-start invocation ------------------
if grep -qE '/worktree-start.*--branch-type' "$SKILL_MD"; then
    pass "TC4: /worktree-start --branch-type present"
else
    fail "TC4: /worktree-start --branch-type not found"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
