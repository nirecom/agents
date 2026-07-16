# IC-1467-1 through IC-1467-11: run-bulk-dispatch.sh and run-phase5-record.sh existence

BULK_SCRIPT="$AGENTS_DIR/skills/issue-create/scripts/run-bulk-dispatch.sh"
PHASE5_SCRIPT="$AGENTS_DIR/skills/issue-create/scripts/run-phase5-record.sh"

# ---------------------------------------------------------------------------
# IC-1467-1: skills/issue-create/scripts/run-bulk-dispatch.sh exists
# ---------------------------------------------------------------------------
if [ -f "$BULK_SCRIPT" ]; then
    pass "IC-1467-1: run-bulk-dispatch.sh exists"
else
    fail "IC-1467-1: run-bulk-dispatch.sh missing — RED until implementation"
fi

# ---------------------------------------------------------------------------
# IC-1467-2: skills/issue-create/scripts/run-bulk-dispatch.sh is executable
# ---------------------------------------------------------------------------
if [ -x "$BULK_SCRIPT" ]; then
    pass "IC-1467-2: run-bulk-dispatch.sh is executable"
else
    fail "IC-1467-2: run-bulk-dispatch.sh not executable — RED until implementation"
fi

# ---------------------------------------------------------------------------
# IC-1467-3: skills/issue-create/scripts/run-phase5-record.sh exists
# ---------------------------------------------------------------------------
if [ -f "$PHASE5_SCRIPT" ]; then
    pass "IC-1467-3: run-phase5-record.sh exists"
else
    fail "IC-1467-3: run-phase5-record.sh missing — RED until implementation"
fi

# ---------------------------------------------------------------------------
# IC-1467-4: skills/issue-create/scripts/run-phase5-record.sh is executable
# ---------------------------------------------------------------------------
if [ -x "$PHASE5_SCRIPT" ]; then
    pass "IC-1467-4: run-phase5-record.sh is executable"
else
    fail "IC-1467-4: run-phase5-record.sh not executable — RED until implementation"
fi

# ---------------------------------------------------------------------------
# IC-1467-5: SKILL.md delegates Phase 4 bulk-sub-of to run-bulk-dispatch.sh
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "IC-1467-5: SKILL.md missing"
elif grep -q "run-bulk-dispatch.sh" "$SKILL_MD"; then
    pass "IC-1467-5: SKILL.md delegates Phase 4 bulk-sub-of to run-bulk-dispatch.sh"
else
    fail "IC-1467-5: SKILL.md does not reference run-bulk-dispatch.sh — RED until implementation"
fi

# ---------------------------------------------------------------------------
# IC-1467-6: SKILL.md delegates Phase 5 record loop to run-phase5-record.sh
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "IC-1467-6: SKILL.md missing"
elif grep -q "run-phase5-record.sh" "$SKILL_MD"; then
    pass "IC-1467-6: SKILL.md delegates Phase 5 record loop to run-phase5-record.sh"
else
    fail "IC-1467-6: SKILL.md does not reference run-phase5-record.sh — RED until implementation"
fi

# ---------------------------------------------------------------------------
# IC-1467-7: run-phase5-record.sh contains worktree-notes-append.js reference
# ---------------------------------------------------------------------------
if [ ! -f "$PHASE5_SCRIPT" ]; then
    fail "IC-1467-7: run-phase5-record.sh missing — RED until implementation"
elif grep -q "worktree-notes-append.js" "$PHASE5_SCRIPT"; then
    pass "IC-1467-7: run-phase5-record.sh contains worktree-notes-append.js reference"
else
    fail "IC-1467-7: run-phase5-record.sh does not reference worktree-notes-append.js"
fi

# ---------------------------------------------------------------------------
# IC-1467-8: run-phase5-record.sh contains non-fatal behavior marker
# ---------------------------------------------------------------------------
if [ ! -f "$PHASE5_SCRIPT" ]; then
    fail "IC-1467-8: run-phase5-record.sh missing — RED until implementation"
elif grep -qiE "non.fatal|non fatal|nonfatal" "$PHASE5_SCRIPT"; then
    pass "IC-1467-8: run-phase5-record.sh contains non-fatal behavior marker"
else
    fail "IC-1467-8: run-phase5-record.sh does not contain non-fatal marker"
fi

# ---------------------------------------------------------------------------
# IC-1467-9: run-phase5-record.sh contains --skip-if-main flag
# ---------------------------------------------------------------------------
if [ ! -f "$PHASE5_SCRIPT" ]; then
    fail "IC-1467-9: run-phase5-record.sh missing — RED until implementation"
elif grep -q -- "--skip-if-main" "$PHASE5_SCRIPT"; then
    pass "IC-1467-9: run-phase5-record.sh contains --skip-if-main flag"
else
    fail "IC-1467-9: run-phase5-record.sh does not contain --skip-if-main"
fi

# ---------------------------------------------------------------------------
# IC-1467-10: run-bulk-dispatch.sh has set -euo pipefail
# ---------------------------------------------------------------------------
if [ ! -f "$BULK_SCRIPT" ]; then
    fail "IC-1467-10: run-bulk-dispatch.sh missing — RED until implementation"
elif grep -q "set -euo pipefail" "$BULK_SCRIPT"; then
    pass "IC-1467-10: run-bulk-dispatch.sh has set -euo pipefail"
else
    fail "IC-1467-10: run-bulk-dispatch.sh missing set -euo pipefail"
fi

# ---------------------------------------------------------------------------
# IC-1467-11: run-phase5-record.sh has set -euo pipefail
# ---------------------------------------------------------------------------
if [ ! -f "$PHASE5_SCRIPT" ]; then
    fail "IC-1467-11: run-phase5-record.sh missing — RED until implementation"
elif grep -q "set -euo pipefail" "$PHASE5_SCRIPT"; then
    pass "IC-1467-11: run-phase5-record.sh has set -euo pipefail"
else
    fail "IC-1467-11: run-phase5-record.sh missing set -euo pipefail"
fi
