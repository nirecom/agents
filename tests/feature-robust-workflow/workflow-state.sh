# ---------------------------------------------------------------------------
# === workflow-state.js: Unit-level checks via node -e ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-state: Unit checks ==="

# WS-UNIT-1: CLAUDE_WORKFLOW_DIR env override → used as workflow dir
# Compare inside Node.js so both sides agree on path format (Git Bash converts /tmp/... to C:/... on Windows).
WS_UNIT1_DIR="$TMPDIR_BASE/custom-workflow-$$"
WS_UNIT1_RESULT=$(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WS_UNIT1_DIR" node -e "
const wf = require('$WS_REL');
console.log(wf.getWorkflowDir() === process.env.CLAUDE_WORKFLOW_DIR ? 'ok' : wf.getWorkflowDir());
" 2>/dev/null || echo "ERROR")
if [ "$WS_UNIT1_RESULT" = "ok" ]; then
    pass "WS-UNIT-1. CLAUDE_WORKFLOW_DIR override is respected"
else
    fail "WS-UNIT-1. CLAUDE_WORKFLOW_DIR override not respected: $WS_UNIT1_RESULT"
fi

# WS-UNIT-2: CLAUDE_WORKFLOW_DIR unset → uses os.homedir()/.claude/projects/workflow
WS_FAKEHOME="$TMPDIR_BASE/fakehome"
WS_UNIT2_RESULT=$(cd "$DOTFILES_DIR" && HOME="$WS_FAKEHOME" USERPROFILE="$WS_FAKEHOME" node -e "
process.env.CLAUDE_WORKFLOW_DIR = '';
delete process.env.CLAUDE_WORKFLOW_DIR;
const wf = require('$WS_REL');
const os = require('os');
const path = require('path');
const expected = path.join(os.homedir(), '.claude', 'projects', 'workflow');
console.log(wf.getWorkflowDir() === expected ? 'ok' : wf.getWorkflowDir());
" 2>/dev/null || echo "ERROR")
if [ "$WS_UNIT2_RESULT" = "ok" ]; then
    pass "WS-UNIT-2. CLAUDE_WORKFLOW_DIR unset → os.homedir() path used"
else
    fail "WS-UNIT-2. expected homedir path, got: $WS_UNIT2_RESULT"
fi

# WS-UNIT-3: writeState creates workflow dir if missing
WS_UNIT3_DIR="$TMPDIR_BASE/ws-unit3-$$"
WS_UNIT3_RESULT=$(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WS_UNIT3_DIR" node -e "
const wf = require('$WS_REL');
const state = wf.createInitialState('test-sid-unit3');
try {
  wf.writeState('test-sid-unit3', state);
  const fs = require('fs');
  const path = require('path');
  console.log(fs.existsSync(path.join(wf.getWorkflowDir(), 'test-sid-unit3.json')) ? 'ok' : 'missing');
} catch(e) { console.log('ERROR: ' + e.message); }
" 2>/dev/null || echo "ERROR")
if [ "$WS_UNIT3_RESULT" = "ok" ]; then
    pass "WS-UNIT-3. writeState creates workflow dir if missing"
else
    fail "WS-UNIT-3. writeState dir creation: $WS_UNIT3_RESULT"
fi

# WS-UNIT-4: readState with nonexistent session → returns null (no throw)
WS_UNIT4_RESULT=$(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node -e "
const wf = require('$WS_REL');
const result = wf.readState('nonexistent-session-xyz');
console.log(result === null ? 'ok' : JSON.stringify(result));
" 2>/dev/null || echo "ERROR")
if [ "$WS_UNIT4_RESULT" = "ok" ]; then
    pass "WS-UNIT-4. readState nonexistent session → null (no throw)"
else
    fail "WS-UNIT-4. readState nonexistent: $WS_UNIT4_RESULT"
fi

# WS-UNIT-5: cleanupZombies does not crash when workflow dir does not exist
WS_UNIT5_DIR="$TMPDIR_BASE/ws-unit5-nonexistent-$$"
WS_UNIT5_EXIT=0
(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WS_UNIT5_DIR" node -e "
const wf = require('$WS_REL');
wf.cleanupZombies(7);
" 2>/dev/null) || WS_UNIT5_EXIT=$?
if [ "$WS_UNIT5_EXIT" = "0" ]; then
    pass "WS-UNIT-5. cleanupZombies on nonexistent dir → no crash"
else
    fail "WS-UNIT-5. cleanupZombies crashed: exit $WS_UNIT5_EXIT"
fi

# WS-UNIT-6: cleanupZombies removes stale .tmp files (mtimed in the past)
WS_UNIT6_DIR="$TMPDIR_BASE/ws-unit6-$$"
mkdir -p "$WS_UNIT6_DIR"
TMP_FILE="$WS_UNIT6_DIR/stale.json.tmp"
touch "$TMP_FILE"
# Backdate mtime by 2 days (172800 seconds)
touch -d "2 days ago" "$TMP_FILE" 2>/dev/null || touch -t "$(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M 2>/dev/null || echo '202601010000')" "$TMP_FILE" 2>/dev/null || true
(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WS_UNIT6_DIR" node -e "
const wf = require('$WS_REL');
wf.cleanupZombies(7);
" 2>/dev/null) || true
if [ ! -f "$TMP_FILE" ]; then
    pass "WS-UNIT-6. cleanupZombies removes stale .tmp files"
else
    # touch -d might not work on macOS — check if mtime was actually set
    MTIME_DIFF=$(node -e "const s=require('fs').statSync('$TMP_FILE');console.log(Date.now()-s.mtimeMs)" 2>/dev/null || echo "0")
    if [ "${MTIME_DIFF:-0}" -lt "86400000" ]; then
        echo "SKIP: WS-UNIT-6. touch -d not supported on this platform, skipping mtime test"
    else
        fail "WS-UNIT-6. stale .tmp file was not removed"
    fi
fi

# WS-IDEM-1: markStep called twice → idempotent result
WS_IDEM1_DIR="$TMPDIR_BASE/ws-idem1-$$"
WS_IDEM1_RESULT=$(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WS_IDEM1_DIR" node -e "
const wf = require('$WS_REL');
wf.markStep('idem-sid', 'research', 'complete');
wf.markStep('idem-sid', 'research', 'complete');
const state = wf.readState('idem-sid');
console.log(state && state.steps.research.status === 'complete' ? 'ok' : JSON.stringify(state));
" 2>/dev/null || echo "ERROR")
if [ "$WS_IDEM1_RESULT" = "ok" ]; then
    pass "WS-IDEM-1. markStep twice → idempotent"
else
    fail "WS-IDEM-1. idempotent markStep: $WS_IDEM1_RESULT"
fi
