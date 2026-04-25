#!/bin/bash
# Integration regression tests for the Workflow State Machine.
# Covers: state inheritance, cross-repo commits, RESET_FROM, USER_VERIFIED,
# branch isolation, and structure smoke tests.
# Usage: bash tests/main-workflow-state-machine.sh
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_HOOK="$DOTFILES_DIR/claude-global/hooks/workflow-gate.js"
MARK_HOOK="$DOTFILES_DIR/claude-global/hooks/workflow-mark.js"
SESSION_START="$DOTFILES_DIR/claude-global/hooks/session-start.js"
WORKFLOW_STATE_LIB="$DOTFILES_DIR/claude-global/hooks/lib/workflow-state.js"
SETTINGS="$DOTFILES_DIR/claude-global/settings.json"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
    else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir: Node.js and bash must share the same filesystem path
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests.XXXXXXXX")
    WORKFLOW_STATE_LIB_NODE=$(echo "$WORKFLOW_STATE_LIB" | sed 's|^/\([a-zA-Z]\)/|\1:/|')
else
    TMPDIR_BASE=$(mktemp -d)
    WORKFLOW_STATE_LIB_NODE="$WORKFLOW_STATE_LIB"
fi
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Current timestamp for states that session-start may encounter (avoids cleanupZombies deletion)
NOW_ISO=$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

write_state() {
    local sid="$1" json="$2"
    mkdir -p "$WORKFLOW_DIR"
    printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

# Convert bash-style /c/... path to Node.js-compatible c:/... path
to_node_path() {
    echo "$1" | sed 's|^/\([a-zA-Z]\)/|\1:/|'
}

encode_path() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9' '-'
}

ALL_COMPLETE_JSON() {
    local sid="${1:-test-session}" branch="${2:-main}"
    local branch_json
    if [ "$branch" = "null" ]; then branch_json="null"; else branch_json="\"$branch\""; fi
    cat <<EOF
{
  "version": 1, "session_id": "$sid", "git_branch": $branch_json,
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
}

ALL_PENDING_JSON() {
    local sid="${1:-test-session}" branch="${2:-main}"
    local branch_json
    if [ "$branch" = "null" ]; then branch_json="null"; else branch_json="\"$branch\""; fi
    cat <<EOF
{
  "version": 1, "session_id": "$sid", "git_branch": $branch_json,
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "pending", "updated_at": null},
    "plan":              {"status": "pending", "updated_at": null},
    "write_tests":       {"status": "pending", "updated_at": null},
    "review_security":   {"status": "pending", "updated_at": null},
    "run_tests":         {"status": "pending", "updated_at": null},
    "docs":              {"status": "pending", "updated_at": null},
    "user_verification": {"status": "pending", "updated_at": null}
  }
}
EOF
}

# State with research+plan complete; rest pending. Uses NOW_ISO to survive cleanupZombies.
INHERIT_STATE_JSON() {
    local sid="$1" branch="${2:-main}"
    local branch_json
    if [ "$branch" = "null" ]; then branch_json="null"; else branch_json="\"$branch\""; fi
    cat <<EOF
{
  "version": 1, "session_id": "$sid", "git_branch": $branch_json,
  "created_at": "$NOW_ISO",
  "steps": {
    "research":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "plan":              {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null}
  }
}
EOF
}

run_gate() {
    local repo="$1" json="$2"
    echo "$json" | CLAUDE_PROJECT_DIR="$repo" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        node "$GATE_HOOK" 2>/dev/null || true
}

expect_approve_gate() {
    local desc="$1" repo="$2" json="$3"
    local result
    result=$(run_gate "$repo" "$json")
    if echo "$result" | grep -q '"approve"'; then pass "$desc"
    else fail "$desc — expected approve, got: $result"; fi
}

expect_block_gate() {
    local desc="$1" repo="$2" json="$3"
    local result
    result=$(run_gate "$repo" "$json")
    if echo "$result" | grep -q '"block"'; then pass "$desc"
    else fail "$desc — expected block, got: $result"; fi
}

expect_block_gate_contains() {
    local desc="$1" repo="$2" json="$3" needle="$4"
    local result
    result=$(run_gate "$repo" "$json")
    if echo "$result" | grep -q '"block"' && echo "$result" | grep -qi "$needle"; then
        pass "$desc"
    else
        fail "$desc — expected block containing '$needle', got: $result"
    fi
}

run_mark_hook() {
    local repo="$1" json="$2"
    echo "$json" | CLAUDE_PROJECT_DIR="$repo" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        node "$MARK_HOOK" 2>/dev/null || true
}

read_state_status() {
    local sid="$1" step="$2"
    local state_file="$WORKFLOW_DIR/${sid}.json"
    if [ ! -f "$state_file" ]; then echo "MISSING"; return; fi
    node -e "
      try {
        const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
        const st = s.steps && s.steps['$step'];
        console.log(st && st.status ? st.status : 'MISSING');
      } catch (e) { console.log('MISSING'); }
    " "$state_file" 2>/dev/null || echo "MISSING"
}

expect_state_step() {
    local desc="$1" sid="$2" step="$3" expected="$4"
    local actual
    actual=$(read_state_status "$sid" "$step")
    if [ "$actual" = "$expected" ]; then pass "$desc"
    else fail "$desc — expected steps.$step=$expected, got: $actual"; fi
}

expect_no_state_change() {
    local desc="$1" sid="$2" step="$3" expected="$4"
    local actual
    actual=$(read_state_status "$sid" "$step")
    if [ "$actual" = "$expected" ]; then pass "$desc"
    else fail "$desc — expected steps.$step to remain $expected, got: $actual"; fi
}

build_mark_json() {
    local cmd="$1" sid="${2:-test-session}" exit_code="${3:-0}"
    local esc=${cmd//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":%s,"stdout":"","stderr":""},"session_id":"%s"}' \
        "$esc" "$exit_code" "$sid"
}

write_transcript_line() {
    local jsonl_file="$1" sid="$2" state_path="$3"
    printf '%s\n' "{\"type\": \"attachment\", \"attachment\": {\"type\": \"hook_success\", \"hookEvent\": \"SessionStart\", \"stdout\": \"{\\\"additionalContext\\\": \\\"Current workflow session_id: $sid\\\\nState file: $state_path\\\"}\", \"exitCode\": 0, \"command\": \"node session-start.js\"}}" >> "$jsonl_file"
}

write_postcompact_line() {
    local jsonl_file="$1" sid="$2" state_path="$3"
    printf '%s\n' "{\"type\": \"attachment\", \"attachment\": {\"type\": \"hook_success\", \"hookEvent\": \"PostCompact\", \"stdout\": \"{\\\"additionalContext\\\": \\\"Current workflow session_id: $sid\\\\nState file: $state_path\\\"}\", \"exitCode\": 0, \"command\": \"node post-compact.js\"}}" >> "$jsonl_file"
}

call_find_latest() {
    local cwd="$1" branch="$2" fake_home="$3"
    local branch_js
    if [ "$branch" = "null" ]; then branch_js="null"; else branch_js="'$branch'"; fi
    local transcript_base_node
    transcript_base_node="$(to_node_path "$fake_home/.claude/projects")"
    local workflow_dir_node
    workflow_dir_node="$(to_node_path "$WORKFLOW_DIR")"
    HOME="$fake_home" \
        CLAUDE_WORKFLOW_DIR="$workflow_dir_node" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_base_node" \
        run_with_timeout node -e "
try {
  const { findLatestStateForContext } = require('$WORKFLOW_STATE_LIB_NODE');
  const result = findLatestStateForContext({ cwd: '$cwd', git_branch: $branch_js });
  console.log(result ? JSON.stringify(result) : 'null');
} catch (e) { console.log('null'); }
" 2>/dev/null || echo "null"
}

get_json_step_status() {
    local json_str="$1" step="$2"
    printf '%s' "$json_str" | node -e "
try {
  let d=''; const buf=Buffer.alloc(4096); let n;
  try { while((n=require('fs').readSync(0,buf,0,4096))>0) d+=buf.slice(0,n).toString(); } catch(e){}
  const s=JSON.parse(d);
  console.log(s.steps&&s.steps['$step']?s.steps['$step'].status:'MISSING');
} catch(e) { console.log('null'); }
" 2>/dev/null || echo "null"
}

# ---------------------------------------------------------------------------
# Section 1: State Inheritance
# (Smoke — details in tests/feature-workflow-inherit-state.sh)
# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: State Inheritance ==="

# L1-a: transcript + state with research=complete → findLatestStateForContext returns it
CWD_1A="/users/test/repo-l1a-$$"
ENC_1A=$(encode_path "$CWD_1A")
HOME_1A="$TMPDIR_BASE/home-1a"
mkdir -p "$HOME_1A/.claude/projects/$ENC_1A"
SID_1A="l1a-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_1A" "$(INHERIT_STATE_JSON "$SID_1A" "main")"
write_transcript_line "$HOME_1A/.claude/projects/$ENC_1A/${SID_1A}.jsonl" \
    "$SID_1A" "$(to_node_path "$WORKFLOW_DIR/${SID_1A}.json")"
RESULT_1A=$(call_find_latest "$CWD_1A" "main" "$HOME_1A")
RESEARCH_1A=$(get_json_step_status "$RESULT_1A" "research")
if [ "$RESEARCH_1A" = "complete" ]; then
    pass "L1-a. transcript + research=complete state → inherited research=complete"
else
    fail "L1-a. inheritance smoke — expected research=complete, got: $RESEARCH_1A (result: $RESULT_1A)"
fi

# L1-b: state with user_verification=complete → NOT inherited (break out of search)
HOME_1B="$TMPDIR_BASE/home-1b"
CWD_1B="/users/test/repo-l1b-$$"
ENC_1B=$(encode_path "$CWD_1B")
mkdir -p "$HOME_1B/.claude/projects/$ENC_1B"
SID_1B="l1b-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_1B" "$(ALL_COMPLETE_JSON "$SID_1B" "main")"
write_transcript_line "$HOME_1B/.claude/projects/$ENC_1B/${SID_1B}.jsonl" \
    "$SID_1B" "$(to_node_path "$WORKFLOW_DIR/${SID_1B}.json")"
RESULT_1B=$(call_find_latest "$CWD_1B" "main" "$HOME_1B")
if [ "$RESULT_1B" = "null" ] || [ -z "$RESULT_1B" ]; then
    pass "L1-b. user_verification=complete → not inherited (returns null)"
else
    fail "L1-b. user_verification=complete → unexpectedly returned state: $RESULT_1B"
fi

# L1-c: session-start called twice on same session ID → state not overwritten (idempotency)
REPO_1C=$(setup_repo)
SID_1C="l1c-$(printf '%04x%04x' $RANDOM $RANDOM)"
ENV_FILE_1C="$TMPDIR_BASE/1c.env"
write_state "$SID_1C" "$(INHERIT_STATE_JSON "$SID_1C" "main")"
for _i in 1 2; do
    echo "{\"session_id\":\"$SID_1C\"}" | \
        CLAUDE_PROJECT_DIR="$REPO_1C" CLAUDE_ENV_FILE="$ENV_FILE_1C" \
        CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null || true
done
expect_state_step "L1-c. session-start 2 runs → research remains complete (idempotent)" \
    "$SID_1C" "research" "complete"

# L1-d: PostCompact in newer transcript file wins over SessionStart in older file
HOME_1D="$TMPDIR_BASE/home-1d"
CWD_1D="/users/test/repo-l1d-$$"
ENC_1D=$(encode_path "$CWD_1D")
mkdir -p "$HOME_1D/.claude/projects/$ENC_1D"
SID_1D_SS="l1d-ss-$(printf '%04x%04x' $RANDOM $RANDOM)"   # SessionStart: research=complete only
SID_1D_PC="l1d-pc-$(printf '%04x%04x' $RANDOM $RANDOM)"   # PostCompact: research+plan=complete
write_state "$SID_1D_SS" "$(INHERIT_STATE_JSON "$SID_1D_SS" "main")"
write_state "$SID_1D_PC" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_1D_PC", "git_branch": "main",
  "created_at": "$NOW_ISO",
  "steps": {
    "research":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "plan":              {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null}
  }
}
EOF
)"
# Older file: SessionStart
JSONL_1D_OLD="$HOME_1D/.claude/projects/$ENC_1D/old-${SID_1D_SS}.jsonl"
write_transcript_line "$JSONL_1D_OLD" "$SID_1D_SS" "$(to_node_path "$WORKFLOW_DIR/${SID_1D_SS}.json")"
node -e "const fs=require('fs');const old=new Date(Date.now()-60000);fs.utimesSync('$JSONL_1D_OLD',old,old);" 2>/dev/null || true
# Newer file: PostCompact
JSONL_1D_NEW="$HOME_1D/.claude/projects/$ENC_1D/new-${SID_1D_PC}.jsonl"
write_postcompact_line "$JSONL_1D_NEW" "$SID_1D_PC" "$(to_node_path "$WORKFLOW_DIR/${SID_1D_PC}.json")"
RESULT_1D=$(call_find_latest "$CWD_1D" "main" "$HOME_1D")
PLAN_1D=$(get_json_step_status "$RESULT_1D" "plan")
if [ "$PLAN_1D" = "complete" ]; then
    pass "L1-d. PostCompact (newer mtime) wins over SessionStart (older) → plan=complete"
else
    fail "L1-d. PostCompact mtime priority — expected plan=complete, got: $PLAN_1D"
fi

# ---------------------------------------------------------------------------
# Section 2: Cross-Repo Commit
# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: Cross-Repo Commit ==="

REPO_A=$(setup_repo)
REPO_B=$(setup_repo)
REPO_C=$(setup_repo)

# L2-a: repoA all complete, git -C repoA issued from repoB context → approve
SID_2A="l2a-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2A" "$(ALL_COMPLETE_JSON "$SID_2A")"
L2A_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2A\"}"
expect_approve_gate "L2-a. repoA all complete, git -C repoA from repoB → approve" \
    "$REPO_B" "$L2A_JSON"

# L2-b: repoA write_tests=pending, git -C repoA from repoB → block (mentions write_tests)
SID_2B="l2b-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2B" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2B", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
)"
L2B_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2B\"}"
expect_block_gate_contains "L2-b. repoA write_tests=pending, git -C repoA → block (write_tests)" \
    "$REPO_B" "$L2B_JSON" "write_tests"

# L2-c: repoA docs-only staged, git -C repoA → docs-only message (user_verification needed)
SID_2C="l2c-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2C" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2C", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "pending",  "updated_at": null}
  }
}
EOF
)"
mkdir -p "$REPO_A/docs"
echo "change" > "$REPO_A/docs/todo.md"
git -C "$REPO_A" add docs/todo.md
L2C_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2C\"}"
L2C_RESULT=$(echo "$L2C_JSON" | CLAUDE_PROJECT_DIR="$REPO_B" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
    node "$GATE_HOOK" 2>/dev/null || true)
git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
git -C "$REPO_A" clean -fdq 2>/dev/null || true
if echo "$L2C_RESULT" | grep -q '"block"' && echo "$L2C_RESULT" | grep -qi "docs-only"; then
    pass "L2-c. docs-only staged cross-repo → block with docs-only message"
else
    fail "L2-c. docs-only staged cross-repo — expected block+docs-only, got: $L2C_RESULT"
fi

# L2-c2: root README.md only staged → docs-only short-circuit
SID_2C2="l2c2-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2C2" "$(ALL_PENDING_JSON "$SID_2C2")"
echo "readme change" > "$REPO_A/README.md"
git -C "$REPO_A" add README.md
L2C2_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2C2\"}"
L2C2_RESULT=$(run_gate "$REPO_A" "$L2C2_JSON")
git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
git -C "$REPO_A" checkout -- README.md 2>/dev/null || true
if echo "$L2C2_RESULT" | grep -q '"block"' && echo "$L2C2_RESULT" | grep -qi "docs-only"; then
    pass "L2-c2. root README.md only staged → docs-only short-circuit"
else
    fail "L2-c2. root README.md only staged → docs-only short-circuit — got: $L2C2_RESULT"
fi

# L2-c3: docs/todo.md + README.md mixed staged → docs-only short-circuit
SID_2C3="l2c3-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2C3" "$(ALL_PENDING_JSON "$SID_2C3")"
mkdir -p "$REPO_A/docs"
echo "todo change" > "$REPO_A/docs/todo.md"
echo "readme change" > "$REPO_A/README.md"
git -C "$REPO_A" add docs/todo.md README.md
L2C3_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2C3\"}"
L2C3_RESULT=$(run_gate "$REPO_A" "$L2C3_JSON")
git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
git -C "$REPO_A" clean -fdq 2>/dev/null || true
git -C "$REPO_A" checkout -- README.md 2>/dev/null || true
if echo "$L2C3_RESULT" | grep -q '"block"' && echo "$L2C3_RESULT" | grep -qi "docs-only"; then
    pass "L2-c3. docs/todo.md + README.md mixed staged → docs-only short-circuit"
else
    fail "L2-c3. docs/todo.md + README.md mixed staged → docs-only short-circuit — got: $L2C3_RESULT"
fi

# L2-c4: root CLAUDE.md only staged → full gate (behavior code)
SID_2C4="l2c4-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2C4" "$(ALL_PENDING_JSON "$SID_2C4")"
echo "# claude config" > "$REPO_A/CLAUDE.md"
git -C "$REPO_A" add CLAUDE.md
L2C4_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2C4\"}"
L2C4_RESULT=$(run_gate "$REPO_A" "$L2C4_JSON")
git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
rm -f "$REPO_A/CLAUDE.md"
if echo "$L2C4_RESULT" | grep -q '"block"' \
   && ! echo "$L2C4_RESULT" | grep -qi "docs-only" \
   && echo "$L2C4_RESULT" | grep -q "research"; then
    pass "L2-c4. root CLAUDE.md only staged → full gate (behavior code)"
else
    fail "L2-c4. root CLAUDE.md only staged → full gate (behavior code) — got: $L2C4_RESULT"
fi

# L2-c5: subdirectory README.md staged → full gate (root-only allowlist)
SID_2C5="l2c5-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2C5" "$(ALL_PENDING_JSON "$SID_2C5")"
mkdir -p "$REPO_A/subproject"
echo "sub readme" > "$REPO_A/subproject/README.md"
git -C "$REPO_A" add subproject/README.md
L2C5_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2C5\"}"
L2C5_RESULT=$(run_gate "$REPO_A" "$L2C5_JSON")
git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
rm -rf "$REPO_A/subproject"
if echo "$L2C5_RESULT" | grep -q '"block"' \
   && ! echo "$L2C5_RESULT" | grep -qi "docs-only"; then
    pass "L2-c5. subdirectory README.md staged → full gate (root-only allowlist)"
else
    fail "L2-c5. subdirectory README.md staged → full gate (root-only allowlist) — got: $L2C5_RESULT"
fi

# L2-d: repoA tests/ staged, write_tests=pending → approve (evidence-based override)
SID_2D="l2d-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2D" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2D", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
)"
mkdir -p "$REPO_A/tests"
echo "test" > "$REPO_A/tests/test-case.sh"
git -C "$REPO_A" add tests/test-case.sh
L2D_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2D\"}"
L2D_RESULT=$(echo "$L2D_JSON" | CLAUDE_PROJECT_DIR="$REPO_B" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
    node "$GATE_HOOK" 2>/dev/null || true)
git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
git -C "$REPO_A" clean -fdq 2>/dev/null || true
if echo "$L2D_RESULT" | grep -q '"approve"'; then
    pass "L2-d. tests/ staged cross-repo, write_tests=pending → approve (evidence override)"
else
    fail "L2-d. tests/ staged cross-repo — expected approve, got: $L2D_RESULT"
fi

# L2-e: CLAUDE_PROJECT_DIR=third-repo, git -C repoA → state still resolved from WORKFLOW_DIR
SID_2E="l2e-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2E" "$(ALL_COMPLETE_JSON "$SID_2E")"
L2E_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2E\"}"
expect_approve_gate "L2-e. CLAUDE_PROJECT_DIR=third-repo, -C repoA → state from WORKFLOW_DIR" \
    "$REPO_C" "$L2E_JSON"

# L2-f: git -C /nonexistent → block (no crash)
SID_2F="l2f-$(printf '%04x%04x' $RANDOM $RANDOM)"
NONEXISTENT="$TMPDIR_BASE/nonexistent-l2f-$$"
L2F_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $NONEXISTENT commit -m test\"},\"session_id\":\"$SID_2F\"}"
L2F_RESULT=$(echo "$L2F_JSON" | CLAUDE_PROJECT_DIR="$REPO_A" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
    node "$GATE_HOOK" 2>/dev/null || true)
if echo "$L2F_RESULT" | grep -q '"block"'; then
    pass "L2-f. git -C /nonexistent → block (no crash)"
else
    fail "L2-f. git -C /nonexistent — expected block, got: $L2F_RESULT"
fi

# L2-g(DQ): double-quoted -C argument correctly resolved
REPO_DQ=$(setup_repo)
SID_2G_DQ="l2g-dq-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2G_DQ" "$(ALL_COMPLETE_JSON "$SID_2G_DQ")"
L2G_DQ_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C \\\"$REPO_DQ\\\" commit -m test\"},\"session_id\":\"$SID_2G_DQ\"}"
expect_approve_gate 'L2-g(DQ). git -C "path" commit → resolved and approved' "$REPO_B" "$L2G_DQ_JSON"

# L2-g(SQ): single-quoted -C argument correctly resolved
REPO_SQ=$(setup_repo)
SID_2G_SQ="l2g-sq-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2G_SQ" "$(ALL_COMPLETE_JSON "$SID_2G_SQ")"
L2G_SQ_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C '$REPO_SQ' commit -m test\"},\"session_id\":\"$SID_2G_SQ\"}"
expect_approve_gate "L2-g(SQ). git -C 'path' commit → resolved and approved" "$REPO_B" "$L2G_SQ_JSON"

# L2-h: test/ (single t, not tests/) staged with write_tests=pending → approve (evidence override)
SID_2H="l2h-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2H" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2H", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
)"
mkdir -p "$REPO_A/test"
echo "unit test" > "$REPO_A/test/unit.sh"
git -C "$REPO_A" add test/unit.sh
L2H_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2H\"}"
L2H_RESULT=$(echo "$L2H_JSON" | CLAUDE_PROJECT_DIR="$REPO_B" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
    node "$GATE_HOOK" 2>/dev/null || true)
git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
git -C "$REPO_A" clean -fdq 2>/dev/null || true
if echo "$L2H_RESULT" | grep -q '"approve"'; then
    pass "L2-h. test/ (single t) staged, write_tests=pending → approve (evidence override)"
else
    fail "L2-h. test/ staged cross-repo — expected approve, got: $L2H_RESULT"
fi

# L2-i: root-level *.md staged with docs=pending → approve (hasStagedDocChanges *.md match)
SID_2I="l2i-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2I" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2I", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
)"
echo "changelog" > "$REPO_A/CHANGES.md"
git -C "$REPO_A" add CHANGES.md
L2I_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2I\"}"
L2I_RESULT=$(echo "$L2I_JSON" | CLAUDE_PROJECT_DIR="$REPO_B" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
    node "$GATE_HOOK" 2>/dev/null || true)
git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
git -C "$REPO_A" clean -fdq 2>/dev/null || true
if echo "$L2I_RESULT" | grep -q '"approve"'; then
    pass "L2-i. root-level *.md staged, docs=pending → approve (hasStagedDocChanges *.md match)"
else
    fail "L2-i. root-level *.md cross-repo — expected approve, got: $L2I_RESULT"
fi

# L2-j(security): path traversal in git -C (../ sequences) → block gracefully, no crash
# git diff fails on non-repo traversal path → evidence checks return false → state-based block
SID_2J="l2j-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_2J" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2J", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
)"
L2J_TRAVERSAL="$TMPDIR_BASE/sub/../../nonexistent-l2j-$$"
L2J_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $L2J_TRAVERSAL commit -m test\"},\"session_id\":\"$SID_2J\"}"
L2J_RESULT=$(echo "$L2J_JSON" | CLAUDE_PROJECT_DIR="$REPO_A" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
    node "$GATE_HOOK" 2>/dev/null || true)
if echo "$L2J_RESULT" | grep -q '"block"'; then
    pass "L2-j(security). path traversal in git -C → block (git fails gracefully, state check succeeds)"
else
    fail "L2-j(security). path traversal — expected block, got: $L2J_RESULT"
fi

# ---------------------------------------------------------------------------
# Section 3: RESET_FROM hook
# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: RESET_FROM ==="

REPO_3=$(setup_repo)

# L3-a: RESET_FROM_write_tests → steps before write_tests=complete, from write_tests=pending
SID_3A="l3a-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_3A" "$(ALL_COMPLETE_JSON "$SID_3A")"
run_mark_hook "$REPO_3" "$(build_mark_json 'echo "<<WORKFLOW_RESET_FROM_write_tests>>"' "$SID_3A")" >/dev/null
expect_state_step "L3-a(research). RESET_FROM_write_tests → research=complete" \
    "$SID_3A" "research" "complete"
expect_state_step "L3-a(plan). RESET_FROM_write_tests → plan=complete" \
    "$SID_3A" "plan" "complete"
expect_state_step "L3-a(write_tests). RESET_FROM_write_tests → write_tests=pending" \
    "$SID_3A" "write_tests" "pending"
expect_state_step "L3-a(user_verification). RESET_FROM_write_tests → user_verification=pending" \
    "$SID_3A" "user_verification" "pending"

# L3-b: RESET_FROM_research → all steps=pending
SID_3B="l3b-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_3B" "$(ALL_COMPLETE_JSON "$SID_3B")"
run_mark_hook "$REPO_3" "$(build_mark_json 'echo "<<WORKFLOW_RESET_FROM_research>>"' "$SID_3B")" >/dev/null
expect_state_step "L3-b(research). RESET_FROM_research → research=pending" \
    "$SID_3B" "research" "pending"
expect_state_step "L3-b(user_verification). RESET_FROM_research → user_verification=pending" \
    "$SID_3B" "user_verification" "pending"

# L3-c: RESET_FROM_foo (unknown step) → state unchanged, ignored
SID_3C="l3c-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_3C" "$(ALL_COMPLETE_JSON "$SID_3C")"
run_mark_hook "$REPO_3" "$(build_mark_json 'echo "<<WORKFLOW_RESET_FROM_foo>>"' "$SID_3C")" >/dev/null
expect_state_step "L3-c. RESET_FROM_foo (unknown) → research stays complete" \
    "$SID_3C" "research" "complete"

# L3-d: session_id missing → state unchanged, exit 0, additionalContext warning
SID_3D="l3d-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_3D" "$(ALL_COMPLETE_JSON "$SID_3D")"
L3D_CMD='echo "<<WORKFLOW_RESET_FROM_write_tests>>"'
L3D_ESC=${L3D_CMD//\"/\\\"}
L3D_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"","stderr":""}}' "$L3D_ESC")
L3D_EXIT=0
L3D_OUT=$(echo "$L3D_JSON" | CLAUDE_PROJECT_DIR="$REPO_3" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
    env -u CLAUDE_ENV_FILE node "$MARK_HOOK" 2>/dev/null) || L3D_EXIT=$?
if [ "$L3D_EXIT" = "0" ]; then
    pass "L3-d(exit). session_id missing + RESET_FROM → exit 0"
else
    fail "L3-d(exit). expected exit 0, got $L3D_EXIT"
fi
expect_state_step "L3-d(state). session_id missing → research stays complete" \
    "$SID_3D" "research" "complete"
if echo "$L3D_OUT" | grep -qi "additionalContext\|session_id\|re-run"; then
    pass "L3-d(msg). session_id missing → warning in additionalContext output"
else
    fail "L3-d(msg). session_id missing → no warning in output: $L3D_OUT"
fi

# ---------------------------------------------------------------------------
# Section 4: USER_VERIFIED hook
# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: USER_VERIFIED ==="

REPO_4=$(setup_repo)

# L4-a: WORKFLOW_USER_VERIFIED → user_verification=complete
SID_4A="l4a-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_4A" "$(ALL_PENDING_JSON "$SID_4A")"
run_mark_hook "$REPO_4" "$(build_mark_json 'echo "<<WORKFLOW_USER_VERIFIED>>"' "$SID_4A")" >/dev/null
expect_state_step "L4-a. WORKFLOW_USER_VERIFIED → user_verification=complete" \
    "$SID_4A" "user_verification" "complete"

# L4-b: MARK_STEP_user_verification_complete → (a) state unchanged (b) rejection msg (c) exit 0
SID_4B="l4b-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_4B" "$(ALL_PENDING_JSON "$SID_4B")"
L4B_CMD='echo "<<WORKFLOW_MARK_STEP_user_verification_complete>>"'
L4B_ESC=${L4B_CMD//\"/\\\"}
L4B_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"","stderr":""},"session_id":"%s"}' \
    "$L4B_ESC" "$SID_4B")
L4B_EXIT=0
L4B_OUT=$(echo "$L4B_JSON" | CLAUDE_PROJECT_DIR="$REPO_4" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
    node "$MARK_HOOK" 2>/dev/null) || L4B_EXIT=$?
if [ "$L4B_EXIT" = "0" ]; then
    pass "L4-b(exit). MARK_STEP_user_verification → exit 0"
else
    fail "L4-b(exit). MARK_STEP_user_verification → expected exit 0, got $L4B_EXIT"
fi
expect_no_state_change "L4-b(state). MARK_STEP_user_verification → user_verification stays pending" \
    "$SID_4B" "user_verification" "pending"
if echo "$L4B_OUT" | grep -qi "user_verification\|rejected\|additionalContext\|MARK_STEP"; then
    pass "L4-b(msg). MARK_STEP_user_verification → rejection message in output"
else
    fail "L4-b(msg). MARK_STEP_user_verification → no rejection in output: $L4B_OUT"
fi

# L4-c: session_id missing → user_verification unchanged, exit 0
SID_4C="l4c-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_4C" "$(ALL_PENDING_JSON "$SID_4C")"
L4C_CMD='echo "<<WORKFLOW_USER_VERIFIED>>"'
L4C_ESC=${L4C_CMD//\"/\\\"}
L4C_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"","stderr":""}}' "$L4C_ESC")
L4C_EXIT=0
echo "$L4C_JSON" | CLAUDE_PROJECT_DIR="$REPO_4" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
    env -u CLAUDE_ENV_FILE node "$MARK_HOOK" 2>/dev/null || L4C_EXIT=$?
if [ "$L4C_EXIT" = "0" ]; then
    pass "L4-c(exit). no session_id + USER_VERIFIED → exit 0"
else
    fail "L4-c(exit). no session_id + USER_VERIFIED → expected exit 0, got $L4C_EXIT"
fi
expect_no_state_change "L4-c(state). no session_id → user_verification stays pending" \
    "$SID_4C" "user_verification" "pending"

# ---------------------------------------------------------------------------
# Section 5: Branch Isolation
# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: Branch Isolation ==="

# Setup: two states for the same cwd, different branches
CWD_5="/users/test/repo-branch-$$"
ENC_5=$(encode_path "$CWD_5")
HOME_5="$TMPDIR_BASE/home-5"
mkdir -p "$HOME_5/.claude/projects/$ENC_5"

SID_5_MAIN="l5-main-$(printf '%04x%04x' $RANDOM $RANDOM)"
SID_5_FEAT="l5-feat-$(printf '%04x%04x' $RANDOM $RANDOM)"

# main state: research=complete only (plan=pending distinguishes it from feature/x)
write_state "$SID_5_MAIN" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_5_MAIN", "git_branch": "main",
  "created_at": "$NOW_ISO",
  "steps": {
    "research":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "plan":              {"status": "pending",  "updated_at": null},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null}
  }
}
EOF
)"
# feature/x state: research+plan=complete
write_state "$SID_5_FEAT" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_5_FEAT", "git_branch": "feature/x",
  "created_at": "$NOW_ISO",
  "steps": {
    "research":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "plan":              {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null}
  }
}
EOF
)"
write_transcript_line "$HOME_5/.claude/projects/$ENC_5/main-${SID_5_MAIN}.jsonl" \
    "$SID_5_MAIN" "$(to_node_path "$WORKFLOW_DIR/${SID_5_MAIN}.json")"
write_transcript_line "$HOME_5/.claude/projects/$ENC_5/feat-${SID_5_FEAT}.jsonl" \
    "$SID_5_FEAT" "$(to_node_path "$WORKFLOW_DIR/${SID_5_FEAT}.json")"

# L5-a: query main → returns main state (plan=pending, not feature/x's plan=complete)
RESULT_5A=$(call_find_latest "$CWD_5" "main" "$HOME_5")
PLAN_5A=$(get_json_step_status "$RESULT_5A" "plan")
if [ "$PLAN_5A" = "pending" ]; then
    pass "L5-a. query main → main state (plan=pending, not feature/x plan=complete)"
else
    fail "L5-a. query main — expected plan=pending (main), got: $PLAN_5A (result: $RESULT_5A)"
fi

# L5-b: query feature/x → returns feature/x state (plan=complete, not main's plan=pending)
RESULT_5B=$(call_find_latest "$CWD_5" "feature/x" "$HOME_5")
PLAN_5B=$(get_json_step_status "$RESULT_5B" "plan")
if [ "$PLAN_5B" = "complete" ]; then
    pass "L5-b. query feature/x → feature/x state (plan=complete)"
else
    fail "L5-b. query feature/x — expected plan=complete, got: $PLAN_5B (result: $RESULT_5B)"
fi

# L5-c: detached HEAD (git_branch=null) query → does NOT match main state (branch mismatch)
HOME_5C="$TMPDIR_BASE/home-5c"
CWD_5C="/users/test/repo-detached-$$"
ENC_5C=$(encode_path "$CWD_5C")
mkdir -p "$HOME_5C/.claude/projects/$ENC_5C"
SID_5C="l5c-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$SID_5C" "$(INHERIT_STATE_JSON "$SID_5C" "main")"
write_transcript_line "$HOME_5C/.claude/projects/$ENC_5C/${SID_5C}.jsonl" \
    "$SID_5C" "$(to_node_path "$WORKFLOW_DIR/${SID_5C}.json")"
RESULT_5C=$(call_find_latest "$CWD_5C" "null" "$HOME_5C")
if [ "$RESULT_5C" = "null" ] || [ -z "$RESULT_5C" ]; then
    pass "L5-c. detached HEAD (git_branch=null) query → null (no match with main state)"
else
    fail "L5-c. detached HEAD → expected null, got: $RESULT_5C"
fi

# L5-d: security — CLAUDE_PROJECT_DIR with shell metacharacters → no command injection, no crash
# getCurrentContext calls: git -C JSON.stringify(cwd) rev-parse --abbrev-ref HEAD
# On Windows (cmd.exe), $(...) syntax is not expanded, so this is safe.
PWNED_MARKER="$TMPDIR_BASE/L5d-pwned.txt"
# Build injection path with literal $() in the dirname (bash does not expand \$)
INJECTION_PATH="${TMPDIR_BASE}/repo-l5d-\$(touch ${PWNED_MARKER})-$$"
SID_5D="l5d-$(printf '%04x%04x' $RANDOM $RANDOM)"
ENV_5D="$TMPDIR_BASE/5d.env"
L5D_EXIT=0
echo "{\"session_id\":\"$SID_5D\"}" | \
    CLAUDE_PROJECT_DIR="$INJECTION_PATH" CLAUDE_ENV_FILE="$ENV_5D" \
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null || L5D_EXIT=$?
if [ "$L5D_EXIT" = "0" ]; then
    pass "L5-d(exit). shell metachar in CLAUDE_PROJECT_DIR → exit 0 (no crash)"
else
    fail "L5-d(exit). shell metachar → unexpected non-zero exit: $L5D_EXIT"
fi
if [ ! -f "$PWNED_MARKER" ]; then
    pass "L5-d(security). shell metachar → no command injection (pwned file not created)"
else
    fail "L5-d(security). INJECTION DETECTED — $PWNED_MARKER was created"
    rm -f "$PWNED_MARKER"
fi

# ---------------------------------------------------------------------------
# Section 6: Structure Smoke
# (Minimal — details in tests/feature-robust-workflow-settings.sh)
# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: Structure Smoke ==="

# L6-a: PostToolUse hooks contains a Bash matcher
if node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
const ptu = s.hooks && s.hooks.PostToolUse;
process.exit(ptu && ptu[0] && ptu[0].matcher === 'Bash' ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
    pass "L6-a. settings.json PostToolUse[0].matcher === 'Bash'"
else
    fail "L6-a. settings.json PostToolUse missing Bash matcher"
fi

# L6-b: permissions.ask contains both WORKFLOW_USER_VERIFIED and WORKFLOW_RESET_FROM
if node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
const ask = (s.permissions && s.permissions.ask) || [];
const hasUV = ask.some(e => e.includes('WORKFLOW_USER_VERIFIED'));
const hasRF = ask.some(e => e.includes('WORKFLOW_RESET_FROM'));
process.exit(hasUV && hasRF ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
    pass "L6-b. permissions.ask has WORKFLOW_USER_VERIFIED and WORKFLOW_RESET_FROM"
else
    fail "L6-b. permissions.ask missing WORKFLOW_USER_VERIFIED or WORKFLOW_RESET_FROM"
fi

# L6-c: permissions.deny contains ~/.claude/projects/workflow path
if node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
const deny = (s.permissions && s.permissions.deny) || [];
process.exit(deny.some(e => e.includes('.claude/projects/workflow')) ? 0 : 1);
" -- "$SETTINGS" 2>/dev/null; then
    pass "L6-c. permissions.deny contains .claude/projects/workflow path"
else
    fail "L6-c. permissions.deny missing .claude/projects/workflow path"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
