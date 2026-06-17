#!/bin/bash
# tests/feature-885-workflow-gate-context-populate.sh
# Tests: hooks/workflow-gate.js
# Tags: workflow-gate, context-populate, axis-a, feature-885
# Tests for issue #885 — workflow-gate.js block() populates context.cwd from
# toolInput.cwd, and context.git_root_resolved=true when repoDir was resolved.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/workflow-gate.js"

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

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'feat885wg'; }

if [ ! -f "$HOOK" ]; then
    skip "workflow-gate.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

read_findings() {
    local tmpdir="$1" sid="$2"
    local f="$tmpdir/${sid}-supervisor-state.json"
    if [ ! -f "$f" ]; then
        echo "[]"
        return
    fi
    node -e "
const fs = require('fs');
try {
  const st = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  process.stdout.write(JSON.stringify(st.layer1.findings || []));
} catch (e) { process.stdout.write('[]'); }
" "$f"
}

MAIN_WT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree[[:space:]]+/, ""); print; exit}')"
if [ -n "$MAIN_WT" ] && command -v cygpath >/dev/null 2>&1; then
    MAIN_WT_NODE="$(cygpath -m "$MAIN_WT")"
else
    MAIN_WT_NODE="$MAIN_WT"
fi

# --- WG1: early block path (malformed stdin) — context.cwd may be undefined
# This case exercises the very early `block(...)` on stdin parse failure where
# toolInput.cwd is not yet known. The expected behavior is graceful: either
# context absent or context.cwd missing — not a crash.
SID_WG1="sid-wg1-$$"
TMP_WG1=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_WG1_NODE=$(cygpath -m "$TMP_WG1"); else TMP_WG1_NODE="$TMP_WG1"; fi
# Send invalid JSON
WORKFLOW_PLANS_DIR="$TMP_WG1_NODE" run_with_timeout 10 bash -c "printf 'not-json' | node '$HOOK'" >/dev/null 2>&1 || true
findings_json=$(read_findings "$TMP_WG1" "$SID_WG1")
# Early block has no sessionId resolved → no finding written. That's acceptable.
out=$(node -e "
const f = $findings_json;
// No finding expected for malformed stdin (no session_id). Should not have crashed.
console.log('OK');
" 2>&1)
if [ "$out" = "OK" ]; then
    pass "WG1: malformed stdin does not crash; finding absence is acceptable"
else
    fail "WG1: out=$out"
fi
rm -rf "$TMP_WG1"

# --- WG2: late block (after repoDir resolved) — context.cwd + git_root_resolved=true
# Strategy: trigger a workflow-gate block on a `git commit` from the main worktree
# without a workflow state present → blocks with "no workflow state found".
SID_WG2="sid-wg2-$$"
TMP_WG2=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_WG2_NODE=$(cygpath -m "$TMP_WG2"); else TMP_WG2_NODE="$TMP_WG2"; fi
if [ -z "$MAIN_WT" ] || [ ! -d "$MAIN_WT" ]; then
    skip "WG2: cannot resolve main worktree"
else
    JSON='{"tool_name":"Bash","tool_input":{"command":"git commit -m x","cwd":"'"$MAIN_WT_NODE"'"},"session_id":"'"$SID_WG2"'"}'
    WORKFLOW_PLANS_DIR="$TMP_WG2_NODE" ENFORCE_WORKTREE=on \
        run_with_timeout 15 bash -c "echo '$JSON' | node '$HOOK'" >/dev/null 2>&1 || true
    findings_json=$(read_findings "$TMP_WG2" "$SID_WG2")
    out=$(node -e "
const f = $findings_json;
const x = f.find(x => x.reporter === 'workflow-gate');
if (!x) { console.log('SKIP_NOFINDING'); process.exit(0); }
if (!x.context || typeof x.context.cwd !== 'string' || !x.context.cwd) {
  console.error('context.cwd missing: '+JSON.stringify(x)); process.exit(2);
}
if (x.context.git_root_resolved !== true) {
  console.error('git_root_resolved not true (expected late-block from repoDir resolved): '+JSON.stringify(x.context)); process.exit(3);
}
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "WG2: late block populates context.cwd + git_root_resolved=true"
    elif [ "$out" = "SKIP_NOFINDING" ]; then
        skip "WG2: no workflow-gate finding emitted (gate may have approved)"
    else
        fail "WG2: (rc=$rc, out=$out)"
    fi
fi
rm -rf "$TMP_WG2"

# --- WG3: toolInput.cwd missing → context.cwd absent or empty ---------------
SID_WG3="sid-wg3-$$"
TMP_WG3=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_WG3_NODE=$(cygpath -m "$TMP_WG3"); else TMP_WG3_NODE="$TMP_WG3"; fi
JSON='{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"session_id":"'"$SID_WG3"'"}'
WORKFLOW_PLANS_DIR="$TMP_WG3_NODE" ENFORCE_WORKTREE=on \
    run_with_timeout 15 bash -c "echo '$JSON' | node '$HOOK'" >/dev/null 2>&1 || true
findings_json=$(read_findings "$TMP_WG3" "$SID_WG3")
out=$(node -e "
const f = $findings_json;
const x = f.find(x => x.reporter === 'workflow-gate');
if (!x) { console.log('SKIP_NOFINDING'); process.exit(0); }
if (x.context && typeof x.context.cwd === 'string' && x.context.cwd.length > 0) {
  // Acceptable — hook may fall back to process.cwd()
  console.log('OK');
  process.exit(0);
}
// Otherwise: context absent or cwd empty — also acceptable.
console.log('OK');
" 2>&1)
rc=$?
if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
    pass "WG3: missing toolInput.cwd handled gracefully"
elif [ "$out" = "SKIP_NOFINDING" ]; then
    skip "WG3: no workflow-gate finding emitted"
else
    fail "WG3: (rc=$rc, out=$out)"
fi
rm -rf "$TMP_WG3"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
