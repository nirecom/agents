#!/usr/bin/env bash
# tests/feature-supervisor-settings-registration.sh
# Tests: settings.json PreToolUse hook registration for supervisor-off-proposal-shim.js
# Tags: supervisor, em-supervisor, settings-registration, scope:issue-specific, hook-registration, pwsh-not-required
# L3 gap (what this test does NOT catch):
# - The shim actually firing in a live Claude Code session (requires real claude -p)
# - settings.json being read by the Claude Code process at session startup
# - matcher string correctly routing PreToolUse events at runtime
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# C3 [HIGH]: Static check that settings.json registers supervisor-off-proposal-shim.js
# in hooks.PreToolUse with matcher === "Bash|runInTerminal|runCommands".
# RED-EXPECTED until /write-code adds the entry.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

SETTINGS="$AGENTS_DIR/settings.json"
SETTINGS_NODE="$_AGENTS_DIR_NODE/settings.json"
SHIM="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsr_sreg'; }

if [ ! -f "$SETTINGS" ]; then
    skip "C3: settings.json not found at $SETTINGS"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

if ! command -v node >/dev/null 2>&1; then
    skip "C3: node not available"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- C3: Parse settings.json and assert shim registration ---
run_c3() {
    local result
    result=$(node -e "
const fs = require('fs');
const path = require('path');

const settingsPath = $(node -e "process.stdout.write(JSON.stringify('$SETTINGS_NODE'))");
let settings;
try {
    settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
} catch (e) {
    console.log('PARSE_ERROR:' + e.message);
    process.exit(0);
}

const hooks = settings && settings.hooks;
if (!hooks) {
    console.log('NO_HOOKS_KEY');
    process.exit(0);
}

const preToolUse = hooks.PreToolUse;
if (!Array.isArray(preToolUse)) {
    console.log('NO_PRETOOLUSE_ARRAY');
    process.exit(0);
}

// Look for an entry with matcher === 'Bash|runInTerminal|runCommands'
// AND hook command containing 'supervisor-off-proposal-shim.js'
const TARGET_MATCHER = 'Bash|runInTerminal|runCommands';
const TARGET_SHIM = 'supervisor-off-proposal-shim.js';

let found = false;
for (const entry of preToolUse) {
    if (!entry || entry.matcher !== TARGET_MATCHER) continue;
    if (!Array.isArray(entry.hooks)) continue;
    for (const h of entry.hooks) {
        if (h && typeof h.command === 'string' && h.command.includes(TARGET_SHIM)) {
            found = true;
            break;
        }
    }
    if (found) break;
}

if (found) {
    console.log('FOUND');
} else {
    // List what matchers with shim-like content exist for diagnostics
    const shimEntries = preToolUse.filter(e => {
        if (!e || !Array.isArray(e.hooks)) return false;
        return e.hooks.some(h => h && typeof h.command === 'string' && h.command.includes(TARGET_SHIM));
    });
    if (shimEntries.length > 0) {
        console.log('WRONG_MATCHER:' + shimEntries.map(e => e.matcher).join(','));
    } else {
        console.log('NOT_REGISTERED');
    }
}
" 2>/dev/null)

    case "$result" in
        FOUND)
            pass "C3: settings.json PreToolUse has supervisor-off-proposal-shim.js with matcher 'Bash|runInTerminal|runCommands'"
            ;;
        NOT_REGISTERED)
            fail "C3: supervisor-off-proposal-shim.js not registered in settings.json PreToolUse (RED-EXPECTED — Change 5 not yet applied)"
            ;;
        WRONG_MATCHER:*)
            fail "C3: shim found but under wrong matcher: ${result#WRONG_MATCHER:} (expected 'Bash|runInTerminal|runCommands')"
            ;;
        PARSE_ERROR:*)
            fail "C3: settings.json parse error: ${result#PARSE_ERROR:}"
            ;;
        NO_HOOKS_KEY)
            fail "C3: settings.json has no 'hooks' key (RED-EXPECTED — Change 5 not yet applied)"
            ;;
        NO_PRETOOLUSE_ARRAY)
            fail "C3: hooks.PreToolUse is absent or not an array (RED-EXPECTED — Change 5 not yet applied)"
            ;;
        "")
            fail "C3: node script produced no output (internal error)"
            ;;
        *)
            fail "C3: unexpected result from parser: $result"
            ;;
    esac
}

run_c3

# T7-smoke: invoke the registered PreToolUse hook command against a real Bash OFF-sentinel event
# and verify the hook fires (not just that its path appears in settings.json). L2 bridge test.
# L3 gap: real Claude Code host PreToolUse invocation via claude -p — covered by
#   WORKFLOW_USER_VERIFIED preflight (check-verification-gate.sh category: hook-registration).
run_t7_smoke() {
    if [ ! -f "$SETTINGS" ]; then
        fail "T7-smoke: settings.json not found"; return
    fi
    if [ ! -f "$SHIM" ]; then
        fail "T7-smoke: supervisor-off-proposal-shim.js absent (RED-EXPECTED — Change 5 not yet applied)"; return
    fi

    local hook_cmd
    hook_cmd=$(run_with_timeout 5 node -e "
try {
    const s=JSON.parse(require('fs').readFileSync('$SETTINGS_NODE','utf8'));
    const groups=(s&&s.hooks&&s.hooks.PreToolUse)||[];
    let cmd='';
    for(const g of groups){
        if(!g||!Array.isArray(g.hooks))continue;
        for(const h of g.hooks){
            if(h&&typeof h.command==='string'&&h.command.includes('supervisor-off-proposal-shim')){cmd=h.command;break;}
        }
        if(cmd)break;
    }
    process.stdout.write(cmd);
} catch(e) { process.stdout.write(''); }
" 2>/dev/null)

    if [ -z "$hook_cmd" ]; then
        fail "T7-smoke: supervisor-off-proposal-shim.js not found in PreToolUse hooks (RED-EXPECTED — Change 5 not registered)"
        return
    fi

    local tmp tmp_node hook_input out rc
    tmp=$(make_tmp)
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi
    hook_input=$(node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'t7s-$$',tool_input:{command:'echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: smoke>>\"'}}))" 2>/dev/null)

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        run_with_timeout 10 bash -c "$hook_cmd" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"

    if echo "$out" | grep -q '"decision":"block"' || [ $rc -eq 2 ]; then
        pass "T7-smoke: registered PreToolUse hook command fires and blocks OFF sentinel Bash event"
    else
        fail "T7-smoke: registered hook command did not block OFF sentinel (rc=$rc, out=$(printf '%q' "${out:0:60}"))"
    fi
}
run_t7_smoke

# C4: verify that the registered command resolves to an accessible script (file exists on disk).
# Uses the correct entry.hooks[i].command extraction path to get the shim command, then
# checks that the shim file path referenced by the command actually exists.
run_c4() {
    if [ ! -f "$SETTINGS" ]; then
        skip "C4: settings.json not found"; return
    fi
    if ! command -v node >/dev/null 2>&1; then
        skip "C4: node not available"; return
    fi

    local hook_cmd
    hook_cmd=$(run_with_timeout 5 node -e "
try {
    const s = JSON.parse(require('fs').readFileSync('$SETTINGS_NODE', 'utf8'));
    const groups = (s && s.hooks && s.hooks.PreToolUse) || [];
    let cmd = '';
    for (const entry of groups) {
        if (!entry || !Array.isArray(entry.hooks)) continue;
        for (const h of entry.hooks) {
            if (h && typeof h.command === 'string' && h.command.includes('supervisor-off-proposal-shim')) {
                cmd = h.command;
                break;
            }
        }
        if (cmd) break;
    }
    process.stdout.write(cmd);
} catch(e) { process.stdout.write(''); }
" 2>/dev/null)

    if [ -z "$hook_cmd" ]; then
        fail "C4: supervisor-off-proposal-shim.js not found via entry.hooks[i].command (incorrect extraction path or not registered)"
        return
    fi

    # The command must reference supervisor-off-proposal-shim.js and the file must exist
    if [ ! -f "$SHIM" ]; then
        fail "C4: command registered ($hook_cmd) but supervisor-off-proposal-shim.js file does not exist at $SHIM"
        return
    fi

    pass "C4: settings.json PreToolUse entry.hooks[i].command references supervisor-off-proposal-shim.js (file exists)"
}
run_c4

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
