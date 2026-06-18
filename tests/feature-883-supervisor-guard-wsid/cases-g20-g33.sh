# tests/feature-883-supervisor-guard-wsid/cases-g20-g33.sh
# Test case function definitions for G20-G33. Invocations live in the dispatcher.

run_g20() {
    require_source "$HOOK" "G20: wsid injected into block-reason when context.md present" || return
    require_wsid "G20: wsid injected into block-reason when context.md present" || return
    local tmp out rc wsid sid TODAY
    tmp="$(mktemp -d)"
    sid="g20-sid"
    TODAY=$(node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)
    wsid="${TODAY}-g20wsid"
    # Priority 1 (WORKTREE_NOTES.md) supplies wsid when running from $tmp.
    printf "Session-ID: %s\n" "$wsid" > "$tmp/WORKTREE_NOTES.md"
    # Seed supervisor state with l2_armed_at non-null to trigger branch (3).
    seed_state "$tmp" "$sid" "{ l2_armed_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "Session ID: $sid" && echo "$out" | grep -q "Workflow session ID: $wsid"; then
        pass "G20: wsid injected into block-reason when context.md present"
    else
        fail "G20: wsid injected into block-reason when context.md present (rc=$rc, out=$out)"
    fi
}

run_g21() {
    require_source "$HOOK" "G21: wsid=UNAVAILABLE when no context.md in plans-dir" || return
    require_wsid "G21: wsid=UNAVAILABLE when no context.md in plans-dir" || return
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="g21-sid"
    # No WORKTREE_NOTES.md, no context.md in tmp — resolveWorkflowSessionId returns null -> UNAVAILABLE.
    # Running from $tmp ensures the repo's own WORKTREE_NOTES.md in CWD does not interfere.
    seed_state "$tmp" "$sid" "{ l2_armed_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "Workflow session ID: UNAVAILABLE"; then
        pass "G21: wsid=UNAVAILABLE when no context.md in plans-dir"
    else
        fail "G21: wsid=UNAVAILABLE when no context.md in plans-dir (rc=$rc, out=$out)"
    fi
}

run_g22() {
    require_source "$HOOK" "G22: cumulative_severity=error path shows Workflow session ID in systemMessage" || return
    require_wsid "G22: cumulative_severity=error path shows Workflow session ID" || return
    local tmp out rc wsid sid TODAY
    tmp="$(mktemp -d)"
    sid="g22-sid"
    TODAY=$(node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)
    wsid="${TODAY}-g22wsid"
    # Priority 1 (WORKTREE_NOTES.md) supplies wsid when running from $tmp.
    printf "Session-ID: %s\n" "$wsid" > "$tmp/WORKTREE_NOTES.md"
    # cumulative_severity=error triggers branch (2)
    seed_state "$tmp" "$sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [{\"categories\":[\"code\"],\"severity\":\"error\",\"detail\":\"test-finding\",\"timestamp\":\"2026-06-06T12:00:00.000Z\"}] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "systemMessage" && echo "$out" | grep -q "Workflow session ID: $wsid"; then
        pass "G22: cumulative_severity=error path shows Workflow session ID in systemMessage"
    else
        fail "G22: cumulative_severity=error path shows Workflow session ID in systemMessage (rc=$rc, out=$out)"
    fi
}

run_g23() {
    require_source "$HOOK" "G23: cross-ID dual-ID fallback — guard fires + freeze counter on wsid file" || return
    require_wsid "G23: cross-ID dual-ID fallback — guard fires + freeze counter on wsid file" || return
    local tmp out rc wsid ccuuid wsid_state_path ccuuid_state_path wsid_retry
    tmp="$(mktemp -d)"
    wsid="20260101-120000-g23wsid"
    ccuuid="g23-cc-uuid-different"
    # Priority 1 (WORKTREE_NOTES.md) supplies wsid when running from $tmp.
    printf "Session-ID: %s\n" "$wsid" > "$tmp/WORKTREE_NOTES.md"
    # Seed supervisor state under the WSID key (not the CC UUID) — simulates
    # the case where Layer-1 wrote state keyed by workflow session id but the
    # Stop hook receives a different CC UUID (dual-ID fallback regression).
    seed_state "$tmp" "$wsid" "{ l2_armed_at: '2026-01-01T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    # Invoke guard with session_id = ccuuid (CC UUID, different from wsid).
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$ccuuid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    # Translate $tmp for Node.js on Windows (MSYS path translation asymmetry)
    if command -v cygpath >/dev/null 2>&1; then
        _tmp_node="$(cygpath -m "$tmp")"
    else
        _tmp_node="$tmp"
    fi
    wsid_state_path="$_tmp_node/${wsid}-supervisor-state.json"
    ccuuid_state_path="$_tmp_node/${ccuuid}-supervisor-state.json"
    # Read retry count from wsid file (proves the fix routes writes through the effective ID).
    wsid_retry=$(node -e "try{const s=JSON.parse(require('fs').readFileSync('$wsid_state_path','utf8')); process.stdout.write(String(s.layer2?.l2_retry_count??0));}catch(_){process.stdout.write('err');}" 2>/dev/null)
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && [ "$wsid_retry" != "0" ] && [ "$wsid_retry" != "err" ]; then
        pass "G23: cross-ID dual-ID fallback — guard fires + freeze counter on wsid file"
    else
        fail "G23: cross-ID dual-ID fallback — guard fires + freeze counter on wsid file (rc=$rc, wsid_retry=$wsid_retry)"
    fi
}

run_g24() {
    require_source "$HOOK" "G24: C3 WORKTREE_OFF proposal — wsid injected into block reason" || return
    require_wsid "G24: C3 WORKTREE_OFF proposal — wsid injected into block reason" || return
    local tmp out rc wsid sid TODAY transcript_path_native tmp_node
    tmp="$(mktemp -d)"
    sid="g24-sid"
    TODAY=$(node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)
    wsid="${TODAY}-g24wsid"
    printf "Session-ID: %s\n" "$wsid" > "$tmp/WORKTREE_NOTES.md"
    if command -v cygpath >/dev/null 2>&1; then
        tmp_node="$(cygpath -m "$tmp")"
    else
        tmp_node="$tmp"
    fi
    transcript_path_native="$tmp_node/transcript.jsonl"
    # Build a transcript with an assistant Bash tool_use containing the WORKTREE_OFF sentinel.
    node -e '
const cmd = "echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: test reason>>\"";
const obj = {type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:cmd}}]}};
require("fs").writeFileSync(process.argv[1], JSON.stringify(obj)+"\n");
' "$transcript_path_native" 2>/dev/null
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"$transcript_path_native\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "Workflow session ID: $wsid"; then
        pass "G24: C3 WORKTREE_OFF proposal — wsid injected into block reason"
    else
        fail "G24: C3 WORKTREE_OFF proposal — wsid injected into block reason (rc=$rc, out=$out)"
    fi
}

run_g25() {
    require_source "$HOOK" "G25: workflowSessionId === sessionId — guard fires via sessionId" || return
    require_wsid "G25: workflowSessionId === sessionId — guard fires via sessionId" || return
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="g25-sid"
    # wsid same as sessionId — resolver must skip fallback path.
    printf "Session-ID: %s\n" "$sid" > "$tmp/WORKTREE_NOTES.md"
    seed_state "$tmp" "$sid" "{ l2_armed_at: '2026-01-01T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "Session ID: $sid"; then
        pass "G25: workflowSessionId === sessionId — guard fires via sessionId"
    else
        fail "G25: workflowSessionId === sessionId — guard fires via sessionId (rc=$rc, out=$out)"
    fi
}

run_g26() {
    require_source "$HOOK" "G26: invalid-charset wsid — falls back to sessionId and fires" || return
    require_wsid "G26: invalid-charset wsid — falls back to sessionId and fires" || return
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="g26-sid"
    # The Session-ID line uses chars outside [A-Za-z0-9_-], so resolveWorkflowSessionId
    # rejects it via the regex inside _readSessionIdFromWorktreeNotes. The resolver in
    # supervisor-guard.js then skips fallback and uses sessionId for state lookup.
    printf "Session-ID: %s\n" "invalid@charset!" > "$tmp/WORKTREE_NOTES.md"
    seed_state "$tmp" "$sid" "{ l2_armed_at: '2026-01-01T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ]; then
        pass "G26: invalid-charset wsid — falls back to sessionId and fires"
    else
        fail "G26: invalid-charset wsid — falls back to sessionId and fires (rc=$rc, out=$out)"
    fi
}

run_g27() {
    require_source "$HOOK" "G27: sessionId with shell metacharacter — guard exits 0 (fail-open)" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    # session_id = "foo;bar" — contains ';' so the charset gate at line 211 rejects it.
    # Build the JSON via node to avoid bash interpolation hazards.
    local json
    json=$(node -e 'process.stdout.write(JSON.stringify({stop_hook_active:false,session_id:"foo;bar",transcript_path:""}))' 2>/dev/null)
    out=$(cd "$tmp" && printf '%s' "$json" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G27: sessionId with shell metacharacter — guard exits 0 (fail-open)"
    else
        fail "G27: sessionId with shell metacharacter — guard exits 0 (fail-open) (rc=$rc, out=$out)"
    fi
}

run_g28() {
    require_source "$HOOK" "G28: cumSev=error with empty findings — formatCumSevErrorReason empty path" || return
    require_wsid "G28: cumSev=error with empty findings — formatCumSevErrorReason empty path" || return
    local tmp out rc wsid sid TODAY
    tmp="$(mktemp -d)"
    sid="g28-sid"
    TODAY=$(node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)
    wsid="${TODAY}-g28wsid"
    printf "Session-ID: %s\n" "$wsid" > "$tmp/WORKTREE_NOTES.md"
    # cumulative_severity=error with empty findings triggers formatCumSevErrorReason empty-findings branch
    seed_state "$tmp" "$sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "systemMessage" && echo "$out" | grep -q "(no findings recorded)" && echo "$out" | grep -q "Workflow session ID: $wsid"; then
        pass "G28: cumSev=error with empty findings — formatCumSevErrorReason empty path"
    else
        fail "G28: cumSev=error with empty findings — formatCumSevErrorReason empty path (rc=$rc, out=$out)"
    fi
}

run_g29() {
    require_source "$HOOK" "G29: cumSev=warning advisory path exits 0 (non-blocking)" || return
    require_wsid "G29: cumSev=warning advisory path exits 0 (non-blocking)" || return
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="g29-sid"
    # cumulative_severity=warning with l2_armed_at=null triggers branch (4) advisory path
    seed_state "$tmp" "$sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: 'warning', findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G29: cumSev=warning advisory path exits 0 (non-blocking)"
    else
        fail "G29: cumSev=warning advisory path exits 0 (non-blocking) (rc=$rc, out=$out)"
    fi
}

run_g30() {
    require_source "$HOOK" "G30: stop_hook_active=true exits 0 immediately (branch 1)" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    # No state seeded, no WORKTREE_NOTES.md — branch (1) fires first at line 184.
    out=$(cd "$tmp" && echo '{"stop_hook_active":true,"session_id":"g30-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G30: stop_hook_active=true exits 0 immediately (branch 1)"
    else
        fail "G30: stop_hook_active=true exits 0 immediately (branch 1) (rc=$rc, out=$out)"
    fi
}

run_g31() {
    require_source "$HOOK" "G31: AskUserQuestion as last tool_use suppresses C3/2/3 block branches" || return
    require_wsid "G31: AskUserQuestion as last tool_use suppresses C3/2/3 block branches" || return
    local tmp out rc sid tmp_node transcript_path_native
    tmp="$(mktemp -d)"
    sid="g31-sid"
    if command -v cygpath >/dev/null 2>&1; then
        tmp_node="$(cygpath -m "$tmp")"
    else
        tmp_node="$tmp"
    fi
    transcript_path_native="$tmp_node/transcript.jsonl"
    # Build transcript where last tool_use is AskUserQuestion.
    node -e '
const obj = {type:"assistant",message:{content:[{type:"tool_use",name:"AskUserQuestion",input:{question:"?"}}]}};
require("fs").writeFileSync(process.argv[1], JSON.stringify(obj)+"\n");
' "$transcript_path_native" 2>/dev/null
    # Seed l2_armed_at so branch (3) would normally fire.
    seed_state "$tmp" "$sid" "{ l2_armed_at: '2026-01-01T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"$transcript_path_native\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G31: AskUserQuestion as last tool_use suppresses C3/2/3 block branches"
    else
        fail "G31: AskUserQuestion as last tool_use suppresses C3/2/3 block branches (rc=$rc, out=$out)"
    fi
}

run_g32() {
    require_source "$HOOK" "G32: C1 sentinel hang in transcript blocks with C1 label in reason" || return
    local tmp out rc sid tmp_node transcript_path_native
    tmp="$(mktemp -d)"
    sid="g32-sid"
    if command -v cygpath >/dev/null 2>&1; then
        tmp_node="$(cygpath -m "$tmp")"
    else
        tmp_node="$tmp"
    fi
    transcript_path_native="$tmp_node/transcript.jsonl"
    # Build transcript with a MARK_STEP Bash tool_use as the last tool_use (no tool_use follows).
    node -e '
const cmd = "echo \"<<WORKFLOW_MARK_STEP_write_code_complete>>\"";
const obj = {type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:cmd}}]}};
require("fs").writeFileSync(process.argv[1], JSON.stringify(obj)+"\n");
' "$transcript_path_native" 2>/dev/null
    # No state seeded: l2ArmedAt=null, cumSev=null — detectSentinelHang returns true triggering branch (3).
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"$transcript_path_native\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "C1"; then
        pass "G32: C1 sentinel hang in transcript blocks with C1 label in reason"
    else
        fail "G32: C1 sentinel hang in transcript blocks with C1 label in reason (rc=$rc, out=$out)"
    fi
}

run_g33() {
    require_source "$HOOK" "G33: frozen state (l2_retry_count at threshold) exits 0" || return
    require_wsid "G33: frozen state (l2_retry_count at threshold) exits 0" || return
    local tmp out rc sid tmp_node
    tmp="$(mktemp -d)"
    sid="g33-sid"
    if command -v cygpath >/dev/null 2>&1; then
        tmp_node="$(cygpath -m "$tmp")"
    else
        tmp_node="$tmp"
    fi
    # Seed state with l2_retry_count=2 (at threshold) — incrementL2RetryCount returns frozen=true.
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.layer2 = { l2_armed_at: '2026-01-01T12:00:00Z', l2_retry_count: 2, last_run_at: null, cumulative_severity: null, findings: [] };
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G33: frozen state (l2_retry_count at threshold) exits 0"
    else
        fail "G33: frozen state (l2_retry_count at threshold) exits 0 (rc=$rc, out=$out)"
    fi
}
