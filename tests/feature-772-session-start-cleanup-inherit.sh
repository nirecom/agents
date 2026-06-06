#!/usr/bin/env bash
# filename: tests/feature-772-session-start-cleanup-inherit.sh
# Tests: hooks/session-start.js
# Tags: session-start, cleanup, inheritance, regression
#
# Regression tests for issue #772:
#   When a new session inherits workflow state from a prior session,
#   the `cleanup` step must NOT carry over verbatim. Instead, the new
#   session marks cleanup=skipped with skip_reason="inherited-from-prior-session"
#   because the cleanup belonged to the prior session's worktree/PR.
#
# RED: these tests fail against the unmodified session-start.js (which
# performs a verbatim deep-copy of steps including cleanup).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_START="$AGENTS_DIR/hooks/session-start.js"
GATE_HOOK="$AGENTS_DIR/hooks/workflow-gate.js"
WORKFLOW_STATE_LIB="$AGENTS_DIR/hooks/lib/workflow-state.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir shared between bash and Node.js
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests772.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Use a current timestamp so cleanupZombies(7) does not delete the prior state.
NOW_ISO=$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

encode_path() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '-'; }
to_node_path() { echo "$1" | sed 's|^/\([a-zA-Z]\)/|\1:/|'; }

setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM-$$"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    # Disable global core.hooksPath (points to agents/hooks pre-commit which
    # blocks commits from the main worktree). Per-repo override wins.
    git -C "$repo" config core.hooksPath ""
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial" --no-verify
    echo "$repo"
}

write_state_file() {
    local sid="$1" content="$2"
    printf '%s' "$content" > "$WORKFLOW_DIR/${sid}.json"
}

read_step_field() {
    local sid="$1" step="$2" field="$3"
    local f="$WORKFLOW_DIR/${sid}.json"
    [ ! -f "$f" ] && echo "MISSING" && return
    node -e "
try {
  const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const st = s.steps && s.steps['$step'];
  const v = st && st['$field'];
  if (v === undefined || v === null) { console.log(''); }
  else { console.log(String(v)); }
} catch (e) { console.log('MISSING'); }
" "$f" 2>/dev/null || echo "MISSING"
}

# Build a "prior session" state JSON with all main workflow steps complete
# and `cleanup` at the specified status.
prior_state_json() {
    local sid="$1" cleanup_status="$2"
    cat <<EOF
{
  "version": 1, "session_id": "$sid", "git_branch": "main",
  "created_at": "$NOW_ISO",
  "steps": {
    "research":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "outline":           {"status": "complete", "updated_at": "$NOW_ISO"},
    "detail":            {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":       {"status": "complete", "updated_at": "$NOW_ISO"},
    "review_security":   {"status": "complete", "updated_at": "$NOW_ISO"},
    "run_tests":         {"status": "complete", "updated_at": "$NOW_ISO"},
    "docs":              {"status": "complete", "updated_at": "$NOW_ISO"},
    "user_verification": {"status": "pending", "updated_at": null},
    "cleanup":           {"status": "$cleanup_status", "updated_at": "$NOW_ISO"}
  }
}
EOF
}

# Write a transcript line so findLatestStateForContext can discover the prior state.
write_transcript_line() {
    local jsonl_file="$1" sid="$2" state_path="$3"
    mkdir -p "$(dirname "$jsonl_file")"
    printf '%s\n' "{\"type\": \"attachment\", \"attachment\": {\"type\": \"hook_success\", \"hookEvent\": \"SessionStart\", \"stdout\": \"{\\\"additionalContext\\\": \\\"Current workflow session_id: $sid\\\\nState file: $state_path\\\"}\", \"exitCode\": 0, \"command\": \"node session-start.js\"}}" >> "$jsonl_file"
}

# Drive: simulate a NEW session starting (with NEW_SID) in a repo that has a
# prior session (PRIOR_SID) recorded in HOME transcript dir. After invocation
# the new session's state file should exist.
run_session_start_new() {
    local repo="$1" new_sid="$2" fake_home="$3"
    local env_file="$TMPDIR_BASE/env-${new_sid}.env"
    echo "{\"session_id\":\"$new_sid\"}" | \
        HOME="$fake_home" \
        CLAUDE_PROJECT_DIR="$repo" \
        CLAUDE_ENV_FILE="$env_file" \
        CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$(to_node_path "$fake_home/.claude/projects")" \
        run_with_timeout 30 node "$SESSION_START" >/dev/null 2>&1 || true
}

# Set up: prior session with given cleanup status, run new session-start,
# return path to new state file for reading.
# Args: <test_id> <prior_cleanup_status> [extra_prior_state_overrides_step] [override_status]
setup_prior_and_new() {
    local tid="$1" prior_cleanup="$2"
    PRIOR_SID="${tid}-prior-$(printf '%04x%04x' $RANDOM $RANDOM)"
    NEW_SID="${tid}-new-$(printf '%04x%04x' $RANDOM $RANDOM)"
    FAKE_HOME="$TMPDIR_BASE/home-${tid}"
    REPO="$(setup_repo)"
    # The cwd of getCurrentContext() will be REPO; the transcript dir is HOME/.claude/projects/<encoded-cwd>/
    local cwd_enc
    cwd_enc=$(encode_path "$(to_node_path "$REPO")")
    mkdir -p "$FAKE_HOME/.claude/projects/$cwd_enc"
    write_state_file "$PRIOR_SID" "$(prior_state_json "$PRIOR_SID" "$prior_cleanup")"
    write_transcript_line "$FAKE_HOME/.claude/projects/$cwd_enc/${PRIOR_SID}.jsonl" \
        "$PRIOR_SID" "$(to_node_path "$WORKFLOW_DIR/${PRIOR_SID}.json")"
}

# ============================================================================
# Normal cases — TDD: will fail until session-start.js is modified
# ============================================================================

# C1: Prior cleanup=complete → new session cleanup=skipped, skip_reason="inherited-from-prior-session"
setup_prior_and_new "c1" "complete"
run_session_start_new "$REPO" "$NEW_SID" "$FAKE_HOME"
CLEANUP_STATUS="$(read_step_field "$NEW_SID" "cleanup" "status")"
SKIP_REASON="$(read_step_field "$NEW_SID" "cleanup" "skip_reason")"
if [ "$CLEANUP_STATUS" = "skipped" ] && [ "$SKIP_REASON" = "inherited-from-prior-session" ]; then
    pass "C1: prior cleanup=complete → new cleanup=skipped + skip_reason=inherited-from-prior-session"
else
    fail "C1: expected cleanup=skipped + skip_reason=inherited-from-prior-session, got status=$CLEANUP_STATUS skip_reason=$SKIP_REASON"
fi

# C2: Prior cleanup=pending (the original bug — pending must be flipped to skipped too)
setup_prior_and_new "c2" "pending"
run_session_start_new "$REPO" "$NEW_SID" "$FAKE_HOME"
CLEANUP_STATUS="$(read_step_field "$NEW_SID" "cleanup" "status")"
if [ "$CLEANUP_STATUS" = "skipped" ]; then
    pass "C2: prior cleanup=pending → new cleanup=skipped (NOT pending)"
else
    fail "C2: expected cleanup=skipped, got status=$CLEANUP_STATUS"
fi

# ============================================================================
# Edge cases
# ============================================================================

# C3: Prior cleanup=in_progress → new session cleanup=skipped
setup_prior_and_new "c3" "in_progress"
run_session_start_new "$REPO" "$NEW_SID" "$FAKE_HOME"
CLEANUP_STATUS="$(read_step_field "$NEW_SID" "cleanup" "status")"
if [ "$CLEANUP_STATUS" = "skipped" ]; then
    pass "C3: prior cleanup=in_progress → new cleanup=skipped"
else
    fail "C3: expected cleanup=skipped, got status=$CLEANUP_STATUS"
fi

# C4: Other steps (research/outline/detail) inherited unchanged
setup_prior_and_new "c4" "complete"
run_session_start_new "$REPO" "$NEW_SID" "$FAKE_HOME"
RESEARCH="$(read_step_field "$NEW_SID" "research" "status")"
OUTLINE="$(read_step_field "$NEW_SID" "outline" "status")"
DETAIL="$(read_step_field "$NEW_SID" "detail" "status")"
if [ "$RESEARCH" = "complete" ] && [ "$OUTLINE" = "complete" ] && [ "$DETAIL" = "complete" ]; then
    pass "C4: other steps (research+outline+detail) inherited unchanged as complete"
else
    fail "C4: expected research=outline=detail=complete, got research=$RESEARCH outline=$OUTLINE detail=$DETAIL"
fi

# ============================================================================
# Regression gating — workflow-gate.js accepts commit when cleanup=skipped
# ============================================================================

# C5: workflow-gate.js does not block a commit when cleanup=skipped (not pending)
# Build a state where every step is complete except cleanup=skipped (inherited),
# then verify workflow-gate.js does not block a generic commit on that state.
C5_SID="c5-$(printf '%04x%04x' $RANDOM $RANDOM)"
C5_REPO="$(setup_repo)"
C5_STATE=$(cat <<EOF
{
  "version": 1, "session_id": "$C5_SID", "git_branch": "main",
  "created_at": "$NOW_ISO",
  "steps": {
    "research":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "outline":           {"status": "complete", "updated_at": "$NOW_ISO"},
    "detail":            {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":       {"status": "complete", "updated_at": "$NOW_ISO"},
    "review_security":   {"status": "complete", "updated_at": "$NOW_ISO"},
    "run_tests":         {"status": "complete", "updated_at": "$NOW_ISO"},
    "docs":              {"status": "complete", "updated_at": "$NOW_ISO"},
    "user_verification": {"status": "complete", "updated_at": "$NOW_ISO"},
    "cleanup":           {"status": "skipped",  "updated_at": "$NOW_ISO", "skip_reason": "inherited-from-prior-session"}
  }
}
EOF
)
write_state_file "$C5_SID" "$C5_STATE"
C5_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $C5_REPO commit -m test\"},\"session_id\":\"$C5_SID\"}"
C5_RESULT=$(echo "$C5_JSON" | CLAUDE_PROJECT_DIR="$C5_REPO" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
    run_with_timeout 30 node "$GATE_HOOK" 2>/dev/null || true)
# It should not block; either approve or empty (pass-through) is acceptable.
if echo "$C5_RESULT" | grep -q '"block"'; then
    fail "C5: workflow-gate.js BLOCKED commit when cleanup=skipped — should approve. Result: $C5_RESULT"
else
    pass "C5: workflow-gate.js accepts commit when cleanup=skipped (not blocked)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
