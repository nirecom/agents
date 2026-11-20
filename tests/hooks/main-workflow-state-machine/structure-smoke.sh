# shellcheck shell=bash
# Case group: Section 6 — Structure Smoke.
# Sourced by main-workflow-state-machine.sh; relies on helpers from common.sh.

run_structure_smoke_tests() {
    # ---------------------------------------------------------------------------
    # Section 6: Structure Smoke
    # (Minimal — details in tests/feature-robust-workflow-settings.sh)
    # ---------------------------------------------------------------------------
    echo ""
    echo "=== Section 6: Structure Smoke ==="

    # L6-a: some PostToolUse entry matches Bash (its position in the list is not the contract)
    if node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
const ptu = (s.hooks && s.hooks.PostToolUse) || [];
process.exit(ptu.some(g => String(g.matcher || '').split('|').includes('Bash')) ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
        pass "L6-a. settings.json has a PostToolUse entry whose matcher includes Bash"
    else
        fail "L6-a. settings.json PostToolUse missing Bash matcher"
    fi

    # L6-b: permissions.ask contains reason-form USER_VERIFIED and does NOT contain bare
    # USER_VERIFIED (#404 contract change). RESET_FROM left permissions.ask in #2852: the
    # PreToolUse hook gate-reset-from-sentinel decides allow or ask by the reset allowance.
    L6B_OUT=$(node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
const ask = (s.permissions && s.permissions.ask) || [];
const reasonUV = ask.some(e => e.includes('WORKFLOW_USER_VERIFIED: *'));
const noBareUV = ask.every(e => e !== 'Bash(echo \"<<WORKFLOW_USER_VERIFIED>>\")');
const noRF = ask.every(e => !e.includes('WORKFLOW_RESET_FROM'));
const pre = (s.hooks && s.hooks.PreToolUse) || [];
const gateRF = pre.some(g => (g.hooks || []).some(h => String(h.command || '').includes('gate-reset-from-sentinel')));
if (!reasonUV) { console.log('MISSING reason-form WORKFLOW_USER_VERIFIED: *'); process.exit(1); }
if (!noBareUV) { console.log('BARE WORKFLOW_USER_VERIFIED still present in ask'); process.exit(1); }
if (!noRF) { console.log('WORKFLOW_RESET_FROM still present in ask'); process.exit(1); }
if (!gateRF) { console.log('MISSING PreToolUse gate-reset-from-sentinel'); process.exit(1); }
process.exit(0);
" -- "$SETTINGS" 2>&1) && L6B_OK=1 || L6B_OK=0
    if [ "$L6B_OK" = "1" ]; then
        pass "L6-b. permissions.ask: reason-form USER_VERIFIED present; bare USER_VERIFIED and RESET_FROM absent; PreToolUse gate-reset-from-sentinel registered"
    else
        fail "L6-b. permissions.ask contract violated: $L6B_OUT"
    fi

    # L6-c: the workflow state dir is protected by the placement guard of
    # block-clearance-token-write (a PreToolUse hook on Edit/Write), not by permissions.deny.
    local l6c_dir="$TMPDIR_BASE/l6c-state"
    mkdir -p "$l6c_dir"
    if node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
const pre = (s.hooks && s.hooks.PreToolUse) || [];
const m = (g) => String(g.matcher || '').split('|');
const hit = pre.some(g => m(g).includes('Edit') && m(g).includes('Write')
  && (g.hooks || []).some(h => String(h.command || '').includes('block-clearance-token-write.js')));
process.exit(hit ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null \
       && env -u CLAUDE_CODE_SESSION_ID WORKFLOW_STATE_DIR="$l6c_dir" node -e "
const path = require('path');
const { classifyPlacement } = require(path.join(process.argv[1], 'hooks/block-clearance-token-write/placement-guard.js'));
process.exit(classifyPlacement(path.join(process.argv[2], 'x.json'), {}) === 'control-dir' ? 0 : 1);
" -- "$DOTFILES_DIR" "$l6c_dir" 2>/dev/null; then
        pass "L6-c. workflow state dir is write-protected by block-clearance-token-write (placement-guard)"
    else
        fail "L6-c. workflow state dir is write-protected by block-clearance-token-write (placement-guard)"
    fi
}
