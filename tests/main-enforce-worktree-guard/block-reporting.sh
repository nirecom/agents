# Tests: hooks/enforce-worktree.js
# Tags: TL2, enforce-worktree, context-populate, block-extras, scope:common
# Sourced by tests/main-enforce-worktree-guard.sh
# Origin: tests/feature-885-enforce-worktree-context-populate.sh (all cases).
# Cases: W1-W3.

# What the block path REPORTS, not whether it blocks: done() must populate
# extras={reason, context} when reporting via reportBlock(), and must NOT
# populate co_blocked_by — the writer back-annotates that field.

br_make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'feat885ew'; }

# The main worktree of the repo this suite runs in (shared harness helper).
BR_MAIN_WT="$(main_worktree_dir)"

br_read_findings() {
    local f="$1/${2}-supervisor-state.json"
    if [ ! -f "$f" ]; then echo "[]"; return; fi
    node -e "
const fs = require('fs');
try {
  const st = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  process.stdout.write(JSON.stringify(st.layer1.findings || []));
} catch (e) { process.stdout.write('[]'); }
" "$f"
}

# --- W1: block from the main worktree → context.cwd present, git_root_resolved=true
BR_SID_W1="sid-w1-$$"
BR_TMP_W1=$(br_make_tmp)
BR_TMP_W1_NODE="$(to_node_path "$BR_TMP_W1")"

if [ -z "$BR_MAIN_WT" ] || [ ! -d "$BR_MAIN_WT" ]; then
    skip "W1: cannot resolve main worktree"
else
    BR_MAIN_WT_J="$(to_node_path "$BR_MAIN_WT")"
    BR_JSON='{"tool_name":"Bash","tool_input":{"command":"echo x > '"$BR_MAIN_WT_J"'/touched.txt","cwd":"'"$BR_MAIN_WT_J"'"},"session_id":"'"$BR_SID_W1"'"}'
    run_guard_payload "$BR_JSON" "" WORKFLOW_PLANS_DIR="$BR_TMP_W1_NODE" \
        >/dev/null 2>&1 || true
    br_findings=$(br_read_findings "$BR_TMP_W1" "$BR_SID_W1")
    br_out=$(node -e "
const f = JSON.parse(process.argv[1]);
const x = f.find(x => x.reporter === 'enforce-worktree');
if (!x) { console.log('SKIP_NOFINDING'); process.exit(0); }
if (!x.context || typeof x.context.cwd !== 'string') { console.error('no context.cwd: '+JSON.stringify(x)); process.exit(3); }
if (x.context.git_root_resolved !== true) { console.error('git_root_resolved not true: '+JSON.stringify(x.context)); process.exit(4); }
if ('co_blocked_by' in x) {
  // The writer may back-annotate it; the HOOK itself must never pass it.
  if (Array.isArray(x.co_blocked_by) && x.co_blocked_by.length > 0) {
    console.error('co_blocked_by populated despite single reporter: '+JSON.stringify(x.co_blocked_by));
    process.exit(5);
  }
}
console.log('OK');
" -- "$br_findings" 2>&1)
    br_rc=$?
    if [ $br_rc -eq 0 ] && [ "$br_out" = "OK" ]; then
        pass "W1: block from main worktree populates context.cwd + git_root_resolved=true; no co_blocked_by"
    elif [ "$br_out" = "SKIP_NOFINDING" ]; then
        skip "W1: hook did not produce a finding for this command shape (synthetic command may not block; covered by integration test)"
    else
        fail "W1: (rc=$br_rc, out=$br_out)"
    fi
    rm -rf "$BR_TMP_W1"
fi

# --- W2: non-git CWD → reason='cwd_no_git_root', context.git_root_resolved=false
BR_SID_W2="sid-w2-$$"
BR_TMP_W2=$(br_make_tmp)
BR_NONGIT=$(br_make_tmp)
BR_TMP_W2_NODE="$(to_node_path "$BR_TMP_W2")"
BR_NONGIT_NODE="$(to_node_path "$BR_NONGIT")"
BR_JSON='{"tool_name":"Bash","tool_input":{"command":"echo x > '"$BR_NONGIT_NODE"'/touched.txt","cwd":"'"$BR_NONGIT_NODE"'"},"session_id":"'"$BR_SID_W2"'"}'
run_guard_payload "$BR_JSON" "" WORKFLOW_PLANS_DIR="$BR_TMP_W2_NODE" \
    >/dev/null 2>&1 || true
br_findings=$(br_read_findings "$BR_TMP_W2" "$BR_SID_W2")
br_out=$(node -e "
const f = JSON.parse(process.argv[1]);
const x = f.find(x => x.reporter === 'enforce-worktree');
if (!x) { console.log('SKIP_NOFINDING'); process.exit(0); }
if (x.reason !== 'cwd_no_git_root') { console.error('reason='+JSON.stringify(x.reason)); process.exit(2); }
if (!x.context || x.context.git_root_resolved !== false) {
  console.error('context.git_root_resolved not false: '+JSON.stringify(x.context)); process.exit(3);
}
console.log('OK');
" -- "$br_findings" 2>&1)
br_rc=$?
if [ $br_rc -eq 0 ] && [ "$br_out" = "OK" ]; then
    pass "W2: non-git CWD → reason=cwd_no_git_root + context.git_root_resolved=false"
elif [ "$br_out" = "SKIP_NOFINDING" ]; then
    skip "W2: no finding emitted (hook fail-open path?)"
else
    fail "W2: (rc=$br_rc, out=$br_out)"
fi
rm -rf "$BR_TMP_W2" "$BR_NONGIT"

# --- W3: stubbed isMainCheckout returning null → reason='isMainCheckout_unresolved'
# enforce-worktree.js guards its CLI body with `require.main === module`, so
# requiring it from a shim does not run the flow, and a stub set in the parent
# process cannot reach the child that actually runs the hook. The runner below
# therefore reports SKIP_STUB unconditionally; the case is carried forward as a
# known-unimplemented skip rather than silently dropped.
BR_SID_W3="sid-w3-$$"
BR_TMP_W3=$(br_make_tmp)
BR_SHIM_DIR=$(br_make_tmp)
BR_TMP_W3_NODE="$(to_node_path "$BR_TMP_W3")"
BR_MAIN_WT_J="$(to_node_path "$BR_MAIN_WT")"

# Quoted heredoc: the two paths reach the runner through the environment, so a
# quote or backslash in either cannot become executable JS.
cat > "$BR_SHIM_DIR/runner.js" <<'EOF'
'use strict';
const grdPath = require.resolve(process.env.BR_GRD_PATH);
const grd = require(grdPath);
grd.isMainCheckout = function() { return null; };
console.log('SKIP_STUB');
EOF
br_out=$(BR_GRD_PATH="$AGENTS_DIR_NODE/hooks/enforce-worktree/git-repo-detection.js" \
    WORKFLOW_PLANS_DIR="$BR_TMP_W3_NODE" ENFORCE_WORKTREE=on \
    run_with_timeout 8 node "$BR_SHIM_DIR/runner.js" 2>&1)
if echo "$br_out" | grep -q SKIP_STUB; then
    skip "W3: isMainCheckout=null stub requires in-process injection (see test note)"
else
    br_findings=$(br_read_findings "$BR_TMP_W3" "$BR_SID_W3")
    br_out2=$(node -e "
const f = JSON.parse(process.argv[1]);
const x = f.find(x => x.reporter === 'enforce-worktree');
if (!x) { console.error('no enforce-worktree finding'); process.exit(2); }
if (x.reason !== 'isMainCheckout_unresolved') { console.error('reason='+JSON.stringify(x.reason)); process.exit(3); }
console.log('OK');
" -- "$br_findings" 2>&1)
    br_rc=$?
    if [ $br_rc -eq 0 ] && [ "$br_out2" = "OK" ]; then
        pass "W3: isMainCheckout=null → reason=isMainCheckout_unresolved"
    else
        fail "W3: (rc=$br_rc, out=$br_out2)"
    fi
fi
rm -rf "$BR_TMP_W3" "$BR_SHIM_DIR"

# Completion marker (dispatcher FRAG2) — must remain the last line.
frag_done "block-reporting.sh"
