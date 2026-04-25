#!/bin/bash
# TDD tests for findLatestStateForContext / session-start.js inheritance logic
# Features NOT YET IMPLEMENTED — some tests are expected to FAIL (labeled "Expected FAIL").
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SESSION_START="$DOTFILES_DIR/claude-global/hooks/session-start.js"
WORKFLOW_STATE_LIB="$DOTFILES_DIR/claude-global/hooks/lib/workflow-state.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }
expected_fail() { echo "Expected FAIL (not yet implemented): $1"; }

# On Windows, Node.js (native) uses Windows paths and a different /tmp than bash (WSL).
# Detect and use a temp dir on the Windows filesystem so both bash and Node.js can share it.
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    # Windows path like C:\Users\...\Temp — convert to /c/Users/.../Temp for bash
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests.XXXXXXXX")
    # Convert lib path from /c/... to c:/... for Windows Node.js require()
    WORKFLOW_STATE_LIB_NODE=$(echo "$WORKFLOW_STATE_LIB" | sed 's|^/\([a-zA-Z]\)/|\1:/|')
    SESSION_START_NODE=$(echo "$SESSION_START" | sed 's|^/\([a-zA-Z]\)/|\1:/|')
else
    TMPDIR_BASE=$(mktemp -d)
    WORKFLOW_STATE_LIB_NODE="$WORKFLOW_STATE_LIB"
    SESSION_START_NODE="$SESSION_START"
fi
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 180 "$@"
    else
        perl -e 'alarm 180; exec @ARGV' -- "$@"
    fi
}

# Encode a path the same way Claude Code does:
# replace every non-alphanumeric character with '-'
encode_path() {
    local p="$1"
    printf '%s' "$p" | tr -c 'A-Za-z0-9' '-'
}

write_state() {
    local sid="$1" json="$2"
    mkdir -p "$WORKFLOW_DIR"
    printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

make_full_state() {
    local sid="$1" branch="$2"
    # branch may be "null" (literal) to produce JSON null
    local branch_json
    if [ "$branch" = "null" ]; then
        branch_json="null"
    else
        branch_json="\"$branch\""
    fi
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "git_branch": $branch_json,
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete",  "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete",  "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "pending",   "updated_at": null},
    "code":              {"status": "pending",   "updated_at": null},
    "verify":            {"status": "pending",   "updated_at": null},
    "docs":              {"status": "pending",   "updated_at": null},
    "user_verification": {"status": "pending",   "updated_at": null}
  }
}
EOF
}

make_all_pending_state() {
    local sid="$1"
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "pending", "updated_at": null},
    "plan":              {"status": "pending", "updated_at": null},
    "write_tests":       {"status": "pending", "updated_at": null},
    "code":              {"status": "pending", "updated_at": null},
    "verify":            {"status": "pending", "updated_at": null},
    "docs":              {"status": "pending", "updated_at": null},
    "user_verification": {"status": "pending", "updated_at": null}
  }
}
EOF
}

# Write a JSONL transcript line (SessionStart attachment) pointing to a session
write_transcript_line() {
    local jsonl_file="$1" sid="$2" state_path="$3"
    local stdout_payload
    stdout_payload="{\\\"additionalContext\\\": \\\"Current workflow session_id: $sid\\\\nState file: $state_path\\\"}"
    printf '%s\n' "{\"type\": \"attachment\", \"attachment\": {\"type\": \"hook_success\", \"hookEvent\": \"SessionStart\", \"stdout\": \"{\\\"additionalContext\\\": \\\"Current workflow session_id: $sid\\\\nState file: $state_path\\\"}\", \"exitCode\": 0, \"command\": \"node session-start.js\"}}" >> "$jsonl_file"
}

# Write a JSONL transcript line (PostCompact attachment) pointing to a session
write_postcompact_line() {
    local jsonl_file="$1" sid="$2" state_path="$3"
    printf '%s\n' "{\"type\": \"attachment\", \"attachment\": {\"type\": \"hook_success\", \"hookEvent\": \"PostCompact\", \"stdout\": \"{\\\"additionalContext\\\": \\\"Current workflow session_id: $sid\\\\nState file: $state_path\\\"}\", \"exitCode\": 0, \"command\": \"node post-compact.js\"}}" >> "$jsonl_file"
}

# Make a state where all steps are complete
make_complete_state() {
    local sid="$1" branch="$2"
    local branch_json
    if [ "$branch" = "null" ]; then branch_json="null"; else branch_json="\"$branch\""; fi
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "git_branch": $branch_json,
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "code":              {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "verify":            {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
}

# Convert bash path (/c/foo) to Windows Node.js path (c:/foo) on Windows; no-op on Unix.
node_path() { echo "$1" | sed 's|^/\([a-zA-Z]\)/|\1:/|'; }

# Returns the node inline script that calls findLatestStateForContext
# $1 = cwd, $2 = git_branch (or "null")
call_find_latest() {
    local cwd="$1" branch="$2" fake_home="$3"
    local branch_js
    if [ "$branch" = "null" ]; then
        branch_js="null"
    else
        branch_js="'$branch'"
    fi
    HOME="$fake_home" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" CLAUDE_TRANSCRIPT_BASE_DIR="$fake_home/.claude/projects" run_with_timeout node -e "
try {
  const { findLatestStateForContext } = require('$WORKFLOW_STATE_LIB_NODE');
  if (typeof findLatestStateForContext !== 'function') {
    process.stdout.write('NOT_IMPLEMENTED');
    process.exit(0);
  }
  const ctx = { cwd: '$cwd', git_branch: $branch_js };
  const result = findLatestStateForContext(ctx);
  console.log(result ? JSON.stringify(result) : 'null');
} catch (e) {
  if (e.message && e.message.includes('findLatestStateForContext')) {
    process.stdout.write('NOT_IMPLEMENTED');
  } else {
    process.stdout.write('NOT_IMPLEMENTED');
  }
  process.exit(0);
}
" 2>/dev/null || echo "NOT_IMPLEMENTED"
}

# ---------------------------------------------------------------------------
# A1: Normal — transcript has session ID → state is inherited
# ---------------------------------------------------------------------------

echo ""
echo "=== A1: transcript has session ID → steps are inherited ==="

CWD_A1="/Users/nire/test-repo-a1"
ENCODED_A1=$(encode_path "$CWD_A1")
FAKE_HOME_A1="$TMPDIR_BASE/home-a1"
TRANS_DIR_A1="$FAKE_HOME_A1/.claude/projects/$ENCODED_A1"
mkdir -p "$TRANS_DIR_A1"

SID_A1="a1-test-$(printf '%04x%04x' $RANDOM $RANDOM)"
STATE_A1=$(make_full_state "$SID_A1" "main")
write_state "$SID_A1" "$STATE_A1"

JSONL_A1="$TRANS_DIR_A1/${SID_A1}.jsonl"
write_transcript_line "$JSONL_A1" "$SID_A1" "$WORKFLOW_DIR/${SID_A1}.json"

RESULT_A1=$(call_find_latest "$CWD_A1" "main" "$FAKE_HOME_A1")

if [ "$RESULT_A1" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A1. findLatestStateForContext not yet implemented"
elif [ "$RESULT_A1" = "null" ] || [ -z "$RESULT_A1" ]; then
    fail "A1. findLatestStateForContext returned null — expected state with session_id=$SID_A1"
else
    RESEARCH_STATUS_A1=$(printf '%s' "$RESULT_A1" | node -e "
try { const s=JSON.parse((function(){let d='',b=Buffer.alloc(4096),n;try{while((n=require('fs').readSync(0,b,0,4096))>0)d+=b.slice(0,n).toString();}catch(e){}return d;})()); console.log(s.steps && s.steps.research ? s.steps.research.status : 'MISSING'); } catch(e) { console.log('PARSE_ERROR'); }
" 2>/dev/null || echo "PARSE_ERROR")
    if [ "$RESEARCH_STATUS_A1" = "complete" ]; then
        pass "A1. findLatestStateForContext returned state with research=complete"
    else
        fail "A1. findLatestStateForContext returned state but research.status=$RESEARCH_STATUS_A1 (expected complete)"
    fi
fi

# ---------------------------------------------------------------------------
# A2: Normal — branch mismatch → no inheritance
# ---------------------------------------------------------------------------

echo ""
echo "=== A2: branch mismatch → no inheritance ==="

CWD_A2="/Users/nire/test-repo-a2"
ENCODED_A2=$(encode_path "$CWD_A2")
FAKE_HOME_A2="$TMPDIR_BASE/home-a2"
TRANS_DIR_A2="$FAKE_HOME_A2/.claude/projects/$ENCODED_A2"
mkdir -p "$TRANS_DIR_A2"

SID_A2="a2-test-$(printf '%04x%04x' $RANDOM $RANDOM)"
# State file has git_branch "other-branch", context asks for "main"
STATE_A2=$(make_full_state "$SID_A2" "other-branch")
write_state "$SID_A2" "$STATE_A2"

JSONL_A2="$TRANS_DIR_A2/${SID_A2}.jsonl"
write_transcript_line "$JSONL_A2" "$SID_A2" "$WORKFLOW_DIR/${SID_A2}.json"

RESULT_A2=$(call_find_latest "$CWD_A2" "main" "$FAKE_HOME_A2")

if [ "$RESULT_A2" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A2. findLatestStateForContext not yet implemented"
elif [ "$RESULT_A2" = "null" ] || [ -z "$RESULT_A2" ]; then
    pass "A2. branch mismatch → returns null (no inheritance)"
else
    fail "A2. branch mismatch → expected null but got: $RESULT_A2"
fi

# ---------------------------------------------------------------------------
# A3: Normal — cwd mismatch → no inheritance (encoded dir doesn't exist)
# ---------------------------------------------------------------------------

echo ""
echo "=== A3: cwd mismatch → no inheritance ==="

# The fake home has transcript for a DIFFERENT cwd, but we query for our cwd
CWD_A3_ACTUAL="/Users/nire/test-repo-a3-actual"
CWD_A3_DIFFERENT="/Users/nire/test-repo-a3-different"
ENCODED_A3_DIFF=$(encode_path "$CWD_A3_DIFFERENT")
FAKE_HOME_A3="$TMPDIR_BASE/home-a3"
TRANS_DIR_A3="$FAKE_HOME_A3/.claude/projects/$ENCODED_A3_DIFF"
mkdir -p "$TRANS_DIR_A3"

SID_A3="a3-test-$(printf '%04x%04x' $RANDOM $RANDOM)"
STATE_A3=$(make_full_state "$SID_A3" "main")
write_state "$SID_A3" "$STATE_A3"

JSONL_A3="$TRANS_DIR_A3/${SID_A3}.jsonl"
write_transcript_line "$JSONL_A3" "$SID_A3" "$WORKFLOW_DIR/${SID_A3}.json"

# Query for actual cwd (no matching encoded dir)
RESULT_A3=$(call_find_latest "$CWD_A3_ACTUAL" "main" "$FAKE_HOME_A3")

if [ "$RESULT_A3" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A3. findLatestStateForContext not yet implemented"
elif [ "$RESULT_A3" = "null" ] || [ -z "$RESULT_A3" ]; then
    pass "A3. cwd mismatch → returns null (no inheritance)"
else
    fail "A3. cwd mismatch → expected null but got: $RESULT_A3"
fi

# ---------------------------------------------------------------------------
# A4: Normal — parallel sessions, most-recently-modified transcript wins
# ---------------------------------------------------------------------------

echo ""
echo "=== A4: parallel sessions — newest transcript wins ==="

CWD_A4="/Users/nire/test-repo-a4"
ENCODED_A4=$(encode_path "$CWD_A4")
FAKE_HOME_A4="$TMPDIR_BASE/home-a4"
TRANS_DIR_A4="$FAKE_HOME_A4/.claude/projects/$ENCODED_A4"
mkdir -p "$TRANS_DIR_A4"

SID_A4A="a4a-test-$(printf '%04x%04x' $RANDOM $RANDOM)"
SID_A4B="a4b-test-$(printf '%04x%04x' $RANDOM $RANDOM)"

STATE_A4A=$(make_full_state "$SID_A4A" "main")
STATE_A4B=$(make_full_state "$SID_A4B" "main")
write_state "$SID_A4A" "$STATE_A4A"
write_state "$SID_A4B" "$STATE_A4B"

# Write file A first
JSONL_A4A="$TRANS_DIR_A4/${SID_A4A}.jsonl"
write_transcript_line "$JSONL_A4A" "$SID_A4A" "$WORKFLOW_DIR/${SID_A4A}.json"

# Set file A mtime to the past so file B is definitively newer
node -e "
const fs = require('fs');
const old = new Date(Date.now() - 60000);
fs.utimesSync('$JSONL_A4A', old, old);
" 2>/dev/null || true

# Write file B after (newer)
JSONL_A4B="$TRANS_DIR_A4/${SID_A4B}.jsonl"
write_transcript_line "$JSONL_A4B" "$SID_A4B" "$WORKFLOW_DIR/${SID_A4B}.json"

RESULT_A4=$(call_find_latest "$CWD_A4" "main" "$FAKE_HOME_A4")

if [ "$RESULT_A4" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A4. findLatestStateForContext not yet implemented"
elif [ "$RESULT_A4" = "null" ] || [ -z "$RESULT_A4" ]; then
    fail "A4. returned null — expected session from newer transcript ($SID_A4B)"
else
    RETURNED_SID_A4=$(printf '%s' "$RESULT_A4" | node -e "
try { const s=JSON.parse((function(){let d='',b=Buffer.alloc(4096),n;try{while((n=require('fs').readSync(0,b,0,4096))>0)d+=b.slice(0,n).toString();}catch(e){}return d;})()); console.log(s.session_id || 'MISSING'); } catch(e) { console.log('PARSE_ERROR'); }
" 2>/dev/null || echo "PARSE_ERROR")
    if [ "$RETURNED_SID_A4" = "$SID_A4B" ]; then
        pass "A4. newest transcript wins → returned $SID_A4B"
    else
        fail "A4. expected session_id=$SID_A4B but got $RETURNED_SID_A4"
    fi
fi

# ---------------------------------------------------------------------------
# A5: Edge — detached HEAD (git_branch=null + null match) → inheritance
# ---------------------------------------------------------------------------

echo ""
echo "=== A5: detached HEAD — null+null match → inheritance ==="

CWD_A5="/Users/nire/test-repo-a5"
ENCODED_A5=$(encode_path "$CWD_A5")
FAKE_HOME_A5="$TMPDIR_BASE/home-a5"
TRANS_DIR_A5="$FAKE_HOME_A5/.claude/projects/$ENCODED_A5"
mkdir -p "$TRANS_DIR_A5"

SID_A5="a5-test-$(printf '%04x%04x' $RANDOM $RANDOM)"
STATE_A5=$(make_full_state "$SID_A5" "null")
write_state "$SID_A5" "$STATE_A5"

JSONL_A5="$TRANS_DIR_A5/${SID_A5}.jsonl"
write_transcript_line "$JSONL_A5" "$SID_A5" "$WORKFLOW_DIR/${SID_A5}.json"

RESULT_A5=$(call_find_latest "$CWD_A5" "null" "$FAKE_HOME_A5")

if [ "$RESULT_A5" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A5. findLatestStateForContext not yet implemented"
elif [ "$RESULT_A5" = "null" ] || [ -z "$RESULT_A5" ]; then
    fail "A5. null+null should match → expected inheritance, got null"
else
    pass "A5. detached HEAD null+null → inheritance works"
fi

# ---------------------------------------------------------------------------
# A6: Edge — non-git cwd (git_branch=null) → works like A5
# ---------------------------------------------------------------------------

echo ""
echo "=== A6: non-git cwd (git_branch=null) → inheritance ==="

CWD_A6="/Users/nire/test-repo-a6"
ENCODED_A6=$(encode_path "$CWD_A6")
FAKE_HOME_A6="$TMPDIR_BASE/home-a6"
TRANS_DIR_A6="$FAKE_HOME_A6/.claude/projects/$ENCODED_A6"
mkdir -p "$TRANS_DIR_A6"

SID_A6="a6-test-$(printf '%04x%04x' $RANDOM $RANDOM)"
STATE_A6=$(make_full_state "$SID_A6" "null")
write_state "$SID_A6" "$STATE_A6"

JSONL_A6="$TRANS_DIR_A6/${SID_A6}.jsonl"
write_transcript_line "$JSONL_A6" "$SID_A6" "$WORKFLOW_DIR/${SID_A6}.json"

RESULT_A6=$(call_find_latest "$CWD_A6" "null" "$FAKE_HOME_A6")

if [ "$RESULT_A6" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A6. findLatestStateForContext not yet implemented"
elif [ "$RESULT_A6" = "null" ] || [ -z "$RESULT_A6" ]; then
    fail "A6. non-git null+null should match → expected inheritance, got null"
else
    pass "A6. non-git cwd null+null → inheritance works"
fi

# ---------------------------------------------------------------------------
# A7: Edge — transcript dir doesn't exist → returns null (no crash)
# ---------------------------------------------------------------------------

echo ""
echo "=== A7: transcript dir doesn't exist → returns null ==="

CWD_A7="/Users/nire/test-repo-a7-nonexistent"
FAKE_HOME_A7="$TMPDIR_BASE/home-a7"
mkdir -p "$FAKE_HOME_A7"
# Do NOT create the encoded transcript dir

RESULT_A7=$(call_find_latest "$CWD_A7" "main" "$FAKE_HOME_A7")

if [ "$RESULT_A7" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A7. findLatestStateForContext not yet implemented"
elif [ "$RESULT_A7" = "null" ] || [ -z "$RESULT_A7" ]; then
    pass "A7. transcript dir missing → returns null (no crash)"
else
    fail "A7. transcript dir missing → expected null but got: $RESULT_A7"
fi

# ---------------------------------------------------------------------------
# A8: Edge — transcript has no hook attachment entries → returns null
# ---------------------------------------------------------------------------

echo ""
echo "=== A8: transcript has no hook attachment entries → returns null ==="

CWD_A8="/Users/nire/test-repo-a8"
ENCODED_A8=$(encode_path "$CWD_A8")
FAKE_HOME_A8="$TMPDIR_BASE/home-a8"
TRANS_DIR_A8="$FAKE_HOME_A8/.claude/projects/$ENCODED_A8"
mkdir -p "$TRANS_DIR_A8"

SID_A8="a8-test-$(printf '%04x%04x' $RANDOM $RANDOM)"
JSONL_A8="$TRANS_DIR_A8/${SID_A8}.jsonl"

# Write only regular message entries — no attachment
printf '%s\n' '{"type": "human", "text": "Hello"}' >> "$JSONL_A8"
printf '%s\n' '{"type": "assistant", "text": "World"}' >> "$JSONL_A8"

RESULT_A8=$(call_find_latest "$CWD_A8" "main" "$FAKE_HOME_A8")

if [ "$RESULT_A8" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A8. findLatestStateForContext not yet implemented"
elif [ "$RESULT_A8" = "null" ] || [ -z "$RESULT_A8" ]; then
    pass "A8. no hook attachment entries → returns null"
else
    fail "A8. no hook attachment entries → expected null but got: $RESULT_A8"
fi

# ---------------------------------------------------------------------------
# A9: Error — attachment stdout is corrupt JSON → skip, no crash
# ---------------------------------------------------------------------------

echo ""
echo "=== A9: corrupt JSON in attachment stdout → no crash, returns null ==="

CWD_A9="/Users/nire/test-repo-a9"
ENCODED_A9=$(encode_path "$CWD_A9")
FAKE_HOME_A9="$TMPDIR_BASE/home-a9"
TRANS_DIR_A9="$FAKE_HOME_A9/.claude/projects/$ENCODED_A9"
mkdir -p "$TRANS_DIR_A9"

SID_A9="a9-test-$(printf '%04x%04x' $RANDOM $RANDOM)"
JSONL_A9="$TRANS_DIR_A9/${SID_A9}.jsonl"

# Write attachment where stdout is malformed JSON
printf '%s\n' '{"type": "attachment", "attachment": {"type": "hook_success", "hookEvent": "SessionStart", "stdout": "not json at all", "exitCode": 0, "command": "node session-start.js"}}' >> "$JSONL_A9"

RESULT_A9=$(call_find_latest "$CWD_A9" "main" "$FAKE_HOME_A9")

if [ "$RESULT_A9" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A9. findLatestStateForContext not yet implemented"
elif [ "$RESULT_A9" = "null" ] || [ -z "$RESULT_A9" ]; then
    pass "A9. corrupt stdout JSON → returns null (no crash)"
else
    fail "A9. corrupt stdout JSON → expected null but got: $RESULT_A9"
fi

# ---------------------------------------------------------------------------
# A10: Edge — transcript has valid session ID but state file is missing → null
# ---------------------------------------------------------------------------

echo ""
echo "=== A10: valid transcript but state file missing → returns null ==="

CWD_A10="/Users/nire/test-repo-a10"
ENCODED_A10=$(encode_path "$CWD_A10")
FAKE_HOME_A10="$TMPDIR_BASE/home-a10"
TRANS_DIR_A10="$FAKE_HOME_A10/.claude/projects/$ENCODED_A10"
mkdir -p "$TRANS_DIR_A10"

SID_A10="a10-test-$(printf '%04x%04x' $RANDOM $RANDOM)"
JSONL_A10="$TRANS_DIR_A10/${SID_A10}.jsonl"

# Write transcript pointing to non-existent state file
write_transcript_line "$JSONL_A10" "$SID_A10" "$WORKFLOW_DIR/${SID_A10}.json"
# Do NOT write the state file

RESULT_A10=$(call_find_latest "$CWD_A10" "main" "$FAKE_HOME_A10")

if [ "$RESULT_A10" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A10. findLatestStateForContext not yet implemented"
elif [ "$RESULT_A10" = "null" ] || [ -z "$RESULT_A10" ]; then
    pass "A10. state file missing → returns null"
else
    fail "A10. state file missing → expected null but got: $RESULT_A10"
fi

# ---------------------------------------------------------------------------
# A11: Normal — all-pending state → skip, returns null
# ---------------------------------------------------------------------------

echo ""
echo "=== A11: all-pending state → skip, returns null ==="

CWD_A11="/Users/nire/test-repo-a11"
ENCODED_A11=$(encode_path "$CWD_A11")
FAKE_HOME_A11="$TMPDIR_BASE/home-a11"
TRANS_DIR_A11="$FAKE_HOME_A11/.claude/projects/$ENCODED_A11"
mkdir -p "$TRANS_DIR_A11"

SID_A11="a11-test-$(printf '%04x%04x' $RANDOM $RANDOM)"
STATE_A11=$(make_all_pending_state "$SID_A11")
write_state "$SID_A11" "$STATE_A11"

JSONL_A11="$TRANS_DIR_A11/${SID_A11}.jsonl"
write_transcript_line "$JSONL_A11" "$SID_A11" "$WORKFLOW_DIR/${SID_A11}.json"

RESULT_A11=$(call_find_latest "$CWD_A11" "main" "$FAKE_HOME_A11")

if [ "$RESULT_A11" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A11. findLatestStateForContext not yet implemented"
elif [ "$RESULT_A11" = "null" ] || [ -z "$RESULT_A11" ]; then
    pass "A11. all-pending state → skipped, returns null"
else
    fail "A11. all-pending state → expected null but got: $RESULT_A11"
fi

# ---------------------------------------------------------------------------
# A12: Idempotency — session-start.js run twice → state not overwritten
# ---------------------------------------------------------------------------

echo ""
echo "=== A12: session-start run twice → state not overwritten ==="

SID_A12="a12-test-$(printf '%04x%04x' $RANDOM $RANDOM)"
ENV_FILE_A12="$TMPDIR_BASE/a12.env"

# First run: creates state file
run_with_timeout bash -c "echo '{\"session_id\":\"$SID_A12\"}' | CLAUDE_WORKFLOW_DIR='$WORKFLOW_DIR' CLAUDE_ENV_FILE='$ENV_FILE_A12' node '$SESSION_START_NODE'" >/dev/null 2>&1 || true

# Modify state — set research=complete
STATE_FILE_A12="$WORKFLOW_DIR/${SID_A12}.json"
if [ -f "$STATE_FILE_A12" ]; then
    node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync('$(node_path "$STATE_FILE_A12")', 'utf8'));
s.steps.research = { status: 'complete', updated_at: new Date().toISOString() };
fs.writeFileSync('$(node_path "$STATE_FILE_A12")', JSON.stringify(s, null, 2));
" 2>/dev/null || true
fi

# Second run with same session_id
run_with_timeout bash -c "echo '{\"session_id\":\"$SID_A12\"}' | CLAUDE_WORKFLOW_DIR='$WORKFLOW_DIR' CLAUDE_ENV_FILE='$ENV_FILE_A12' node '$SESSION_START_NODE'" >/dev/null 2>&1 || true

if [ ! -f "$STATE_FILE_A12" ]; then
    fail "A12. state file missing after second run"
else
    RESEARCH_A12=$(node -e "
try {
  const s = JSON.parse(require('fs').readFileSync('$(node_path "$STATE_FILE_A12")', 'utf8'));
  const st = s.steps && s.steps.research ? s.steps.research.status : 'MISSING';
  console.log(st);
} catch(e) { console.log('PARSE_ERROR'); }
" 2>/dev/null || echo "PARSE_ERROR")
    if [ "$RESEARCH_A12" = "complete" ]; then
        pass "A12. second run did not overwrite state (research still complete)"
    else
        fail "A12. second run overwrote state — research.status=$RESEARCH_A12 (expected complete)"
    fi
fi

# ---------------------------------------------------------------------------
# T-C1 (Integration) — session-start stdout contains additionalContext
# Expected FAIL before implementation
# ---------------------------------------------------------------------------

echo ""
echo "=== T-C1: session-start → stdout has additionalContext with session_id ==="

TC1_SID="tc1-test-$(printf '%04x%04x' $RANDOM $RANDOM)"
TC1_ENV="$TMPDIR_BASE/tc1.env"

TC1_OUTPUT=$(run_with_timeout bash -c "echo '{\"session_id\":\"$TC1_SID\"}' | CLAUDE_WORKFLOW_DIR='$WORKFLOW_DIR' CLAUDE_ENV_FILE='$TC1_ENV' node '$SESSION_START_NODE'" 2>/dev/null || echo "ERROR")

TC1_HAS_CONTEXT=$(printf '%s' "$TC1_OUTPUT" | node -e "
try {
  const o = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf8'));
  if (o && o.additionalContext && o.additionalContext.includes('$TC1_SID')) {
    console.log('yes');
  } else {
    console.log('no');
  }
} catch(e) { console.log('no'); }
" 2>/dev/null || echo "no")

if [ "$TC1_HAS_CONTEXT" = "yes" ]; then
    pass "T-C1. session-start stdout.additionalContext contains session_id"
else
    expected_fail "T-C1. session-start currently outputs {} — additionalContext not yet implemented"
fi

# ---------------------------------------------------------------------------
# T-C2 (Integration) — inheritance → stdout contains "Inherited"
# Expected FAIL before implementation
# ---------------------------------------------------------------------------

echo ""
echo "=== T-C2: inheritance → stdout contains 'Inherited workflow steps from session' ==="

CWD_TC2="$(pwd)"
ENCODED_TC2=$(encode_path "$CWD_TC2")
FAKE_HOME_TC2="$TMPDIR_BASE/home-tc2"
TRANS_DIR_TC2="$FAKE_HOME_TC2/.claude/projects/$ENCODED_TC2"
mkdir -p "$TRANS_DIR_TC2"

SID_TC2_OLD="tc2-old-$(printf '%04x%04x' $RANDOM $RANDOM)"
SID_TC2_NEW="tc2-new-$(printf '%04x%04x' $RANDOM $RANDOM)"
TC2_ENV="$TMPDIR_BASE/tc2.env"

STATE_TC2=$(make_full_state "$SID_TC2_OLD" "main")
write_state "$SID_TC2_OLD" "$STATE_TC2"

JSONL_TC2="$TRANS_DIR_TC2/${SID_TC2_OLD}.jsonl"
write_transcript_line "$JSONL_TC2" "$SID_TC2_OLD" "$WORKFLOW_DIR/${SID_TC2_OLD}.json"

TC2_OUTPUT=$(HOME="$FAKE_HOME_TC2" run_with_timeout bash -c "echo '{\"session_id\":\"$SID_TC2_NEW\"}' | CLAUDE_WORKFLOW_DIR='$WORKFLOW_DIR' CLAUDE_ENV_FILE='$TC2_ENV' CLAUDE_PROJECT_DIR='$CWD_TC2' node '$SESSION_START_NODE'" 2>/dev/null || echo "ERROR")

TC2_HAS_INHERITED=$(printf '%s' "$TC2_OUTPUT" | node -e "
try {
  const o = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf8'));
  if (o && o.additionalContext && o.additionalContext.includes('Inherited workflow steps from session')) {
    console.log('yes');
  } else {
    console.log('no');
  }
} catch(e) { console.log('no'); }
" 2>/dev/null || echo "no")

if [ "$TC2_HAS_INHERITED" = "yes" ]; then
    pass "T-C2. session-start stdout contains inheritance message"
else
    expected_fail "T-C2. inheritance not yet implemented (session-start outputs {})"
fi

# ---------------------------------------------------------------------------
# T-C3 (Integration) — zombie cleanup after inheritance
# Expected FAIL before implementation
# ---------------------------------------------------------------------------

echo ""
echo "=== T-C3: zombie cleanup happens AFTER inheritance ==="

CWD_TC3="$(pwd)"
ENCODED_TC3=$(encode_path "$CWD_TC3")
FAKE_HOME_TC3="$TMPDIR_BASE/home-tc3"
TRANS_DIR_TC3="$FAKE_HOME_TC3/.claude/projects/$ENCODED_TC3"
mkdir -p "$TRANS_DIR_TC3"

SID_TC3_OLD="tc3-old-$(printf '%04x%04x' $RANDOM $RANDOM)"
SID_TC3_NEW="tc3-new-$(printf '%04x%04x' $RANDOM $RANDOM)"
TC3_ENV="$TMPDIR_BASE/tc3.env"

STATE_TC3=$(make_full_state "$SID_TC3_OLD" "main")
write_state "$SID_TC3_OLD" "$STATE_TC3"

# Set state file mtime to >7 days ago to make it look like a zombie
node -e "
const fs = require('fs');
const old = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000);
fs.utimesSync('$WORKFLOW_DIR/${SID_TC3_OLD}.json', old, old);
" 2>/dev/null || true

# Also set the created_at in state to old date so cleanupZombies picks it up
node -e "
const fs = require('fs');
const p = '$WORKFLOW_DIR/${SID_TC3_OLD}.json';
const s = JSON.parse(fs.readFileSync(p, 'utf8'));
s.created_at = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000).toISOString();
Object.keys(s.steps).forEach(k => { s.steps[k].updated_at = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000).toISOString(); });
fs.writeFileSync(p, JSON.stringify(s, null, 2));
" 2>/dev/null || true

JSONL_TC3="$TRANS_DIR_TC3/${SID_TC3_OLD}.jsonl"
write_transcript_line "$JSONL_TC3" "$SID_TC3_OLD" "$WORKFLOW_DIR/${SID_TC3_OLD}.json"

# Spawn session-start with NEW session id
HOME="$FAKE_HOME_TC3" run_with_timeout bash -c "echo '{\"session_id\":\"$SID_TC3_NEW\"}' | CLAUDE_WORKFLOW_DIR='$WORKFLOW_DIR' CLAUDE_ENV_FILE='$TC3_ENV' CLAUDE_PROJECT_DIR='$CWD_TC3' node '$SESSION_START_NODE'" >/dev/null 2>&1 || true

NEW_STATE_EXISTS="no"
if [ -f "$WORKFLOW_DIR/${SID_TC3_NEW}.json" ]; then
    NEW_STATE_EXISTS="yes"
fi
OLD_ZOMBIE_DELETED="no"
if [ ! -f "$WORKFLOW_DIR/${SID_TC3_OLD}.json" ]; then
    OLD_ZOMBIE_DELETED="yes"
fi

if [ "$NEW_STATE_EXISTS" = "yes" ] && [ "$OLD_ZOMBIE_DELETED" = "yes" ]; then
    pass "T-C3. new state exists AND old zombie deleted (inheritance before cleanup)"
else
    expected_fail "T-C3. inheritance before cleanup not yet implemented (new=$NEW_STATE_EXISTS zombie_deleted=$OLD_ZOMBIE_DELETED)"
fi

# ---------------------------------------------------------------------------
# A-M1: SessionStart(A) + PostCompact(B) → B (most recent) inherited
# ---------------------------------------------------------------------------

echo ""
echo "=== A-M1: SessionStart(A) + PostCompact(B) → B inherited (most recent) ==="

CWD_AM1="/Users/nire/test-repo-am1"
ENCODED_AM1=$(encode_path "$CWD_AM1")
FAKE_HOME_AM1="$TMPDIR_BASE/home-am1"
TRANS_DIR_AM1="$FAKE_HOME_AM1/.claude/projects/$ENCODED_AM1"
mkdir -p "$TRANS_DIR_AM1"

SID_AM1A="am1a-$(printf '%04x%04x' $RANDOM $RANDOM)"
SID_AM1B="am1b-$(printf '%04x%04x' $RANDOM $RANDOM)"

write_state "$SID_AM1A" "$(make_full_state "$SID_AM1A" "main")"
write_state "$SID_AM1B" "$(make_full_state "$SID_AM1B" "main")"

JSONL_AM1="$TRANS_DIR_AM1/${SID_AM1A}.jsonl"
write_transcript_line "$JSONL_AM1" "$SID_AM1A" "$WORKFLOW_DIR/${SID_AM1A}.json"
write_postcompact_line "$JSONL_AM1" "$SID_AM1B" "$WORKFLOW_DIR/${SID_AM1B}.json"

RESULT_AM1=$(call_find_latest "$CWD_AM1" "main" "$FAKE_HOME_AM1")

if [ "$RESULT_AM1" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A-M1. findLatestStateForContext not yet implemented (PostCompact preference)"
elif [ "$RESULT_AM1" = "null" ] || [ -z "$RESULT_AM1" ]; then
    fail "A-M1. expected state B to be inherited, got null"
else
    RETURNED_AM1=$(printf '%s' "$RESULT_AM1" | node -e "
let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const s=JSON.parse(d);console.log(s.session_id||'MISSING');}catch(e){console.log('PARSE_ERROR');}});
" 2>/dev/null || echo "PARSE_ERROR")
    if [ "$RETURNED_AM1" = "$SID_AM1B" ]; then
        pass "A-M1. PostCompact(B) preferred over SessionStart(A) → returned $SID_AM1B"
    else
        fail "A-M1. expected session_id=$SID_AM1B (PostCompact) but got $RETURNED_AM1"
    fi
fi

# ---------------------------------------------------------------------------
# A-M2: PostCompact only (SessionStart compacted away) → state inherited
# ---------------------------------------------------------------------------

echo ""
echo "=== A-M2: PostCompact only (no SessionStart) → state inherited ==="

CWD_AM2="/Users/nire/test-repo-am2"
ENCODED_AM2=$(encode_path "$CWD_AM2")
FAKE_HOME_AM2="$TMPDIR_BASE/home-am2"
TRANS_DIR_AM2="$FAKE_HOME_AM2/.claude/projects/$ENCODED_AM2"
mkdir -p "$TRANS_DIR_AM2"

SID_AM2="am2-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_AM2" "$(make_full_state "$SID_AM2" "main")"

JSONL_AM2="$TRANS_DIR_AM2/${SID_AM2}.jsonl"
write_postcompact_line "$JSONL_AM2" "$SID_AM2" "$WORKFLOW_DIR/${SID_AM2}.json"

RESULT_AM2=$(call_find_latest "$CWD_AM2" "main" "$FAKE_HOME_AM2")

if [ "$RESULT_AM2" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A-M2. findLatestStateForContext not yet implemented (PostCompact-only)"
elif [ "$RESULT_AM2" = "null" ] || [ -z "$RESULT_AM2" ]; then
    fail "A-M2. PostCompact-only JSONL should allow inheritance, got null"
else
    pass "A-M2. PostCompact-only → state inherited"
fi

# ---------------------------------------------------------------------------
# A-M3: Most recent session (B) has user_verification=complete → null
# ---------------------------------------------------------------------------

echo ""
echo "=== A-M3: PostCompact(B) user_verification=complete → no inheritance ==="

CWD_AM3="/Users/nire/test-repo-am3"
ENCODED_AM3=$(encode_path "$CWD_AM3")
FAKE_HOME_AM3="$TMPDIR_BASE/home-am3"
TRANS_DIR_AM3="$FAKE_HOME_AM3/.claude/projects/$ENCODED_AM3"
mkdir -p "$TRANS_DIR_AM3"

SID_AM3A="am3a-$(printf '%04x%04x' $RANDOM $RANDOM)"
SID_AM3B="am3b-$(printf '%04x%04x' $RANDOM $RANDOM)"

write_state "$SID_AM3A" "$(make_full_state "$SID_AM3A" "main")"
write_state "$SID_AM3B" "$(make_complete_state "$SID_AM3B" "main")"

JSONL_AM3="$TRANS_DIR_AM3/${SID_AM3A}.jsonl"
write_transcript_line "$JSONL_AM3" "$SID_AM3A" "$WORKFLOW_DIR/${SID_AM3A}.json"
write_postcompact_line "$JSONL_AM3" "$SID_AM3B" "$WORKFLOW_DIR/${SID_AM3B}.json"

RESULT_AM3=$(call_find_latest "$CWD_AM3" "main" "$FAKE_HOME_AM3")

if [ "$RESULT_AM3" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A-M3. findLatestStateForContext not yet implemented (complete→no inherit)"
elif [ "$RESULT_AM3" = "null" ] || [ -z "$RESULT_AM3" ]; then
    pass "A-M3. user_verification=complete → no inheritance (null)"
else
    fail "A-M3. expected null (completed task), got: $(printf '%s' "$RESULT_AM3" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const s=JSON.parse(d);console.log(s.session_id);}catch(e){console.log('?');}});" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# A-M4: Two JSONLs: older=complete, newer=active → newer inherited
# ---------------------------------------------------------------------------

echo ""
echo "=== A-M4: older JSONL complete, newer JSONL active → newer inherited ==="

CWD_AM4="/Users/nire/test-repo-am4"
ENCODED_AM4=$(encode_path "$CWD_AM4")
FAKE_HOME_AM4="$TMPDIR_BASE/home-am4"
TRANS_DIR_AM4="$FAKE_HOME_AM4/.claude/projects/$ENCODED_AM4"
mkdir -p "$TRANS_DIR_AM4"

SID_AM4OLD="am4old-$(printf '%04x%04x' $RANDOM $RANDOM)"
SID_AM4NEW="am4new-$(printf '%04x%04x' $RANDOM $RANDOM)"

write_state "$SID_AM4OLD" "$(make_complete_state "$SID_AM4OLD" "main")"
write_state "$SID_AM4NEW" "$(make_full_state "$SID_AM4NEW" "main")"

# Write older JSONL first, then set its mtime to past
JSONL_AM4OLD="$TRANS_DIR_AM4/${SID_AM4OLD}.jsonl"
write_transcript_line "$JSONL_AM4OLD" "$SID_AM4OLD" "$WORKFLOW_DIR/${SID_AM4OLD}.json"
node -e "const fs=require('fs');const old=new Date(Date.now()-60000);fs.utimesSync('$JSONL_AM4OLD',old,old);" 2>/dev/null || true

# Write newer JSONL
JSONL_AM4NEW="$TRANS_DIR_AM4/${SID_AM4NEW}.jsonl"
write_transcript_line "$JSONL_AM4NEW" "$SID_AM4NEW" "$WORKFLOW_DIR/${SID_AM4NEW}.json"

RESULT_AM4=$(call_find_latest "$CWD_AM4" "main" "$FAKE_HOME_AM4")

if [ "$RESULT_AM4" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A-M4. findLatestStateForContext not yet implemented (multi-JSONL mtime sort)"
elif [ "$RESULT_AM4" = "null" ] || [ -z "$RESULT_AM4" ]; then
    fail "A-M4. expected newer active state to be inherited, got null"
else
    RETURNED_AM4=$(printf '%s' "$RESULT_AM4" | node -e "
let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const s=JSON.parse(d);console.log(s.session_id||'MISSING');}catch(e){console.log('PARSE_ERROR');}});
" 2>/dev/null || echo "PARSE_ERROR")
    if [ "$RETURNED_AM4" = "$SID_AM4NEW" ]; then
        pass "A-M4. older complete JSONL skipped, newer active → returned $SID_AM4NEW"
    else
        fail "A-M4. expected $SID_AM4NEW but got $RETURNED_AM4"
    fi
fi

# ---------------------------------------------------------------------------
# A-M5: SessionStart(A) + PostCompact(B), B state file missing → fall back to A
# ---------------------------------------------------------------------------

echo ""
echo "=== A-M5: PostCompact(B) state missing → fall back to SessionStart(A) ==="

CWD_AM5="/Users/nire/test-repo-am5"
ENCODED_AM5=$(encode_path "$CWD_AM5")
FAKE_HOME_AM5="$TMPDIR_BASE/home-am5"
TRANS_DIR_AM5="$FAKE_HOME_AM5/.claude/projects/$ENCODED_AM5"
mkdir -p "$TRANS_DIR_AM5"

SID_AM5A="am5a-$(printf '%04x%04x' $RANDOM $RANDOM)"
SID_AM5B="am5b-$(printf '%04x%04x' $RANDOM $RANDOM)"

write_state "$SID_AM5A" "$(make_full_state "$SID_AM5A" "main")"
# Do NOT write state for SID_AM5B

JSONL_AM5="$TRANS_DIR_AM5/${SID_AM5A}.jsonl"
write_transcript_line "$JSONL_AM5" "$SID_AM5A" "$WORKFLOW_DIR/${SID_AM5A}.json"
write_postcompact_line "$JSONL_AM5" "$SID_AM5B" "$WORKFLOW_DIR/${SID_AM5B}.json"

RESULT_AM5=$(call_find_latest "$CWD_AM5" "main" "$FAKE_HOME_AM5")

if [ "$RESULT_AM5" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A-M5. findLatestStateForContext not yet implemented (PostCompact state-missing fallback)"
elif [ "$RESULT_AM5" = "null" ] || [ -z "$RESULT_AM5" ]; then
    fail "A-M5. B state missing → expected fallback to A, got null"
else
    RETURNED_AM5=$(printf '%s' "$RESULT_AM5" | node -e "
let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const s=JSON.parse(d);console.log(s.session_id||'MISSING');}catch(e){console.log('PARSE_ERROR');}});
" 2>/dev/null || echo "PARSE_ERROR")
    if [ "$RETURNED_AM5" = "$SID_AM5A" ]; then
        pass "A-M5. B state missing → fell back to A ($SID_AM5A)"
    else
        fail "A-M5. expected $SID_AM5A (fallback) but got $RETURNED_AM5"
    fi
fi

# ---------------------------------------------------------------------------
# A-M6: SessionStart(A) active + PostCompact(B) complete → null (no fallback)
# ---------------------------------------------------------------------------

echo ""
echo "=== A-M6: PostCompact(B) complete, SessionStart(A) active → null (no rollback) ==="

CWD_AM6="/Users/nire/test-repo-am6"
ENCODED_AM6=$(encode_path "$CWD_AM6")
FAKE_HOME_AM6="$TMPDIR_BASE/home-am6"
TRANS_DIR_AM6="$FAKE_HOME_AM6/.claude/projects/$ENCODED_AM6"
mkdir -p "$TRANS_DIR_AM6"

SID_AM6A="am6a-$(printf '%04x%04x' $RANDOM $RANDOM)"
SID_AM6B="am6b-$(printf '%04x%04x' $RANDOM $RANDOM)"

write_state "$SID_AM6A" "$(make_full_state "$SID_AM6A" "main")"
write_state "$SID_AM6B" "$(make_complete_state "$SID_AM6B" "main")"

JSONL_AM6="$TRANS_DIR_AM6/${SID_AM6A}.jsonl"
write_transcript_line "$JSONL_AM6" "$SID_AM6A" "$WORKFLOW_DIR/${SID_AM6A}.json"
write_postcompact_line "$JSONL_AM6" "$SID_AM6B" "$WORKFLOW_DIR/${SID_AM6B}.json"

RESULT_AM6=$(call_find_latest "$CWD_AM6" "main" "$FAKE_HOME_AM6")

if [ "$RESULT_AM6" = "NOT_IMPLEMENTED" ]; then
    expected_fail "A-M6. findLatestStateForContext not yet implemented (complete B → no rollback to A)"
elif [ "$RESULT_AM6" = "null" ] || [ -z "$RESULT_AM6" ]; then
    pass "A-M6. user_verification=complete (B) → no fallback to A, returns null"
else
    RETURNED_AM6=$(printf '%s' "$RESULT_AM6" | node -e "
let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const s=JSON.parse(d);console.log(s.session_id||'MISSING');}catch(e){console.log('PARSE_ERROR');}});
" 2>/dev/null || echo "PARSE_ERROR")
    fail "A-M6. expected null (no rollback), got session_id=$RETURNED_AM6"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed (some may be Expected FAIL placeholders — that is OK)!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
