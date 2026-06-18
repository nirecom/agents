# tests/feature-883-supervisor-guard-wsid/cases-g34-g41.sh
# Test case function definitions for G34-G41 (review-gap coverage).
# Invocations live in the dispatcher.

run_g34() {
    require_source "$HOOK" "G34: branch (5) all-null path — silent exit 0" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    # No state seeded, no WORKTREE_NOTES.md, empty transcript_path. session_id passes
    # the charset gate; all detection paths return null/false; falls through to (5).
    out=$(cd "$tmp" && echo '{"stop_hook_active":false,"session_id":"g34-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G34: branch (5) all-null path — silent exit 0"
    else
        fail "G34: branch (5) all-null path — silent exit 0 (rc=$rc, out=$out)"
    fi
}

run_g35() {
    require_source "$HOOK" "G35: l2_phase=done suppresses branch (3) despite l2_armed_at" || return
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="g35-sid"
    # l2_phase=done causes branch (3) condition l2Phase !== "done" to short-circuit.
    seed_state "$tmp" "$sid" "{ l2_armed_at: '2026-01-01T12:00:00Z', l2_phase: 'done', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G35: l2_phase=done suppresses branch (3) despite l2_armed_at"
    else
        fail "G35: l2_phase=done suppresses branch (3) despite l2_armed_at (rc=$rc, out=$out)"
    fi
}

run_g36() {
    require_source "$HOOK" "G36: l2_phase=frozen suppresses branch (3) despite l2_armed_at" || return
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="g36-sid"
    # G33 reaches frozen-on-threshold via retry count; G36 sets l2_phase=frozen directly.
    seed_state "$tmp" "$sid" "{ l2_armed_at: '2026-01-01T12:00:00Z', l2_phase: 'frozen', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G36: l2_phase=frozen suppresses branch (3) despite l2_armed_at"
    else
        fail "G36: l2_phase=frozen suppresses branch (3) despite l2_armed_at (rc=$rc, out=$out)"
    fi
}

run_g37() {
    require_source "$HOOK" "G37: SENTINEL_HANG_EXEMPT_STEPS — final_report does not trigger hang" || return
    local tmp out rc sid tmp_node transcript_path_native
    tmp="$(mktemp -d)"
    sid="g37-sid"
    if command -v cygpath >/dev/null 2>&1; then
        tmp_node="$(cygpath -m "$tmp")"
    else
        tmp_node="$tmp"
    fi
    transcript_path_native="$tmp_node/transcript.jsonl"
    # final_report is in SENTINEL_HANG_EXEMPT_STEPS — detectSentinelHang returns false.
    node -e '
const cmd = "echo \"<<WORKFLOW_MARK_STEP_final_report_complete>>\"";
const obj = {type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:cmd}}]}};
require("fs").writeFileSync(process.argv[1], JSON.stringify(obj)+"\n");
' "$transcript_path_native" 2>/dev/null
    # No state seeded; hangDetected=false, l2ArmedAt=null -> branch (3) condition false -> exit 0.
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"$transcript_path_native\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G37: SENTINEL_HANG_EXEMPT_STEPS — final_report does not trigger hang"
    else
        fail "G37: SENTINEL_HANG_EXEMPT_STEPS — final_report does not trigger hang (rc=$rc, out=$out)"
    fi
}

run_g38() {
    require_source "$HOOK" "G38: WORKTREE_ON after WORKTREE_OFF cancels C3 detection" || return
    local tmp out rc sid tmp_node transcript_path_native
    tmp="$(mktemp -d)"
    sid="g38-sid"
    if command -v cygpath >/dev/null 2>&1; then
        tmp_node="$(cygpath -m "$tmp")"
    else
        tmp_node="$tmp"
    fi
    transcript_path_native="$tmp_node/transcript.jsonl"
    # Two assistant turns: first WORKTREE_OFF, then WORKTREE_ON.
    # detectWorktreeOffProposal: lastOffIdx < lastOnIdx -> returns false.
    node -e '
const off = "echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: test reason>>\"";
const on  = "echo \"<<WORKFLOW_ENFORCE_WORKTREE_ON: done>>\"";
const a = {type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:off}}]}};
const b = {type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:on}}]}};
require("fs").writeFileSync(process.argv[1], JSON.stringify(a)+"\n"+JSON.stringify(b)+"\n");
' "$transcript_path_native" 2>/dev/null
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"$transcript_path_native\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G38: WORKTREE_ON after WORKTREE_OFF cancels C3 detection"
    else
        fail "G38: WORKTREE_ON after WORKTREE_OFF cancels C3 detection (rc=$rc, out=$out)"
    fi
}

run_g39() {
    require_source "$HOOK" "G39: AskUserQuestion suppresses C3 branch specifically" || return
    local tmp out rc sid tmp_node transcript_path_native
    tmp="$(mktemp -d)"
    sid="g39-sid"
    if command -v cygpath >/dev/null 2>&1; then
        tmp_node="$(cygpath -m "$tmp")"
    else
        tmp_node="$tmp"
    fi
    transcript_path_native="$tmp_node/transcript.jsonl"
    # Single assistant turn: first tool_use is WORKTREE_OFF Bash, last is AskUserQuestion.
    # detectWorktreeOffProposal -> true; detectAskUserQuestionTurn -> true.
    # Branch (C3) guarded by !askUserQuestionTurn -> suppressed.
    node -e '
const off = "echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: reason>>\"";
const obj = {type:"assistant",message:{content:[
  {type:"tool_use",name:"Bash",input:{command:off}},
  {type:"tool_use",name:"AskUserQuestion",input:{question:"?"}}
]}};
require("fs").writeFileSync(process.argv[1], JSON.stringify(obj)+"\n");
' "$transcript_path_native" 2>/dev/null
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"$transcript_path_native\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G39: AskUserQuestion suppresses C3 branch specifically"
    else
        fail "G39: AskUserQuestion suppresses C3 branch specifically (rc=$rc, out=$out)"
    fi
}

run_g40() {
    require_source "$HOOK" "G40: aggregateCategories deduplicates repeated category" || return
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="g40-sid"
    # Two findings sharing category "code". Dedup should output "code" once, not twice.
    seed_state "$tmp" "$sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [{\"categories\":[\"code\"],\"severity\":\"error\",\"detail\":\"finding1\",\"timestamp\":\"2026-01-01T12:00:00.000Z\"},{\"categories\":[\"code\",\"security\"],\"severity\":\"error\",\"detail\":\"finding2\",\"timestamp\":\"2026-01-01T12:00:00.000Z\"}] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "code" && ! echo "$out" | grep -q "code, code"; then
        pass "G40: aggregateCategories deduplicates repeated category"
    else
        fail "G40: aggregateCategories deduplicates repeated category (rc=$rc, out=$out)"
    fi
}

run_g41() {
    require_source "$HOOK" "G41: corrupt/empty state file — fail-open exit 0" || return
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="g41-sid"
    # Write an EMPTY file at the expected state path; readState() throws on JSON.parse("")
    # and the catch block in guard sets state=null. Branch (5) fires -> exit 0.
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
require('fs').writeFileSync(w.getStatePath('$sid'), '');
" >/dev/null 2>&1
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G41: corrupt/empty state file — fail-open exit 0"
    else
        fail "G41: corrupt/empty state file — fail-open exit 0 (rc=$rc, out=$out)"
    fi
}

run_g42() {
    require_source "$HOOK" "G42: cumSev=notice advisory path exits 0" || return
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="g42-sid"
    # cumulative_severity=notice hits the same advisory branch (4) as warning -> exit 0.
    seed_state "$tmp" "$sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: 'notice', findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G42: cumSev=notice advisory path exits 0"
    else
        fail "G42: cumSev=notice advisory path exits 0 (rc=$rc, out=$out)"
    fi
}

run_g43() {
    require_source "$HOOK" "G43: CC UUID state present — guard stays on CC UUID, no wsid fallback" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    local cc_uuid wsid
    cc_uuid="g43-cc-uuid"
    wsid="g43-wsid"
    # WORKTREE_NOTES.md supplies wsid so resolveWorkflowSessionId returns it.
    printf "Session-ID: %s\n" "$wsid" > "$tmp/WORKTREE_NOTES.md"
    # CC UUID state is non-null (cumSev=error with finding) -> resolver stays on CC UUID.
    seed_state "$tmp" "$cc_uuid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [{\"categories\":[\"code\"],\"severity\":\"error\",\"detail\":\"cc-uuid-finding\",\"timestamp\":\"2026-01-01T12:00:00.000Z\"}] }"
    # wsid state is empty (cumSev=null) — if resolver wrongly fell back, cumSev=null -> rc=0 (regression).
    seed_state "$tmp" "$wsid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$cc_uuid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "cc-uuid-finding"; then
        pass "G43: CC UUID state present — guard stays on CC UUID, no wsid fallback"
    else
        fail "G43: CC UUID state present — guard stays on CC UUID, no wsid fallback (rc=$rc, out=$out)"
    fi
}

run_g44() {
    require_source "$HOOK" "G44: isWorkflowOff active — guard exits 0 (early exit)" || return
    local tmp out rc sid wf_dir
    tmp="$(mktemp -d)"
    wf_dir="$(mktemp -d)"
    sid="g44-sid"
    # Seed state with l2_armed_at so branch (3) would normally fire (rc=2).
    seed_state "$tmp" "$sid" "{ l2_armed_at: '2026-01-01T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    # Create the .workflow-off marker file in CLAUDE_WORKFLOW_DIR so isWorkflowOff returns true.
    touch "$wf_dir/${sid}.workflow-off"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" CLAUDE_WORKFLOW_DIR="$wf_dir" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp" "$wf_dir"
    if [ $rc -eq 0 ]; then
        pass "G44: isWorkflowOff active — guard exits 0 (early exit)"
    else
        fail "G44: isWorkflowOff active — guard exits 0 (early exit) (rc=$rc, out=$out)"
    fi
}

run_g45() {
    require_source "$HOOK" "G45: C3 branch output contains WORKTREE_OFF-specific text" || return
    local tmp out rc sid tmp_node transcript_path_native
    tmp="$(mktemp -d)"
    sid="g45-sid"
    if command -v cygpath >/dev/null 2>&1; then
        tmp_node="$(cygpath -m "$tmp")"
    else
        tmp_node="$tmp"
    fi
    transcript_path_native="$tmp_node/transcript.jsonl"
    node -e '
const cmd = "echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: test reason>>\"";
const obj = {type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:cmd}}]}};
require("fs").writeFileSync(process.argv[1], JSON.stringify(obj)+"\n");
' "$transcript_path_native" 2>/dev/null
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"$transcript_path_native\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "C3: WORKTREE_OFF proposal pre-detected" && echo "$out" | grep -q "Action:"; then
        pass "G45: C3 branch output contains WORKTREE_OFF-specific text"
    else
        fail "G45: C3 branch output contains WORKTREE_OFF-specific text (rc=$rc, out=$out)"
    fi
}

run_g46() {
    require_source "$HOOK" "G46: cumSev=error multi-finding output has indexed [1] [2] lines" || return
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="g46-sid"
    seed_state "$tmp" "$sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [{\"categories\":[\"code\"],\"severity\":\"error\",\"detail\":\"first-finding\",\"timestamp\":\"2026-06-01T00:00:00.000Z\"},{\"categories\":[\"test\"],\"severity\":\"warning\",\"detail\":\"second-finding\",\"timestamp\":\"2026-06-01T00:00:01.000Z\"}] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "\[1\]" && echo "$out" | grep -q "\[2\]"; then
        pass "G46: cumSev=error multi-finding output has indexed [1] [2] lines"
    else
        fail "G46: cumSev=error multi-finding output has indexed [1] [2] lines (rc=$rc, out=$out)"
    fi
}

run_g47() {
    require_source "$HOOK" "G47: l2_armed_at without hang takes C2 path — output contains C2 label" || return
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="g47-sid"
    seed_state "$tmp" "$sid" "{ l2_armed_at: '2026-01-01T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "C2 scheduled review"; then
        pass "G47: l2_armed_at without hang takes C2 path — output contains C2 label"
    else
        fail "G47: l2_armed_at without hang takes C2 path — output contains C2 label (rc=$rc, out=$out)"
    fi
}

run_g48() {
    require_source "$HOOK" "G48: resolveWorkflowSessionId Priority 2 — CLAUDE_ENV_FILE → CLAUDE_SESSION_ID" || return
    require_wsid "G48: resolveWorkflowSessionId Priority 2 — CLAUDE_ENV_FILE → CLAUDE_SESSION_ID" || return
    local tmp env_file out rc sid wsid
    tmp="$(mktemp -d)"
    env_file="$(mktemp)"
    sid="g48-cc-uuid"
    wsid="g48-wsid-from-env"
    printf "CLAUDE_SESSION_ID=%s\n" "$wsid" > "$env_file"
    touch "$tmp/${wsid}-intent.md"
    seed_state "$tmp" "$wsid" "{ l2_armed_at: '2026-01-01T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    # No WORKTREE_NOTES.md — Priority 1 skips; Priority 2 picks wsid via CLAUDE_ENV_FILE.
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" CLAUDE_ENV_FILE="$env_file" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"; rm -f "$env_file"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "Workflow session ID: $wsid"; then
        pass "G48: resolveWorkflowSessionId Priority 2 — CLAUDE_ENV_FILE → CLAUDE_SESSION_ID"
    else
        fail "G48: resolveWorkflowSessionId Priority 2 — CLAUDE_ENV_FILE → CLAUDE_SESSION_ID (rc=$rc, out=$out)"
    fi
}

run_g49() {
    require_source "$HOOK" "G49: resolveWorkflowSessionId Priority 3 — depth-score wins highest-depth candidate" || return
    require_wsid "G49: resolveWorkflowSessionId Priority 3 — depth-score wins highest-depth candidate" || return
    local tmp out rc sid wsid_low wsid_high TODAY
    tmp="$(mktemp -d)"
    sid="g49-cc-uuid"
    TODAY=$(node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)
    wsid_low="${TODAY}-100000-g49low"
    wsid_high="${TODAY}-090000-g49high"
    # wsid_low: depth=1 (context.md + intent.md only); wsid_high: depth=2 (+ detail.md).
    touch "$tmp/${wsid_low}-context.md" "$tmp/${wsid_low}-intent.md"
    touch "$tmp/${wsid_high}-context.md" "$tmp/${wsid_high}-intent.md" "$tmp/${wsid_high}-detail.md"
    # State only under wsid_high — guard fires only if depth-sort selects it.
    seed_state "$tmp" "$wsid_high" "{ l2_armed_at: '2026-01-01T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "Workflow session ID: $wsid_high"; then
        pass "G49: resolveWorkflowSessionId Priority 3 — depth-score wins highest-depth candidate"
    else
        fail "G49: resolveWorkflowSessionId Priority 3 — depth-score wins highest-depth candidate (rc=$rc, out=$out)"
    fi
}

run_g50() {
    require_source "$HOOK" "G50: SENTINEL_HANG_EXEMPT_STEPS — pre_final_report_gate does not trigger hang" || return
    local tmp out rc sid tmp_node transcript_path_native
    tmp="$(mktemp -d)"
    sid="g50-sid"
    if command -v cygpath >/dev/null 2>&1; then
        tmp_node="$(cygpath -m "$tmp")"
    else
        tmp_node="$tmp"
    fi
    transcript_path_native="$tmp_node/transcript.jsonl"
    node -e '
const cmd = "echo \"<<WORKFLOW_MARK_STEP_pre_final_report_gate_complete>>\"";
const obj = {type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:cmd}}]}};
require("fs").writeFileSync(process.argv[1], JSON.stringify(obj)+"\n");
' "$transcript_path_native" 2>/dev/null
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"$transcript_path_native\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G50: SENTINEL_HANG_EXEMPT_STEPS — pre_final_report_gate does not trigger hang"
    else
        fail "G50: SENTINEL_HANG_EXEMPT_STEPS — pre_final_report_gate does not trigger hang (rc=$rc, out=$out)"
    fi
}
