#!/bin/bash
# Tests: skills/refactor-prompts/SKILL.md
# Tags: worktree, start, prompts, refactor, skill, static, TL2, scope:common
# Tests for skills/refactor-prompts/SKILL.md content fixes (issue #602 PR1, extended by #1910).
#
# Asserts static SKILL.md content:
#   TC1: NO `/tmp/rp-scan.json` redirect (Windows-unsafe pattern).
#   TC2: USES `SCAN_JSON=$(...)` variable-capture form.
#   TC3: worktree-start invocation no longer passes `--task-name` (#1910 removed the flag).
#   TC4: worktree-start invocation no longer passes `--branch-type`.
#   TC5: worktree-start is invoked as `/worktree-start --headless refactor-prompts`.
#   TC6: the /worktree-start line contains no `$(` — slash-command args are not
#        shell-expanded, so the old `$(date +%Y%m%d)` form was a latent bug.
#
# TC3-TC6 are RED until the #1910 implementation lands (fail-before-fix).

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

# --- TC3: --task-name flag removed from worktree-start invocation ----------
if grep -qE '/worktree-start.*--task-name' "$SKILL_MD"; then
    fail "TC3: /worktree-start still passes --task-name (flag was removed in #1910)"
else
    pass "TC3: /worktree-start does not pass --task-name"
fi

# --- TC4: --branch-type flag removed from worktree-start invocation --------
if grep -qE '/worktree-start.*--branch-type' "$SKILL_MD"; then
    fail "TC4: /worktree-start still passes --branch-type (flag was removed in #1910)"
else
    pass "TC4: /worktree-start does not pass --branch-type"
fi

# --- TC5: headless invocation form -----------------------------------------
if grep -qF '/worktree-start --headless refactor-prompts' "$SKILL_MD"; then
    pass "TC5: /worktree-start --headless refactor-prompts present"
else
    fail "TC5: /worktree-start --headless refactor-prompts not found"
fi

# --- TC6: no shell substitution on the slash-command line ------------------
# Slash-command arguments are passed verbatim to the skill, never through a shell,
# so a `$(...)` in the argument list is a latent bug rather than a date.
if grep -E '/worktree-start' "$SKILL_MD" | grep -qF '$('; then
    fail "TC6: the /worktree-start line contains a \$( shell substitution"
else
    pass "TC6: the /worktree-start line contains no shell substitution"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
