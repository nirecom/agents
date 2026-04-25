#!/bin/bash
# Structural smoke tests for claude-global/settings.json workflow entries.
# Covers: permissions.ask/allow/deny guards and PostToolUse Bash matcher.
# Removed: hook count/order tests (fragile), old-path-absent tests (stable).
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$DOTFILES_DIR/claude-global/settings.json"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

if [ ! -f "$SETTINGS" ]; then
    echo "FATAL: settings.json not found at $SETTINGS"
    exit 2
fi

# ---------------------------------------------------------------------------
# SR1: permissions.ask contains WORKFLOW_USER_VERIFIED
# ---------------------------------------------------------------------------
echo ""
echo "=== settings.json: SR1 — ask contains WORKFLOW_USER_VERIFIED ==="

if node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const ask=s.permissions&&s.permissions.ask||[];
process.exit(ask.some(e=>e.includes('WORKFLOW_USER_VERIFIED')) ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
    pass "SR1. permissions.ask contains WORKFLOW_USER_VERIFIED entry"
else
    fail "SR1. permissions.ask does NOT contain WORKFLOW_USER_VERIFIED entry"
fi

# ---------------------------------------------------------------------------
# SR2: permissions.ask contains WORKFLOW_RESET_FROM (underscore format)
# ---------------------------------------------------------------------------
echo ""
echo "=== settings.json: SR2 — ask contains WORKFLOW_RESET_FROM_ ==="

if node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const ask=s.permissions&&s.permissions.ask||[];
process.exit(ask.some(e => e.includes('WORKFLOW_RESET_FROM_') && e.includes('>>')) ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
    pass "SR2. permissions.ask contains WORKFLOW_RESET_FROM_ (underscore format) entry"
else
    fail "SR2. permissions.ask does NOT contain WORKFLOW_RESET_FROM_ entry"
fi

# ---------------------------------------------------------------------------
# SR3: permissions.allow contains WORKFLOW_MARK_STEP (underscore format)
# ---------------------------------------------------------------------------
echo ""
echo "=== settings.json: SR3 — allow contains WORKFLOW_MARK_STEP ==="

if node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const allow=s.permissions&&s.permissions.allow||[];
process.exit(allow.some(e => e.includes('WORKFLOW_MARK_STEP')) ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
    pass "SR3. permissions.allow contains WORKFLOW_MARK_STEP entry"
else
    fail "SR3. permissions.allow does NOT contain WORKFLOW_MARK_STEP entry"
fi

# ---------------------------------------------------------------------------
# SR4: permissions.deny contains ~/.claude/projects/workflow path
# ---------------------------------------------------------------------------
echo ""
echo "=== settings.json: SR4 — deny contains .claude/projects/workflow ==="

if node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const deny=s.permissions&&s.permissions.deny||[];
process.exit(deny.some(e => e.includes('.claude/projects/workflow')) ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
    pass "SR4. permissions.deny contains .claude/projects/workflow entry"
else
    fail "SR4. permissions.deny does NOT contain .claude/projects/workflow entry"
fi

# ---------------------------------------------------------------------------
# SR5: permissions.ask contains WORKFLOW_REVIEW_SECURITY_NOT_NEEDED
# ---------------------------------------------------------------------------
echo ""
echo "=== settings.json: SR5 — ask contains WORKFLOW_REVIEW_SECURITY_NOT_NEEDED ==="

if node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const ask = s.permissions && s.permissions.ask || [];
process.exit(ask.some(e => e.includes('WORKFLOW_REVIEW_SECURITY_NOT_NEEDED')) ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
    pass "SR5. permissions.ask contains WORKFLOW_REVIEW_SECURITY_NOT_NEEDED entry"
else
    fail "SR5. permissions.ask does NOT contain WORKFLOW_REVIEW_SECURITY_NOT_NEEDED entry"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
