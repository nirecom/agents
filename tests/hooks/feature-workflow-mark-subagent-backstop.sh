#!/usr/bin/env bash
# Tests: hooks/workflow-mark.js
# Tags: scope:issue-specific
# L2 tests for the workflow-mark.js isSubagentCall backstop (PostToolUse): for a
# subagent call, sentinel MARK_STEP processing is suppressed, but the push/merge
# user_verification reset still fires.
# L3 gap: whether Claude Code populates agent_id on a real subagent-issued Bash
# PostToolUse payload is only verifiable in a live `claude -p` session spawning a
# Task subagent; these L2 tests inject agent_id directly.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark.js"
ERRORS=0
PASS_COUNT=0

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Windows-compatible tmpdir
TMPDIR_ROOT="$(node -e "const os=require('os'),path=require('path'),fs=require('fs'),crypto=require('crypto');const d=path.join(os.tmpdir(),'wmback-'+crypto.randomBytes(6).toString('hex'));fs.mkdirSync(d,{recursive:true});process.stdout.write(d);")"
WORKFLOW_STATE_DIR="$TMPDIR_ROOT/workflow"
mkdir -p "$WORKFLOW_STATE_DIR"
export WORKFLOW_STATE_DIR
cleanup() { rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

# Plans-dir isolation (#1799): supervisor-emit must never write into the
# developer's real ~/.workflow-plans/. Pinned alongside WORKFLOW_STATE_DIR.
WORKFLOW_PLANS_DIR="$TMPDIR_ROOT/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR

NOW_ISO=$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }

# ---------------------------------------------------------------------------
# State helpers
# run_tests_status / user_verification_status are interpolated.
# ---------------------------------------------------------------------------
write_state() {
    local sid="$1" run_tests_status="$2" uv_status="$3"
    cat > "$WORKFLOW_STATE_DIR/${sid}.json" <<EOF
{"version":1,"session_id":"$sid","created_at":"$NOW_ISO","cwd":"/tmp","git_branch":"main","steps":{"clarify_intent":{"status":"complete","updated_at":"$NOW_ISO"},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"review_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"$run_tests_status","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"$uv_status","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}
EOF
}

# read_status <sid> <step> — emit the status string for a given step
read_status() {
    local sid="$1" step="$2"
    # Read through the canonical API: since #1733 `steps` is a PROJECTION over the
    # on-disk event stream, not a persisted top-level key.
    (cd "$SCRIPT_CHECKOUT_ROOT" && node -e "
        try {
            const s=require('./hooks/workflow-state').readState(process.argv[1]);
            process.stdout.write(((s&&s.steps&&s.steps[process.argv[2]])||{}).status||'MISSING');
        } catch(e){ process.stdout.write('ERR'); }
    " -- "$sid" "$step" 2>/dev/null) || true
}

# read_last_pushed_sha <sid>
read_last_pushed_sha() {
    local sid="$1"
    node -e "
        const fs=require('fs');
        try {
            const s=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
            process.stdout.write(s.last_pushed_sha||'');
        } catch(e){ process.stdout.write('ERR'); }
    " -- "$WORKFLOW_STATE_DIR/${sid}.json" 2>/dev/null || true
}

# run_hook <json> — pipe PostToolUse payload to workflow-mark.js
run_hook() {
    local json="$1"
    local input_file
    input_file="$(mktemp "$TMPDIR_ROOT/hook_input.XXXXXX")"
    printf '%s' "$json" > "$input_file"
    run_with_timeout node "$HOOK" < "$input_file" >/dev/null 2>&1 || true
    rm -f "$input_file"
}

assert_status() {
    local id="$1" desc="$2" sid="$3" step="$4" expected="$5"
    local actual
    actual=$(read_status "$sid" "$step")
    if [ "$actual" = "$expected" ]; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — expected ${step}=${expected}, got ${actual}"
    fi
}

# ===========================================================================
# TC1 — subagent + sentinel → state UNCHANGED (run_tests stays pending)
# ===========================================================================
echo ""
echo "=== TC1 — subagent sentinel suppressed ==="
SID="mark-tc1"
write_state "$SID" "pending" "pending"
run_hook '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_MARK_STEP_run_tests_complete>>\""},"tool_response":{"exit_code":0,"stdout":""},"session_id":"'"$SID"'","agent_id":"a1"}'
assert_status "TC1" "subagent + MARK_STEP sentinel → run_tests stays pending (backstop suppresses)" \
    "$SID" "run_tests" "pending"

# ===========================================================================
# TC2 — main + sentinel → state MUTATES (run_tests=complete) [regression guard]
# ===========================================================================
echo ""
echo "=== TC2 — main sentinel applies (regression) ==="
SID="mark-tc2"
write_state "$SID" "pending" "pending"
run_hook '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_MARK_STEP_run_tests_complete>>\""},"tool_response":{"exit_code":0,"stdout":""},"session_id":"'"$SID"'"}'
assert_status "TC2" "main (no agent_id) + MARK_STEP sentinel → run_tests=complete" \
    "$SID" "run_tests" "complete"

# ===========================================================================
# TC3 — C1 regression — subagent + git push origin main → user_verification reset
#        (push/merge block runs BEFORE the backstop, so it fires even for subagent)
# ===========================================================================
echo ""
echo "=== TC3 — subagent push still resets user_verification ==="
SID="mark-tc3"
write_state "$SID" "pending" "complete"
run_hook '{"tool_name":"Bash","tool_input":{"command":"git push origin main"},"tool_response":{"exit_code":0,"stdout":""},"session_id":"'"$SID"'","agent_id":"a1"}'
assert_status "TC3" "subagent + git push origin main → user_verification reset to pending" \
    "$SID" "user_verification" "pending"

# ===========================================================================
# TC4 — C1 regression — subagent + gh pr merge → user_verification reset
# ===========================================================================
echo ""
echo "=== TC4 — subagent gh pr merge still resets user_verification ==="
SID="mark-tc4"
write_state "$SID" "pending" "complete"
run_hook '{"tool_name":"Bash","tool_input":{"command":"gh pr merge --merge"},"tool_response":{"exit_code":0,"stdout":""},"session_id":"'"$SID"'","agent_id":"a1"}'
assert_status "TC4" "subagent + gh pr merge --merge → user_verification reset to pending" \
    "$SID" "user_verification" "pending"

# ===========================================================================
# TC5 — data gap — payload with NO agent_id field + sentinel → main treatment
#        (absent agent_id = false = main; state mutates) [fail-safe fallback]
# ===========================================================================
echo ""
echo "=== TC5 — data gap (absent agent_id = main) ==="
SID="mark-tc5"
write_state "$SID" "pending" "pending"
run_hook '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_MARK_STEP_run_tests_complete>>\""},"tool_response":{"exit_code":0,"stdout":""},"session_id":"'"$SID"'"}'
assert_status "TC5" "no agent_id field + MARK_STEP sentinel → run_tests=complete (fail-safe: absent=main)" \
    "$SID" "run_tests" "complete"

# ===========================================================================
# TC6 — error state — main + sentinel + exit_code 1 → run_tests stays pending
#        (workflow-mark.js exits early on non-zero exit_code without marking)
# ===========================================================================
echo ""
echo "=== TC6 — non-zero exit_code suppresses MARK_STEP ==="
SID="TC6_SID"
write_state "$SID" "pending" "pending"
run_hook '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_MARK_STEP_run_tests_complete>>\""},"tool_response":{"exit_code":1,"stdout":""},"session_id":"'"$SID"'"}'
assert_status "TC6" "main + MARK_STEP sentinel + exit_code 1 → run_tests stays pending (early exit on error)" \
    "$SID" "run_tests" "pending"

# ===========================================================================
# TC7 — gh pr merge --squash → user_verification reset
#        merge-detect.js uses /^\s*gh\s+pr\s+merge\b/ — any flags are accepted
# ===========================================================================
echo ""
echo "=== TC7 — gh pr merge --squash resets user_verification ==="
SID="mark-tc7"
write_state "$SID" "pending" "complete"
run_hook '{"tool_name":"Bash","tool_input":{"command":"gh pr merge --squash --delete-branch"},"tool_response":{"exit_code":0,"stdout":""},"session_id":"'"$SID"'"}'
assert_status "TC7" "gh pr merge --squash → user_verification reset to pending (any-flags detection)" \
    "$SID" "user_verification" "pending"

# ===========================================================================
# TC8 — gh pr merge --rebase → user_verification reset (same broad detection)
# ===========================================================================
echo ""
echo "=== TC8 — gh pr merge --rebase resets user_verification ==="
SID="mark-tc8"
write_state "$SID" "pending" "complete"
run_hook '{"tool_name":"Bash","tool_input":{"command":"gh pr merge --rebase"},"tool_response":{"exit_code":0,"stdout":""},"session_id":"'"$SID"'"}'
assert_status "TC8" "gh pr merge --rebase → user_verification reset to pending (any-flags detection)" \
    "$SID" "user_verification" "pending"

# ===========================================================================
# Results
# ===========================================================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS_COUNT + ERRORS))
echo "${PASS_COUNT}/${TOTAL} tests passed, ${ERRORS} failed"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "${ERRORS} test(s) failed"
    exit 1
fi
