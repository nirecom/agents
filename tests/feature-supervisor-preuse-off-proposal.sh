#!/usr/bin/env bash
# tests/feature-supervisor-preuse-off-proposal.sh
# Tests: hooks/supervisor-off-proposal-shim.js
# Tags: supervisor, em-supervisor, pretooluse, off-proposal, shim, scope:issue-specific, pwsh-not-required, hook-registration
# L3 gap (what this test does NOT catch):
# - The shim firing as a real PreToolUse hook inside a live claude -p session
#   (settings.json PreToolUse registration — only verified via live session)
# - Real sentinel command forms from an actual Claude Code session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# SKIPPED: Mutation probe for shim OFF-sentinel regex patterns (C10)
# Because: supervisor-off-proposal-shim.js not yet implemented; once landed,
#   run: bash bin/mutation-probe.sh hooks/supervisor-off-proposal-shim.js
# L3 gap: mutation score >= 80% on OFF-sentinel regex constants

# T4: Two subcases against the NEW shim hooks/supervisor-off-proposal-shim.js
# (a) state has a blocking finding whose reporter !== "enforce-worktree"
#     + an OFF-sentinel Bash command on stdin → assert exit 2 AND decision:"block"
# (b) ALL blocking findings have reporter === "enforce-worktree"
#     + OFF cmd → assert exit 0 (false-block recovery pass-through)
# Security structure: negative assertion checks the protected outcome directly.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SHIM="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsr4'; }

if [ ! -f "$SHIM" ]; then
    fail "T4: supervisor-off-proposal-shim.js not present (RED-EXPECTED — Change 5 not yet implemented)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# OFF sentinel command that should trigger the shim
OFF_CMD='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: test reason>>"'

# --- T4a: blocking finding from non-enforce-worktree reporter → block ---
run_t4a() {
    local tmp sid out rc
    tmp=$(make_tmp)
    sid="t4a-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    # Seed state: layer1 finding with reporter="workflow-gate" (not enforce-worktree)
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
// blocking finding (severity=warning, not notice) from non-enforce-worktree reporter
st.layer1.findings = [{
    categories: ['workflow'],
    severity: 'warning',
    detail: 'blocking finding from workflow-gate',
    reporter: 'workflow-gate',
    timestamp: new Date().toISOString()
}];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    local hook_input
    hook_input=$(node -e "
process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    session_id: '$sid',
    tool_input: { command: $(node -e "process.stdout.write(JSON.stringify('$OFF_CMD'))") }
}));
")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    # Security: assert the block decision is present in stdout (not just exit code)
    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T4a: shim must emit decision:block when non-enforce-worktree blocking finding present"
        return
    fi
    if [ $rc -ne 2 ]; then
        fail "T4a: shim must exit 2 when blocking (non-enforce-worktree reporter), got rc=$rc"
        return
    fi
    pass "T4a: non-enforce-worktree blocking finding + OFF cmd → exit 2 + decision:block"
}

# --- T4b: all blocking findings from enforce-worktree → exit 0 (false-block recovery) ---
run_t4b() {
    local tmp sid out rc
    tmp=$(make_tmp)
    sid="t4b-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    # All blocking findings have reporter="enforce-worktree"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.layer1.findings = [{
    categories: ['workflow'],
    severity: 'warning',
    detail: 'enforce-worktree false block',
    reporter: 'enforce-worktree',
    timestamp: new Date().toISOString()
}];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    local hook_input
    hook_input=$(node -e "
process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    session_id: '$sid',
    tool_input: { command: $(node -e "process.stdout.write(JSON.stringify('$OFF_CMD'))") }
}));
")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    # Security: assert NOT blocked (false-block recovery pass-through)
    if echo "$out" | grep -q '"decision":"block"'; then
        fail "T4b: shim must NOT block when all blocking findings are from enforce-worktree (false-block recovery)"
        return
    fi
    if [ $rc -ne 0 ]; then
        fail "T4b: false-block recovery must exit 0, got rc=$rc"
        return
    fi
    pass "T4b: all enforce-worktree blocking findings + OFF cmd → exit 0 (false-block recovery)"
}

# --- T4c: non-OFF command → exit 0 (shim passes through non-sentinel commands) ---
run_t4c() {
    local tmp sid out rc
    tmp=$(make_tmp)
    sid="t4c-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    # State with blocking finding — but command is NOT an OFF sentinel
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.layer1.findings = [{
    categories: ['code'],
    severity: 'error',
    detail: 'severe finding',
    reporter: 'workflow-gate',
    timestamp: new Date().toISOString()
}];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"git status"}}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    if [ $rc -ne 0 ]; then
        fail "T4c: non-OFF command must pass through (exit 0), got rc=$rc"
        return
    fi
    if echo "$out" | grep -q '"decision":"block"'; then
        fail "T4c: non-OFF command must NOT be blocked by shim"
        return
    fi
    pass "T4c: non-OFF command → shim passes through (exit 0)"
}

run_t4a
run_t4b
run_t4c

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
