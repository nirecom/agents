# shellcheck shell=bash
# Shared helpers + fixtures for the main-workflow-state-machine dispatcher.
# Sourced by main-workflow-state-machine.sh and the case-group files in this folder.

ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
    else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# Current timestamp for states that session-start may encounter (avoids cleanupZombies deletion)
NOW_ISO=$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
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
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_tests":      {"status": "skipped", "updated_at": "2026-04-11T10:03:30.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"},
    "cleanup":           {"status": "skipped",  "updated_at": "2026-04-11T10:08:00.000Z"}
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
    "outline":           {"status": "pending", "updated_at": null},
    "detail":            {"status": "pending", "updated_at": null},
    "write_tests":       {"status": "pending", "updated_at": null},
    "review_tests":      {"status": "pending", "updated_at": null},
    "review_security":   {"status": "pending", "updated_at": null},
    "run_tests":         {"status": "pending", "updated_at": null},
    "docs":              {"status": "pending", "updated_at": null},
    "user_verification": {"status": "pending", "updated_at": null}
  }
}
EOF
}

# State with research+outline+detail complete; rest pending. Uses NOW_ISO to survive cleanupZombies.
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
    "outline":           {"status": "complete", "updated_at": "$NOW_ISO"},
    "detail":            {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
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
    # Unconditionally set AGENTS_CONFIG_DIR="$repo" so isAgentsSessionRepo() (#1138)
    # treats the target repo as the agents session repo — enforcement always applies.
    # Cross-repo tests that need a different agents dir must use an inline node call.
    echo "$json" | CLAUDE_PROJECT_DIR="$repo" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        AGENTS_CONFIG_DIR="$repo" node "$GATE_HOOK" 2>/dev/null || true
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
