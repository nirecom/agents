#!/bin/bash
# tests/feature-831-auto-report-integration.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-issue-close.js, hooks/workflow-gate.js, hooks/workflow-mark/enforce-override-handlers.js
# Tags: supervisor, em-supervisor, layer1, hook, integration, auto-report
# Tests for issue #831 — hook auto-report integration.
#
# Pipes synthetic JSON payloads to each hook and asserts a finding was written
# to PLANS_DIR/<sid>-supervisor-state.json with the correct taxonomy. Negative
# cases (WORKFLOW_ON sentinel) assert NO finding is written.
#
# RED until the hooks adopt hooks/lib/supervisor-emit.js. Cases SKIP when a
# feature-probe shows the integration is not yet wired up — they are not
# expected to pass pre-implementation.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

ENFORCE_WT="$AGENTS_DIR/hooks/enforce-worktree.js"
ENFORCE_IC="$AGENTS_DIR/hooks/enforce-issue-close.js"
WF_GATE="$AGENTS_DIR/hooks/workflow-gate.js"
OVERRIDE_HANDLERS="$AGENTS_DIR/hooks/workflow-mark/enforce-override-handlers.js"
EMIT_MODULE="$AGENTS_DIR/hooks/lib/supervisor-emit.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_source() {
    local p="$1" label="$2"
    if [ ! -f "$p" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# Read finding count in supervisor-state.json
finding_count() {
    local tmp_node="$1" sid="$2"
    run_with_timeout 5 node -e "
const fs=require('fs');
const p=require('path').join(process.argv[1], process.argv[2]+'-supervisor-state.json');
try { const st=JSON.parse(fs.readFileSync(p,'utf8')); console.log((st.layer1&&st.layer1.findings||[]).length); }
catch(e){ console.log(0); }
" -- "$tmp_node" "$sid" 2>/dev/null
}

# Read first finding fields → 'cats|severity|reporter'
finding_first() {
    local tmp_node="$1" sid="$2"
    run_with_timeout 5 node -e "
const fs=require('fs');
const p=require('path').join(process.argv[1], process.argv[2]+'-supervisor-state.json');
try {
  const st=JSON.parse(fs.readFileSync(p,'utf8'));
  const f=(st.layer1&&st.layer1.findings||[])[0];
  if(!f){console.log('');process.exit(0);}
  console.log([(f.categories||[]).slice().sort().join(','), f.severity||'', f.reporter||''].join('|'));
} catch(e){ console.log(''); }
" -- "$tmp_node" "$sid" 2>/dev/null
}

# Probe whether supervisor-emit.js exists — gates the integration cases.
FEATURE_PRESENT=0
[ -f "$EMIT_MODULE" ] && FEATURE_PRESENT=1

# --- I1: enforce-worktree.js block emits a finding ---
run_i1() {
    require_source "$ENFORCE_WT" "I1: enforce-worktree.js block writes a finding" || return
    if [ $FEATURE_PRESENT -eq 0 ]; then
        skip "I1: enforce-worktree.js block writes a finding (supervisor-emit.js not implemented yet)"
        return
    fi
    local tmp tmp_node sid="i1-sid"
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    # Synthetic Edit payload targeting a file in the main repo root (not a worktree)
    local payload
    payload=$(run_with_timeout 5 node -e "
console.log(JSON.stringify({
  session_id: 'i1-sid',
  tool_name: 'Edit',
  tool_input: { file_path: process.argv[1] + '/README.md', old_string: 'a', new_string: 'b' }
}));
" -- "$_AGENTS_DIR_NODE" 2>/dev/null)
    # Run the hook with ENFORCE_WORKTREE=on and an inherited CWD in the agents root.
    local out rc
    out=$(echo "$payload" | (
        cd "$_AGENTS_DIR_NODE" && \
        ENFORCE_WORKTREE=on \
        WORKFLOW_PLANS_DIR="$tmp" \
        run_with_timeout 10 node "$_AGENTS_DIR_NODE/hooks/enforce-worktree.js" 2>/dev/null
    ))
    rc=$?
    local blocked=0
    echo "$out" | grep -q '"decision":"block"' && blocked=1
    local n
    n=$(finding_count "$tmp_node" "$sid")
    if [ "$blocked" = "1" ] && [ "$n" -ge 1 ]; then
        local f; f=$(finding_first "$tmp_node" "$sid")
        case "$f" in
            workflow*warning*enforce-worktree*) pass "I1: enforce-worktree.js block writes a finding" ;;
            *) fail "I1: enforce-worktree.js block writes a finding (taxonomy mismatch: $f)" ;;
        esac
    else
        fail "I1: enforce-worktree.js block writes a finding (blocked=$blocked, count=$n, rc=$rc)"
    fi
    rm -rf "$tmp"
}

# --- I2: enforce-issue-close.js block emits a finding ---
run_i2() {
    require_source "$ENFORCE_IC" "I2: enforce-issue-close.js block writes a finding" || return
    if [ $FEATURE_PRESENT -eq 0 ]; then
        skip "I2: enforce-issue-close.js block writes a finding (supervisor-emit.js not implemented yet)"
        return
    fi
    local tmp tmp_node sid="i2-sid"
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    local payload
    payload=$(run_with_timeout 5 node -e "
console.log(JSON.stringify({
  session_id: 'i2-sid',
  tool_name: 'Bash',
  tool_input: { command: 'gh issue close 1' }
}));" 2>/dev/null)
    local out rc
    out=$(echo "$payload" | WORKFLOW_PLANS_DIR="$tmp" \
        run_with_timeout 10 node "$_AGENTS_DIR_NODE/hooks/enforce-issue-close.js" 2>/dev/null)
    rc=$?
    local n; n=$(finding_count "$tmp_node" "$sid")
    if [ "$rc" = "2" ] && [ "$n" -ge 1 ]; then
        local f; f=$(finding_first "$tmp_node" "$sid")
        case "$f" in
            workflow*warning*enforce-issue-close*) pass "I2: enforce-issue-close.js block writes a finding" ;;
            *) fail "I2: enforce-issue-close.js block writes a finding (taxonomy mismatch: $f)" ;;
        esac
    else
        fail "I2: enforce-issue-close.js block writes a finding (rc=$rc, count=$n)"
    fi
    rm -rf "$tmp"
}

# --- I3: workflow-gate.js Gate 1 unstaged-tracked block emits a finding ---
run_i3() {
    require_source "$WF_GATE" "I3: workflow-gate.js Gate 1 unstaged-tracked block writes a finding" || return
    if [ $FEATURE_PRESENT -eq 0 ]; then
        skip "I3: workflow-gate.js Gate 1 unstaged-tracked block writes a finding (supervisor-emit.js not implemented yet)"
        return
    fi
    if ! command -v git >/dev/null 2>&1; then
        skip "I3: workflow-gate.js Gate 1 unstaged-tracked block writes a finding (git not available)"
        return
    fi
    local tmp tmp_node sid="i3-sid"
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    local repo="$tmp/repo"
    mkdir -p "$repo"
    (
        cd "$repo" && \
        git init -q -b feature/i3 && \
        git config user.email "test@example.com" && git config user.name "test" && \
        printf "v1\n" > tracked.txt && \
        git add tracked.txt && git commit -q -m "init" && \
        printf "v2\n" > tracked.txt
    ) >/dev/null 2>&1 || { rm -rf "$tmp"; skip "I3: workflow-gate.js Gate 1 unstaged-tracked block writes a finding (git setup failed)"; return; }
    local payload
    payload=$(run_with_timeout 5 node -e "
console.log(JSON.stringify({
  session_id: 'i3-sid',
  tool_name: 'Bash',
  tool_input: { command: \"git commit -m 'x'\" },
  cwd: process.argv[1]
}));" -- "$(to_node_path "$repo")" 2>/dev/null)
    local out rc
    out=$(echo "$payload" | (
        cd "$repo" && \
        WORKFLOW_PLANS_DIR="$tmp" \
        run_with_timeout 10 node "$_AGENTS_DIR_NODE/hooks/workflow-gate.js" 2>/dev/null
    ))
    rc=$?
    local n; n=$(finding_count "$tmp_node" "$sid")
    if [ "$n" -ge 1 ]; then
        local f; f=$(finding_first "$tmp_node" "$sid")
        case "$f" in
            workflow*warning*workflow-gate*) pass "I3: workflow-gate.js Gate 1 unstaged-tracked block writes a finding" ;;
            *) fail "I3: workflow-gate.js Gate 1 unstaged-tracked block writes a finding (taxonomy mismatch: $f)" ;;
        esac
    else
        fail "I3: workflow-gate.js Gate 1 unstaged-tracked block writes a finding (count=$n, rc=$rc)"
    fi
    rm -rf "$tmp"
}

# --- I4: enforce-override-handlers WORKFLOW_OFF sentinel triggers a finding ---
run_i4() {
    require_source "$OVERRIDE_HANDLERS" "I4: WORKFLOW_OFF sentinel triggers a finding" || return
    if [ $FEATURE_PRESENT -eq 0 ]; then
        skip "I4: WORKFLOW_OFF sentinel triggers a finding (supervisor-emit.js not implemented yet)"
        return
    fi
    local tmp tmp_node sid="i4-sid"
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    # Drive the handler directly via a small node program (it's a library module,
    # not a stdin-reading hook). The workflow-mark dispatcher is the integration
    # point — we exercise the override-handlers contract from inside it.
    local prog="$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers.js"
    WORKFLOW_PLANS_DIR="$tmp" \
    WORKFLOW_DIR="$tmp" \
    run_with_timeout 10 node -e "
const oh = require('$prog');
const messages = [];
let fatal = null;
oh.handle({
  cmd: 'echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: trivial typo fix>>\"',
  sessionId: '$sid',
  pushMessage: (m) => messages.push(m),
  signalFatal: (m) => { fatal = m; },
});
" >/dev/null 2>&1
    local n; n=$(finding_count "$tmp_node" "$sid")
    if [ "$n" -ge 1 ]; then
        local f; f=$(finding_first "$tmp_node" "$sid")
        case "$f" in
            workflow*warning*enforce-override-handlers*) pass "I4: WORKFLOW_OFF sentinel triggers a finding" ;;
            *) fail "I4: WORKFLOW_OFF sentinel triggers a finding (taxonomy mismatch: $f)" ;;
        esac
    else
        fail "I4: WORKFLOW_OFF sentinel triggers a finding (count=$n)"
    fi
    rm -rf "$tmp"
}

# --- I5: WORKFLOW_ON sentinel does NOT trigger a finding ---
run_i5() {
    require_source "$OVERRIDE_HANDLERS" "I5: WORKFLOW_ON sentinel does NOT trigger a finding" || return
    local tmp tmp_node sid="i5-sid"
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    local prog="$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers.js"
    WORKFLOW_PLANS_DIR="$tmp" \
    WORKFLOW_DIR="$tmp" \
    run_with_timeout 10 node -e "
const oh = require('$prog');
const messages = [];
let fatal = null;
oh.handle({
  cmd: 'echo \"<<WORKFLOW_ENFORCE_WORKFLOW_ON: restore enforcement>>\"',
  sessionId: '$sid',
  pushMessage: (m) => messages.push(m),
  signalFatal: (m) => { fatal = m; },
});
" >/dev/null 2>&1
    local n; n=$(finding_count "$tmp_node" "$sid")
    if [ "$n" = "0" ]; then
        pass "I5: WORKFLOW_ON sentinel does NOT trigger a finding"
    else
        fail "I5: WORKFLOW_ON sentinel does NOT trigger a finding (count=$n)"
    fi
    rm -rf "$tmp"
}

run_i1
run_i2
run_i3
run_i4
run_i5

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
