#!/usr/bin/env bash
# tests/feature-supervisor-preuse-off-proposal.sh
# Tests: hooks/supervisor-off-proposal-shim.js
# Tags: supervisor, em-supervisor, pretooluse, off-proposal, shim, clearance-token, reason-binding, scope:issue-specific, pwsh-not-required, hook-registration, TL1
# TL3 gap (what this test does NOT catch):
# - The shim firing as a real PreToolUse hook inside a live claude -p session
#   (settings.json PreToolUse registration — only verified via live session).
# - Real sentinel command forms + real clearance-token mint via bin/request-off-clearance.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#
# #1608 token-first rewrite: the shim gate now decides on a reason-bound clearance
# TOKEN (<workflowDir>/<sid>.off-clearance), INDEPENDENT of supervisor findings/severity.
#   - valid + reason-bound token → exit 0 (allow → human ask). Findings are irrelevant
#     (deadlock root fix: error findings + valid token still allow).
#   - reason/target-mismatch token → block (reason-binding, C2a).
#   - token absent (genuine emit) → block. The old enforce-worktree fast-allow (T4b) and
#     escape_hatch_event pass-through (T4d) are REMOVED: no token → block even when all
#     findings are from enforce-worktree.
#   - token read/parse failure (corrupt) → block (fail-CLOSED).
#   - expired token → block.
#   - look-alike (non-genuine) → exit 0 (real OFF never activates).

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
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'shimtok'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

if [ ! -f "$SHIM" ]; then
    fail "supervisor-off-proposal-shim.js not present (harness error)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi

# --- fixture writers (run inside a per-case tmp dir) ---
seed_state_empty() {  # <tmp_node> <sid>
    WORKFLOW_PLANS_DIR="$1" "$RWT" 10 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$2');
fs.writeFileSync(w.getStatePath('$2'), JSON.stringify(st));" >/dev/null 2>&1
}
seed_state_error() {  # <tmp_node> <sid>
    WORKFLOW_PLANS_DIR="$1" "$RWT" 10 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$2');
st.layer1.findings=[{categories:['code'],severity:'error',detail:'blocking',reporter:'workflow-gate',timestamp:new Date().toISOString()}];
fs.writeFileSync(w.getStatePath('$2'), JSON.stringify(st));" >/dev/null 2>&1
}
seed_state_worktree() {  # <tmp_node> <sid>
    WORKFLOW_PLANS_DIR="$1" "$RWT" 10 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$2');
st.layer1.findings=[{categories:['workflow'],severity:'warning',detail:'enforce-worktree false block',reporter:'enforce-worktree',timestamp:new Date().toISOString()}];
fs.writeFileSync(w.getStatePath('$2'), JSON.stringify(st));" >/dev/null 2>&1
}
# write_token <tmp_node> <sid> <target> <category> <kind: valid|expired|corrupt>
write_token() {
    "$RWT" 10 node -e "
const fs=require('fs'),path=require('path');
const p=path.join('$1','$2'+'.off-clearance');
if('$5'==='corrupt'){fs.writeFileSync(p,'{ this is not json ');process.exit(0);}
const exp = '$5'==='expired' ? new Date(Date.now()-60000).toISOString() : new Date(Date.now()+15*60000).toISOString();
fs.writeFileSync(p, JSON.stringify({target:'$3',category:'$4',urgency:'normal',minted_at:new Date().toISOString(),expires_at:exp,verdict_reason:'examiner ALLOW',detail:'stub'}));" >/dev/null 2>&1
}

# run_shim <tmp_node> <sid> <cmd> → prints "rc|<stdout>"
run_shim() {
    local tmp_node="$1" sid="$2" cmd="$3" hook_input out rc
    hook_input=$("$RWT" 10 node -e "
process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'$sid',tool_input:{command:process.argv[1]}}));" "$cmd")
    out=$(WORKFLOW_PLANS_DIR="$tmp_node" CLAUDE_WORKFLOW_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        "$RWT" 15 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

# run_shim_in_dir <run_cwd> <tmp_node> <sid> <cmd> → prints "rc|<stdout>"
# Same as run_shim, but runs node with CWD set to <run_cwd> so resolveWorkflowSessionId()'s
# Priority-1 WORKTREE_NOTES.md read (which reads process.cwd()/WORKTREE_NOTES.md) can be
# controlled deterministically, independent of the test-runner's own CWD.
run_shim_in_dir() {
    local run_cwd="$1" tmp_node="$2" sid="$3" cmd="$4" hook_input out rc
    hook_input=$("$RWT" 10 node -e "
process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'$sid',tool_input:{command:process.argv[1]}}));" "$cmd")
    out=$(cd "$run_cwd" && WORKFLOW_PLANS_DIR="$tmp_node" CLAUDE_WORKFLOW_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        "$RWT" 15 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

# seed_worktree_notes <dir> <wsid> — write WORKTREE_NOTES.md with the Session-ID line
# that resolveWorkflowSessionId() (hooks/lib/resolve-workflow-session-id.js) reads as its
# Priority-1 source (`^Session-ID:\s*(\S+)\s*$`), read from process.cwd().
seed_worktree_notes() {
    printf 'Session-ID: %s\n' "$2" > "$1/WORKTREE_NOTES.md"
}

WF_BOUND='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: [workflow-bug] next-step bug blocks progress>>"'
WF_WRONGCAT='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: [convenience] just easier to skip>>"'
WT_BOUND='echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: [workflow-bug] worktree guard false block>>"'
WF_LOOKALIKE='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF>>"'

is_block() { echo "$1" | grep -q '"decision":"block"'; }

# ===== T1: valid reason-bound token + ERROR findings → exit 0 (deadlock root fix) =====
run_T1() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_state_error "$tn" "t1sid"
    write_token "$tn" "t1sid" "workflow" "workflow-bug" "valid"
    r=$(run_shim "$tn" "t1sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "0" ] && ! is_block "$out"; then
        pass "T1: valid reason-bound token + error findings → exit 0 (token overrides findings)"
    else
        fail "T1: RED-EXPECTED (severity gate still live): valid token must allow despite error findings; rc=$rc out=$out"
    fi
}

# ===== T2: reason-category mismatch token → block (reason-binding C2a) =====
run_T2() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_state_empty "$tn" "t2sid"
    write_token "$tn" "t2sid" "workflow" "workflow-bug" "valid"
    r=$(run_shim "$tn" "t2sid" "$WF_WRONGCAT"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "2" ] && is_block "$out"; then
        pass "T2: token(category=workflow-bug) + reason [convenience] → block (reason-binding)"
    else
        fail "T2: RED-EXPECTED: reason-category mismatch must block; rc=$rc out=$out"
    fi
}

# ===== T2b: target-mismatch token → block (reason-binding C2a, target axis) =====
run_T2b() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_state_empty "$tn" "t2bsid"
    write_token "$tn" "t2bsid" "workflow" "workflow-bug" "valid"  # token for workflow target
    r=$(run_shim "$tn" "t2bsid" "$WT_BOUND"); rc="${r%%|*}"; out="${r#*|}"  # but WORKTREE_OFF emitted
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "2" ] && is_block "$out"; then
        pass "T2b: workflow-target token + WORKTREE_OFF emit → block (target mismatch)"
    else
        fail "T2b: RED-EXPECTED: target mismatch must block; rc=$rc out=$out"
    fi
}

# ===== T3: no token + genuine OFF (empty state) → block =====
run_T3() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_state_empty "$tn" "t3sid"   # no findings → current shim would PASS; token model must BLOCK
    r=$(run_shim "$tn" "t3sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "2" ] && is_block "$out"; then
        pass "T3: no clearance token + genuine OFF → block (exit 2)"
    else
        fail "T3: RED-EXPECTED (no token gate): missing token must block even with empty findings; rc=$rc out=$out"
    fi
}

# ===== T4: corrupt token file + genuine OFF → block (fail-CLOSED) =====
run_T4() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_state_empty "$tn" "t4sid"
    write_token "$tn" "t4sid" "workflow" "workflow-bug" "corrupt"
    r=$(run_shim "$tn" "t4sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "2" ] && is_block "$out"; then
        pass "T4: corrupt token file + genuine OFF → block (fail-CLOSED)"
    else
        fail "T4: RED-EXPECTED: corrupt token must fail-CLOSED (block); rc=$rc out=$out"
    fi
}

# ===== T5: expired token + genuine OFF → block =====
run_T5() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_state_empty "$tn" "t5sid"
    write_token "$tn" "t5sid" "workflow" "workflow-bug" "expired"
    r=$(run_shim "$tn" "t5sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "2" ] && is_block "$out"; then
        pass "T5: expired token + genuine OFF → block"
    else
        fail "T5: RED-EXPECTED: expired token must block; rc=$rc out=$out"
    fi
}

# ===== T6: look-alike (non-genuine) OFF → exit 0 (real OFF never activates) =====
run_T6() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")   # no state, no token (ENOENT)
    r=$(run_shim "$tn" "t6sid" "$WF_LOOKALIKE"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "0" ] && ! is_block "$out"; then
        pass "T6: look-alike (bare, no reason) OFF → pass through (exit 0)"
    else
        fail "T6: look-alike must pass through (non-genuine emit); rc=$rc out=$out"
    fi
}

# ===== T7: non-OFF command → pass through exit 0 =====
run_T7() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_state_error "$tn" "t7sid"
    r=$(run_shim "$tn" "t7sid" "git status"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "0" ] && ! is_block "$out"; then
        pass "T7: non-OFF command → shim passes through (exit 0)"
    else
        fail "T7: non-OFF command must pass through; rc=$rc out=$out"
    fi
}

# ===== T8: enforce-worktree-only findings + NO token → block (fast-allow removed) =====
run_T8() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_state_worktree "$tn" "t8sid"   # all findings from enforce-worktree, NO token
    r=$(run_shim "$tn" "t8sid" "$WT_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "2" ] && is_block "$out"; then
        pass "T8: enforce-worktree-only findings + no token → block (T4b/T4d fast-allow removed)"
    else
        fail "T8: RED-EXPECTED (fast-allow still live): no token must block even with enforce-worktree findings; rc=$rc out=$out"
    fi
}

# seed_marker <tmp_node> <sid> <kind: worktree-off|workflow-off> — write a session override marker
seed_marker() {
    "$RWT" 10 node -e "
const fs=require('fs'),path=require('path');
fs.writeFileSync(path.join('$1','$2.$3'),JSON.stringify({reason:'test',set_at:new Date().toISOString()}));" >/dev/null 2>&1
}

# ===== T9: Step-2 target-aware bypass — worktree-off marker honors a WORKTREE_OFF emit (no token) =====
run_T9() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_marker "$tn" "t9sid" "worktree-off"   # already worktree-off; NO clearance token
    r=$(run_shim "$tn" "t9sid" "$WT_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "0" ] && ! is_block "$out"; then
        pass "T9: worktree-off marker + WORKTREE_OFF emit → exit 0 (Step-2 target-aware honored, no token needed)"
    else
        fail "T9: RED-EXPECTED (worktree-target Step-2 not honored): worktree-off marker must bypass token gate for WORKTREE_OFF; rc=$rc out=$out"
    fi
}

# ===== T9b: target-awareness — worktree-off marker does NOT clear a WORKFLOW_OFF emit =====
run_T9b() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_marker "$tn" "t9bsid" "worktree-off"   # worktree-off marker only; WORKFLOW_OFF emitted, NO token
    r=$(run_shim "$tn" "t9bsid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "2" ] && is_block "$out"; then
        pass "T9b: worktree-off marker + WORKFLOW_OFF emit → block (worktree marker must not bypass workflow-target)"
    else
        fail "T9b: RED-EXPECTED (blanket bypass): worktree-off marker must NOT clear a workflow-target sentinel; rc=$rc out=$out"
    fi
}

# ===== T9c: WORKFLOW_OFF subsumes both targets — workflow-off marker honors a WORKTREE_OFF emit =====
run_T9c() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_marker "$tn" "t9csid" "workflow-off"   # already workflow-off; WORKTREE_OFF emitted, NO token
    r=$(run_shim "$tn" "t9csid" "$WT_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "0" ] && ! is_block "$out"; then
        pass "T9c: workflow-off marker + WORKTREE_OFF emit → exit 0 (WORKFLOW_OFF subsumes both targets)"
    else
        fail "T9c: RED-EXPECTED: workflow-off marker must bypass token gate for any OFF target; rc=$rc out=$out"
    fi
}

# ===== T10: Step-4 wsid-fallback read — no token for session_id, but a valid token IS
# keyed to the resolved workflow session id (wsid) → the shim falls back and allows =====
run_T10() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_worktree_notes "$tmp" "t10wsid"           # resolveWsid() -> "t10wsid" (Priority 1, CWD read)
    seed_state_empty "$tn" "t10wsid"
    write_token "$tn" "t10wsid" "workflow" "workflow-bug" "valid"   # keyed to wsid, NOT to session_id
    # deliberately do NOT write a t10sid.off-clearance token
    r=$(run_shim_in_dir "$tmp" "$tn" "t10sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "0" ] && ! is_block "$out"; then
        pass "T10: no token for session_id, valid token for resolved wsid → exit 0 (Step-4 wsid-fallback read)"
    else
        fail "T10: RED-EXPECTED (Step-4 own wsid-fallback not honored): rc=$rc out=$out"
    fi
}

# ===== T10b: Step-4 wsid-fallback read still runs full validation — a wsid-keyed token
# with a mismatched reason-category must still block (fallback does not skip binding) =====
run_T10b() {
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_worktree_notes "$tmp" "t10bwsid"          # resolveWsid() -> "t10bwsid"
    seed_state_empty "$tn" "t10bwsid"
    write_token "$tn" "t10bwsid" "workflow" "workflow-bug" "valid"  # category=workflow-bug
    # no t10bsid.off-clearance token; emitted reason carries [convenience], not [workflow-bug]
    r=$(run_shim_in_dir "$tmp" "$tn" "t10bsid" "$WF_WRONGCAT"); rc="${r%%|*}"; out="${r#*|}"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "2" ] && is_block "$out"; then
        pass "T10b: wsid-fallback token found but reason-category mismatch → block (validation still applies)"
    else
        fail "T10b: RED-EXPECTED: wsid-fallback must not skip reason-binding validation; rc=$rc out=$out"
    fi
}

run_T1
run_T2
run_T2b
run_T3
run_T4
run_T5
run_T6
run_T7
run_T8
run_T9
run_T9b
run_T9c
run_T10
run_T10b

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
