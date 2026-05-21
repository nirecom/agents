#!/bin/bash
# Structural smoke tests for claude-global/settings.json workflow entries.
# Covers: permissions.ask/allow/deny guards and PostToolUse Bash matcher.
# Removed: hook count/order tests (fragile), old-path-absent tests (stable).
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$DOTFILES_DIR/settings.json"
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
# SR6: bare WORKFLOW_USER_VERIFIED absent from ask (#404)
# ---------------------------------------------------------------------------
echo ""
echo "=== settings.json: SR6 — bare WORKFLOW_USER_VERIFIED absent from ask ==="

if node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const ask=s.permissions&&s.permissions.ask||[];
process.exit(ask.every(e => e !== 'Bash(echo \"<<WORKFLOW_USER_VERIFIED>>\")') ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
    pass "SR6. bare WORKFLOW_USER_VERIFIED absent from permissions.ask"
else
    fail "SR6. bare WORKFLOW_USER_VERIFIED still present in permissions.ask"
fi

# ---------------------------------------------------------------------------
# SR7: reason-form WORKFLOW_USER_VERIFIED: * present in ask
# ---------------------------------------------------------------------------
echo ""
echo "=== settings.json: SR7 — reason-form WORKFLOW_USER_VERIFIED: * present in ask ==="

if node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const ask=s.permissions&&s.permissions.ask||[];
process.exit(ask.some(e => e === 'Bash(echo \"<<WORKFLOW_USER_VERIFIED: *>>\")') ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
    pass "SR7. reason-form WORKFLOW_USER_VERIFIED: * present in permissions.ask"
else
    fail "SR7. reason-form WORKFLOW_USER_VERIFIED: * NOT in permissions.ask"
fi

# ---------------------------------------------------------------------------
# SR8: bare _NOT_NEEDED absent / reason forms present (4 sentinels)
# ---------------------------------------------------------------------------
echo ""
echo "=== settings.json: SR8 — _NOT_NEEDED: bare absent + reason form present ==="

SR8_OUT=$(node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const ask=s.permissions&&s.permissions.ask||[];
const names=['WORKFLOW_CLARIFY_INTENT_NOT_NEEDED','WORKFLOW_PLAN_NOT_NEEDED','WORKFLOW_WRITE_TESTS_NOT_NEEDED','WORKFLOW_REVIEW_SECURITY_NOT_NEEDED'];
for (const n of names) {
  const bare='Bash(echo \"<<'+n+'>>\")';
  const reason='Bash(echo \"<<'+n+': *>>\")';
  if (!ask.every(e => e !== bare)) { console.log('BARE PRESENT: '+n); process.exit(1); }
  if (!ask.some(e => e === reason)) { console.log('REASON MISSING: '+n); process.exit(1); }
}
process.exit(0);
" -- "$SETTINGS" 2>&1) && SR8_OK=1 || SR8_OK=0
if [ "$SR8_OK" = "1" ]; then
    pass "SR8. _NOT_NEEDED sentinels: bare absent + reason form present (all 4)"
else
    fail "SR8. _NOT_NEEDED contract violated: $SR8_OUT"
fi

# ---------------------------------------------------------------------------
# SR9: bare ENFORCE_WORKTREE_OFF absent / reason-form present in ask
# ---------------------------------------------------------------------------
echo ""
echo "=== settings.json: SR9 — ENFORCE_WORKTREE_OFF: bare absent + reason in ask ==="

SR9_OUT=$(node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const ask=s.permissions&&s.permissions.ask||[];
const bare='Bash(echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF>>\")';
const reason='Bash(echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: *>>\")';
if (!ask.every(e => e !== bare)) { console.log('BARE PRESENT in ask'); process.exit(1); }
if (!ask.some(e => e === reason)) { console.log('REASON MISSING in ask'); process.exit(1); }
process.exit(0);
" -- "$SETTINGS" 2>&1) && SR9_OK=1 || SR9_OK=0
if [ "$SR9_OK" = "1" ]; then
    pass "SR9. ENFORCE_WORKTREE_OFF: bare absent + reason form present in ask"
else
    fail "SR9. ENFORCE_WORKTREE_OFF contract violated: $SR9_OUT"
fi

# ---------------------------------------------------------------------------
# SR10: reason ENFORCE_WORKTREE_ON in allow + ON absent from ask (#404)
# ---------------------------------------------------------------------------
echo ""
echo "=== settings.json: SR10 — ENFORCE_WORKTREE_ON: reason in allow + absent from ask ==="

SR10_OUT=$(node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const ask=s.permissions&&s.permissions.ask||[];
const allow=s.permissions&&s.permissions.allow||[];
const reason='Bash(echo \"<<WORKFLOW_ENFORCE_WORKTREE_ON: *>>\")';
if (!allow.some(e => e === reason)) { console.log('REASON ON MISSING in allow'); process.exit(1); }
if (ask.some(e => e.includes('WORKFLOW_ENFORCE_WORKTREE_ON'))) { console.log('ON still present in ask'); process.exit(1); }
process.exit(0);
" -- "$SETTINGS" 2>&1) && SR10_OK=1 || SR10_OK=0
if [ "$SR10_OK" = "1" ]; then
    pass "SR10. ENFORCE_WORKTREE_ON: reason in allow + absent from ask"
else
    fail "SR10. ENFORCE_WORKTREE_ON contract violated: $SR10_OUT"
fi

# ---------------------------------------------------------------------------
# SR11: bare ENFORCE_WORKTREE_ON absent from allow
# ---------------------------------------------------------------------------
echo ""
echo "=== settings.json: SR11 — bare ENFORCE_WORKTREE_ON absent from allow ==="

if node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const allow=s.permissions&&s.permissions.allow||[];
process.exit(allow.every(e => e !== 'Bash(echo \"<<WORKFLOW_ENFORCE_WORKTREE_ON>>\")') ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
    pass "SR11. bare WORKFLOW_ENFORCE_WORKTREE_ON absent from permissions.allow"
else
    fail "SR11. bare WORKFLOW_ENFORCE_WORKTREE_ON still present in permissions.allow"
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
