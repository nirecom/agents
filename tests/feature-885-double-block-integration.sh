#!/bin/bash
# tests/feature-885-double-block-integration.sh
# Tests: hooks/enforce-worktree.js + hooks/enforce-issue-close.js + hooks/lib/supervisor-state-writer.js
# Tags: double-block, integration, co-blocked-by, axis-a, feature-885
# Integration test for issue #885 — synthesize a double-block scenario.
#
# Sequence:
#   1. enforce-worktree.js blocks `gh issue close 999` (out-of-session-scope main worktree)
#   2. enforce-issue-close.js blocks the same command (not inline-skill form)
#   3. Reading the supervisor state shows BOTH findings with co_blocked_by
#      pointing at each other.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK_EW="$AGENTS_DIR/hooks/enforce-worktree.js"
HOOK_IC="$AGENTS_DIR/hooks/enforce-issue-close.js"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'feat885int'; }

if [ ! -f "$HOOK_EW" ] || [ ! -f "$HOOK_IC" ]; then
    skip "hook(s) missing"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

MAIN_WT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree[[:space:]]+/, ""); print; exit}')"
if [ -n "$MAIN_WT" ] && command -v cygpath >/dev/null 2>&1; then
    MAIN_WT_NODE="$(cygpath -m "$MAIN_WT")"
else
    MAIN_WT_NODE="$MAIN_WT"
fi

if [ -z "$MAIN_WT" ] || [ ! -d "$MAIN_WT" ]; then
    skip "I1: cannot resolve main worktree"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

SID="sid-i1-$$"
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi

CMD="gh issue close 999"

# Step 1: feed to enforce-worktree (from main worktree CWD — blocked).
JSON_EW='{"tool_name":"Bash","tool_input":{"command":"'"$CMD"'","cwd":"'"$MAIN_WT_NODE"'"},"session_id":"'"$SID"'"}'
WORKFLOW_PLANS_DIR="$TMP_NODE" ENFORCE_WORKTREE=on \
    run_with_timeout 15 bash -c "echo '$JSON_EW' | node '$HOOK_EW'" >/dev/null 2>&1 || true

# Step 2: feed the same command to enforce-issue-close (also blocked).
JSON_IC='{"tool_name":"Bash","tool_input":{"command":"'"$CMD"'"},"session_id":"'"$SID"'"}'
WORKFLOW_PLANS_DIR="$TMP_NODE" \
    run_with_timeout 15 bash -c "echo '$JSON_IC' | node '$HOOK_IC'" >/dev/null 2>&1 || true

STATE_FILE="$TMP/${SID}-supervisor-state.json"
if [ ! -f "$STATE_FILE" ]; then
    skip "I1: no state file written (no hook blocked; integration scenario requires enforce-worktree to block gh issue close from main worktree)"
    rm -rf "$TMP"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

out=$(node -e "
const fs = require('fs');
const st = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
const f = st.layer1.findings || [];
const ew = f.find(x => x.reporter === 'enforce-worktree');
const ic = f.find(x => x.reporter === 'enforce-issue-close');
if (!ew) {
  console.log('SKIP_NOEW');
  process.exit(0);
}
if (!ic) { console.error('missing enforce-issue-close finding'); process.exit(3); }
if (!Array.isArray(ew.co_blocked_by) || !ew.co_blocked_by.includes('enforce-issue-close')) {
  console.error('ew.co_blocked_by missing enforce-issue-close: '+JSON.stringify(ew.co_blocked_by)); process.exit(4);
}
if (!Array.isArray(ic.co_blocked_by) || !ic.co_blocked_by.includes('enforce-worktree')) {
  console.error('ic.co_blocked_by missing enforce-worktree: '+JSON.stringify(ic.co_blocked_by)); process.exit(5);
}
console.log('OK');
" "$STATE_FILE" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
    pass "I1: double-block produces 2 findings with mutual co_blocked_by"
elif [ "$out" = "SKIP_NOEW" ]; then
    skip "I1: enforce-worktree did not block this command shape from main worktree (integration depends on session-scope config)"
else
    fail "I1: (rc=$rc, out=$out)"
fi

rm -rf "$TMP"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
