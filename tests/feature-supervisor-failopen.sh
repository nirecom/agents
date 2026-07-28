#!/usr/bin/env bash
# tests/feature-supervisor-failopen.sh
# Tests: hooks/supervisor-off-proposal-shim.js, hooks/workflow-gate.js
# Tags: supervisor, em-supervisor, fail-open, resilience, scope:issue-specific, pwsh-not-required, hook-registration
# L3 gap (what this test does NOT catch):
# - Real Claude Code session with corrupted state file — tests inject corruption directly
# - Real PreToolUse/Stop hook registration firing with corrupt state
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# SKIPPED: Operational fail-open edge cases for scope-drift (C5)
# Because: missing detail plan / malformed ## Files to modify / non-git-repo require
#   fixture manipulation that conflicts with the existing T7 git-based setup; deferred
#   to implementation-time expansion
# L3 gap: integration test that calls checkSupervisorPreMerge with a real git repo
#   whose detail.md has a malformed Files-to-modify section

# T7: Corrupt/invalid JSON (and zero-byte) supervisor state file.
#
# NEW contract (#1608 token-first gate): the shim's verdict comes from the OFF-clearance
# token, never from supervisor state. Supervisor state is read only to pick the honest
# block-message wording (#1606). So corrupt/empty state must:
#   - never crash the shim (rc is 0 or 2 only, never a Node stack trace, never rc > 2), and
#   - never change the verdict: no token → block; valid reason-bound token → pass through.
# T7a/T7c cover the no-token (block) side; T7a-token/T7c-token cover the token (pass) side.
# workflow-gate.js (T7b) keeps its own fail-open invariant on corrupt state.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SHIM="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"
HOOK="$AGENTS_DIR/hooks/workflow-gate.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
WFSTATE_NODE="$_AGENTS_DIR_NODE/hooks/lib/workflow-state.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsr7'; }

write_corrupt_state() {
    local tmp_node="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
const p = w.getStatePath('$sid');
fs.mkdirSync(require('path').dirname(p), { recursive: true });
// Write corrupted JSON — truncated, invalid syntax
fs.writeFileSync(p, '{\"version\":1,\"session_id\":\"$sid\",corrupt');
" >/dev/null 2>&1
}

write_empty_state() {
    local tmp_node="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
const p = w.getStatePath('$sid');
fs.mkdirSync(require('path').dirname(p), { recursive: true });
fs.writeFileSync(p, '');  // zero-byte
" >/dev/null 2>&1
}

# Mint a valid reason-bound clearance token (#1608) at <CLAUDE_WORKFLOW_DIR>/<sid>.off-clearance.
# Shape mirrors bin/request-off-clearance's ALLOW mint.
mint_clearance_token() {
    local tmp_node="$1" sid="$2" target="$3" category="$4"
    CLAUDE_WORKFLOW_DIR="$tmp_node" run_with_timeout 5 node -e "
const fs = require('fs'), path = require('path');
const now = Date.now();
fs.mkdirSync('$tmp_node', { recursive: true });
fs.writeFileSync(path.join('$tmp_node', '$sid' + '.off-clearance'), JSON.stringify({
  target: '$target',
  category: '$category',
  urgency: 'normal',
  minted_at: new Date(now).toISOString(),
  expires_at: new Date(now + 15 * 60 * 1000).toISOString(),
  verdict_reason: 'test mint',
  detail: 'test mint'
}));
" >/dev/null 2>&1
}

# Run the shim on an OFF-sentinel emit; echoes "<verdict>|<rc>|<stderr-bytes>".
# verdict: block | pass
run_shim_off() {
    local tmp_node="$1" sid="$2" off_cmd="$3" out rc errfile errlen
    errfile="$tmp_node/shim-stderr.txt"
    local hook_input
    hook_input=$(node -e "
process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    session_id: process.argv[1],
    tool_input: { command: process.argv[2] }
}));
" -- "$sid" "$off_cmd")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" CLAUDE_WORKFLOW_DIR="$tmp_node" \
        run_with_timeout 10 node "$SHIM" <<< "$hook_input" 2>"$errfile")
    rc=$?
    errlen=$(wc -c < "$errfile" 2>/dev/null | tr -d ' ')
    [ -n "$errlen" ] || errlen=0
    if echo "$out" | grep -q '"decision":"block"'; then
        echo "block|$rc|$errlen"
    else
        echo "pass|$rc|$errlen"
    fi
}

seed_wf_state_complete() {
    local tmp_node="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const wf = require('$WFSTATE_NODE');
wf.markStep('$sid', 'user_verification', 'complete');
" >/dev/null 2>&1
}

# --- T7a: Corrupt state + OFF cmd, NO clearance token → shim survives and blocks ---
# Corrupt supervisor state must not crash the shim; the verdict comes from the token
# gate (no token → block), not from the unreadable state.
run_t7a() {
    local tmp sid tmp_node result verdict rc errlen
    tmp=$(make_tmp)
    sid="t7a-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

    if [ ! -f "$SHIM" ]; then
        skip "T7a: supervisor-off-proposal-shim.js not present (NEW file)"
        rm -rf "$tmp"
        return
    fi

    write_corrupt_state "$tmp_node" "$sid"

    result=$(run_shim_off "$tmp_node" "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: recovery>>"')
    verdict=${result%%|*}; rc=$(echo "$result" | cut -d'|' -f2); errlen=$(echo "$result" | cut -d'|' -f3)

    rm -rf "$tmp"

    # Resilience: no crash — rc is a defined hook verdict, stderr carries no stack trace.
    if [ "$rc" != "0" ] && [ "$rc" != "2" ]; then
        fail "T7a: shim must not crash on corrupt state (rc must be 0 or 2), got rc=$rc"
        return
    fi
    if [ "$errlen" != "0" ]; then
        fail "T7a: shim wrote to stderr on corrupt state (${errlen}B) — expected no Node stack trace"
        return
    fi
    if [ "$verdict" != "block" ]; then
        fail "T7a: corrupt state must not change the verdict — no clearance token → block, got=$verdict"
        return
    fi
    pass "T7a: corrupt state + no clearance token → shim survives (rc=2) and blocks on the token gate"
}

# --- T7a-token: Corrupt state + VALID clearance token → sentinel passes through ---
run_t7a_token() {
    local tmp sid tmp_node result verdict rc errlen
    tmp=$(make_tmp)
    sid="t7a-token-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

    if [ ! -f "$SHIM" ]; then
        skip "T7a-token: supervisor-off-proposal-shim.js not present (NEW file)"
        rm -rf "$tmp"
        return
    fi

    write_corrupt_state "$tmp_node" "$sid"
    mint_clearance_token "$tmp_node" "$sid" "workflow" "workflow-bug"

    result=$(run_shim_off "$tmp_node" "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: [workflow-bug] recovery>>"')
    verdict=${result%%|*}; rc=$(echo "$result" | cut -d'|' -f2); errlen=$(echo "$result" | cut -d'|' -f3)

    rm -rf "$tmp"

    if [ "$errlen" != "0" ]; then
        fail "T7a-token: shim wrote to stderr on corrupt state (${errlen}B) — expected no Node stack trace"
        return
    fi
    if [ "$verdict" = "pass" ] && [ "$rc" = "0" ]; then
        pass "T7a-token: corrupt state + valid reason-bound token → shim exits 0 (state cannot veto the token)"
    else
        fail "T7a-token: valid token must pass through despite corrupt state, got verdict=$verdict rc=$rc"
    fi
}

# --- T7b: Corrupt state + gh pr merge → workflow-gate must exit 0/approve (fail-open) ---
run_t7b() {
    local tmp sid out rc
    tmp=$(make_tmp)
    sid="t7b-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    write_corrupt_state "$tmp_node" "$sid"
    seed_wf_state_complete "$tmp_node" "$sid"

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash"}}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    # The workflow-gate may or may not know about checkSupervisorPreMerge yet.
    # If it does, corrupt state must be fail-open (no block from supervisor path).
    # The gate may block for OTHER reasons (no user_verification) — but must not block
    # specifically due to corrupt supervisor state.
    # We test: if it emits block, the reason must NOT mention supervisor/audit.
    if echo "$out" | grep -q '"decision":"block"'; then
        local reason
        reason=$(echo "$out" | node -e "
const s=JSON.parse(require('fs').readFileSync(0,'utf8'));
process.stdout.write((s&&s.reason)||'');
" 2>/dev/null)
        if echo "$reason" | grep -qiE "supervisor|audit_phase|scope-drift"; then
            fail "T7b: workflow-gate must NOT block due to supervisor reason when state is corrupt (fail-open violated)"
            return
        fi
    fi
    pass "T7b: corrupt supervisor state → workflow-gate does not block on supervisor path (fail-open)"
}

# --- T7c: Empty/zero-byte state file, NO clearance token → shim survives and blocks ---
run_t7c() {
    local tmp sid tmp_node result verdict rc errlen
    tmp=$(make_tmp)
    sid="t7c-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

    if [ ! -f "$SHIM" ]; then
        skip "T7c: supervisor-off-proposal-shim.js not present"
        rm -rf "$tmp"
        return
    fi

    write_empty_state "$tmp_node" "$sid"

    result=$(run_shim_off "$tmp_node" "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: recovery>>"')
    verdict=${result%%|*}; rc=$(echo "$result" | cut -d'|' -f2); errlen=$(echo "$result" | cut -d'|' -f3)

    rm -rf "$tmp"

    if [ "$rc" != "0" ] && [ "$rc" != "2" ]; then
        fail "T7c: shim must not crash on empty state (rc must be 0 or 2), got rc=$rc"
        return
    fi
    if [ "$errlen" != "0" ]; then
        fail "T7c: shim wrote to stderr on empty state (${errlen}B) — expected no Node stack trace"
        return
    fi
    if [ "$verdict" != "block" ]; then
        fail "T7c: empty state must not change the verdict — no clearance token → block, got=$verdict"
        return
    fi
    pass "T7c: empty state file + no clearance token → shim survives (rc=2) and blocks on the token gate"
}

# --- T7c-token: Empty/zero-byte state + VALID clearance token → sentinel passes through ---
run_t7c_token() {
    local tmp sid tmp_node result verdict rc errlen
    tmp=$(make_tmp)
    sid="t7c-token-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

    if [ ! -f "$SHIM" ]; then
        skip "T7c-token: supervisor-off-proposal-shim.js not present"
        rm -rf "$tmp"
        return
    fi

    write_empty_state "$tmp_node" "$sid"
    mint_clearance_token "$tmp_node" "$sid" "worktree" "cleanup"

    result=$(run_shim_off "$tmp_node" "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: [cleanup] recovery>>"')
    verdict=${result%%|*}; rc=$(echo "$result" | cut -d'|' -f2); errlen=$(echo "$result" | cut -d'|' -f3)

    rm -rf "$tmp"

    if [ "$errlen" != "0" ]; then
        fail "T7c-token: shim wrote to stderr on empty state (${errlen}B) — expected no Node stack trace"
        return
    fi
    if [ "$verdict" = "pass" ] && [ "$rc" = "0" ]; then
        pass "T7c-token: empty state + valid reason-bound token → shim exits 0 (state cannot veto the token)"
    else
        fail "T7c-token: valid token must pass through despite empty state, got verdict=$verdict rc=$rc"
    fi
}

run_t7a
run_t7a_token
run_t7b
run_t7c
run_t7c_token

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
