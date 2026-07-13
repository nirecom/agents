#!/usr/bin/env bash
# tests/feature-1145-shim-adaptive.sh
# Tests: hooks/supervisor-off-proposal-shim.js, hooks/lib/worktree-end-env-anchor.js
# Tags: supervisor, em-supervisor, pretooluse, off-proposal, shim, we15, adaptive-message, scope:issue-specific, pwsh-not-required, hook-registration
# L2 integration tests for the adaptive OFF-block message added AFTER write-code.
# When computeIsWtEnd() (via isWorktreeEndEnv) returns true, the block reason switches
# to the WE-15/WE-16 adaptive text (mentions /sweep-worktrees and WE-20); otherwise the
# fixed "Active supervisor findings exist" text is kept.
# RED-EXPECTED: shim not yet modified + worktree-end-env-anchor.js not yet implemented.
#
# L3 gap (what this test does NOT catch):
# - The shim firing as a real PreToolUse hook inside a live claude -p session
#   (settings.json PreToolUse registration — only verified via live session).
# - Real sentinel command forms and real wsid resolution from an actual worktree-end run.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SHIM="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"
ANCHOR="$AGENTS_DIR/hooks/lib/worktree-end-env-anchor.js"
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

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'shimadapt'; }

tmp_node_for() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

if [ ! -f "$SHIM" ] || [ ! -f "$ANCHOR" ]; then
    fail "T4e-i: shim or worktree-end-env-anchor.js not present (RED-EXPECTED — WE-15 adaptive not yet implemented)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

WORKTREE_OFF_CMD='echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: test reason>>"'

# Seed a blocking L1 finding (severity=warning, reporter=workflow-gate) under $1=sid, plans-dir $2.
seed_blocking_finding() {
    local sid="$1" plansdir="$2"
    WORKFLOW_PLANS_DIR="$plansdir" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.layer1.findings = [{
    categories: ['workflow'],
    severity: 'warning',
    detail: 'blocking finding from workflow-gate',
    reporter: 'workflow-gate',
    timestamp: new Date().toISOString()
}];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

# Build hook_input JSON with a given session_id and the WORKTREE_OFF command.
build_hook_input() {
    local sid="$1"
    node -e "
process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    session_id: '$sid',
    tool_input: { command: $(node -e "process.stdout.write(JSON.stringify('$WORKTREE_OFF_CMD'))") }
}));
"
}

# --- T4e: worktree-end env present + blocking finding → adaptive block text ---
run_t4e() {
    local tmp tmp_node sid hook_input out rc
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="t4e-sid-$$"
    seed_blocking_finding "$sid" "$tmp_node"
    printf '%s' '{"WORKTREE_PATH":"/some/path","MERGE_SHA":"abc123"}' > "$tmp/${sid}-final-report-env.json"
    hook_input=$(build_hook_input "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"

    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T4e: must emit decision:block (findings path, worktree-end env)"; return; fi
    if [ $rc -ne 2 ]; then fail "T4e: must exit 2, got rc=$rc"; return; fi
    if ! echo "$out" | grep -q '/sweep-worktrees'; then
        fail "T4e: adaptive text must mention /sweep-worktrees"; return; fi
    if ! echo "$out" | grep -q 'WE-20'; then
        fail "T4e: adaptive text must mention WE-20"; return; fi
    pass "T4e: worktree-end env + blocking finding → exit 2 + adaptive (/sweep-worktrees + WE-20)"
}

# --- T4f: session-close schema (WORKTREE_PATH="") → fixed text (no adaptive) ---
run_t4f() {
    local tmp tmp_node sid hook_input out rc
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="t4f-sid-$$"
    seed_blocking_finding "$sid" "$tmp_node"
    printf '%s' '{"WORKTREE_PATH":"","OTHER_FIELD":"x"}' > "$tmp/${sid}-final-report-env.json"
    hook_input=$(build_hook_input "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"

    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T4f: must emit decision:block (findings path)"; return; fi
    if [ $rc -ne 2 ]; then fail "T4f: must exit 2, got rc=$rc"; return; fi
    if echo "$out" | grep -q '/sweep-worktrees'; then
        fail "T4f: session-close schema must NOT use adaptive text (found /sweep-worktrees)"; return; fi
    pass "T4f: session-close schema (WORKTREE_PATH=\"\") → exit 2 + fixed text (no /sweep-worktrees)"
}

# --- T4g: corrupt env JSON → fail-open to fixed text (no adaptive) ---
run_t4g() {
    local tmp tmp_node sid hook_input out rc
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="t4g-sid-$$"
    seed_blocking_finding "$sid" "$tmp_node"
    printf '%s' '"not valid json{' > "$tmp/${sid}-final-report-env.json"
    hook_input=$(build_hook_input "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"

    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T4g: must emit decision:block (findings path)"; return; fi
    if [ $rc -ne 2 ]; then fail "T4g: must exit 2, got rc=$rc"; return; fi
    if echo "$out" | grep -q '/sweep-worktrees'; then
        fail "T4g: corrupt env JSON must fail-open to fixed text (found /sweep-worktrees)"; return; fi
    pass "T4g: corrupt env JSON → exit 2 + fixed text (fail-open, no /sweep-worktrees)"
}

# --- T4h: ENOENT path (no state file) + worktree-end env → adaptive block text ---
run_t4h() {
    local tmp tmp_node sid hook_input out rc
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="t4h-sid-$$"
    # NO state file seeded → ENOENT block path. Genuine WORKTREE_OFF emit.
    printf '%s' '{"WORKTREE_PATH":"/some/path","MERGE_SHA":"abc123"}' > "$tmp/${sid}-final-report-env.json"
    hook_input=$(build_hook_input "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"

    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T4h: ENOENT genuine emit must emit decision:block"; return; fi
    if [ $rc -ne 2 ]; then fail "T4h: must exit 2, got rc=$rc"; return; fi
    if ! echo "$out" | grep -q '/sweep-worktrees'; then
        fail "T4h: ENOENT site adaptive text must mention /sweep-worktrees"; return; fi
    if ! echo "$out" | grep -q 'WE-20'; then
        fail "T4h: ENOENT site adaptive text must mention WE-20"; return; fi
    pass "T4h: ENOENT + worktree-end env → exit 2 + adaptive (/sweep-worktrees + WE-20)"
}

# --- T4i: ccSid != wsid; env file named by wsid; adaptive resolves via wsid fallback ---
run_t4i() {
    local tmp tmp_node ccSid wsid hook_input out rc
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    ccSid="t4i-cc-$$"
    wsid="20260713-000000-t4i-$$"

    # Blocking finding seeded under the CC session id (primary read path).
    seed_blocking_finding "$ccSid" "$tmp_node"

    # env file is named by the WORKFLOW session id (wsid), NOT the CC session id.
    printf '%s' '{"WORKTREE_PATH":"/some/path","MERGE_SHA":"abc123"}' > "$tmp/${wsid}-final-report-env.json"

    # Priority 2 wsid resolution: CLAUDE_CODE_SESSION_ID=wsid + <wsid>-context.md artifact.
    printf '%s' 'context' > "$tmp/${wsid}-context.md"

    hook_input=$(build_hook_input "$ccSid")

    # Run from a non-git-repo dir so Priority 1 (WORKTREE_NOTES.md) does not interfere.
    out=$( cd "$tmp" && WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        CLAUDE_CODE_SESSION_ID="$wsid" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>/dev/null )
    rc=$?
    rm -rf "$tmp"

    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T4i: must emit decision:block (findings path under ccSid)"; return; fi
    if [ $rc -ne 2 ]; then fail "T4i: must exit 2, got rc=$rc"; return; fi
    if ! echo "$out" | grep -q '/sweep-worktrees'; then
        fail "T4i: wsid-resolved adaptive text must mention /sweep-worktrees"; return; fi
    if ! echo "$out" | grep -q 'WE-20'; then
        fail "T4i: wsid-resolved adaptive text must mention WE-20"; return; fi
    pass "T4i: ccSid != wsid, env named by wsid → adaptive fires via wsid fallback (/sweep-worktrees + WE-20)"
}

run_t4e
run_t4f
run_t4g
run_t4h
run_t4i

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
