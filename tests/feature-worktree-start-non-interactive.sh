#!/bin/bash
# Tests for issue #602 PR1 — skills/worktree-start/SKILL.md non-interactive mode.
#
# /worktree-start is a SKILL consumed by the LLM, not an executable CLI, so this
# is a STATIC CONTENT test: we assert the SKILL.md documents the contracts the
# refactor-prompts skill (and other callers) depend on.
#
#   TC1: SKILL.md documents --task-name argument handling.
#   TC2: SKILL.md documents --branch-type argument handling.
#   TC3: SKILL.md documents idempotency (reuse existing worktree when task-name
#        collides) — keyword search for "already exists" / "git worktree list".
#   TC4: SKILL.md documents arg validation / rejection on missing or invalid args.
#
# RED until PR1 lands.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="$AGENTS_DIR/skills/worktree-start/SKILL.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SKILL_MD" ]; then
    echo "FAIL: precondition missing — skills/worktree-start/SKILL.md"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# --- TC1: --task-name documented -------------------------------------------
if grep -q -- '--task-name' "$SKILL_MD"; then
    pass "TC1: --task-name documented"
else
    fail "TC1: --task-name not documented"
fi

# --- TC2: --branch-type documented -----------------------------------------
if grep -q -- '--branch-type' "$SKILL_MD"; then
    pass "TC2: --branch-type documented"
else
    fail "TC2: --branch-type not documented"
fi

# --- TC3: idempotency / reuse documented -----------------------------------
if grep -qiE 'already exists|git worktree list|idempoten|reuse' "$SKILL_MD"; then
    pass "TC3: idempotency / reuse-existing semantics documented"
else
    fail "TC3: idempotency keyword (already exists / git worktree list / idempotent / reuse) missing"
fi

# --- TC4: arg validation documented ----------------------------------------
if grep -qiE 'invalid|valid(ate|ation)|reject|exit 1|missing' "$SKILL_MD"; then
    pass "TC4: arg validation / error path documented"
else
    fail "TC4: validation/error-path keyword missing"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
