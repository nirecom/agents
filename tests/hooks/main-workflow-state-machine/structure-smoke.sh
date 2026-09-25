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

    # L6-a: PostToolUse hooks contains a Bash matcher
    if node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
const ptu = s.hooks && s.hooks.PostToolUse;
process.exit(ptu && ptu[0] && ptu[0].matcher === 'Bash' ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
        pass "L6-a. settings.json PostToolUse[0].matcher === 'Bash'"
    else
        fail "L6-a. settings.json PostToolUse missing Bash matcher"
    fi

    # L6-b: permissions.ask contains reason-form USER_VERIFIED, RESET_FROM,
    # and does NOT contain bare USER_VERIFIED (#404 contract change).
    L6B_OUT=$(node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
const ask = (s.permissions && s.permissions.ask) || [];
const reasonUV = ask.some(e => e.includes('WORKFLOW_USER_VERIFIED: *'));
const noBareUV = ask.every(e => e !== 'Bash(echo \"<<WORKFLOW_USER_VERIFIED>>\")');
const hasRF = ask.some(e => e.includes('WORKFLOW_RESET_FROM'));
if (!reasonUV) { console.log('MISSING reason-form WORKFLOW_USER_VERIFIED: *'); process.exit(1); }
if (!noBareUV) { console.log('BARE WORKFLOW_USER_VERIFIED still present in ask'); process.exit(1); }
if (!hasRF) { console.log('MISSING WORKFLOW_RESET_FROM'); process.exit(1); }
process.exit(0);
" -- "$SETTINGS" 2>&1) && L6B_OK=1 || L6B_OK=0
    if [ "$L6B_OK" = "1" ]; then
        pass "L6-b. permissions.ask: reason-form USER_VERIFIED + RESET_FROM present; bare USER_VERIFIED absent"
    else
        fail "L6-b. permissions.ask contract violated: $L6B_OUT"
    fi

    # L6-c: permissions.deny contains ~/.claude/projects/workflow path
    if node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
const deny = (s.permissions && s.permissions.deny) || [];
process.exit(deny.some(e => e.includes('.claude/projects/workflow')) ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
        pass "L6-c. permissions.deny contains .claude/projects/workflow path"
    else
        fail "L6-c. permissions.deny missing .claude/projects/workflow path"
    fi
}
