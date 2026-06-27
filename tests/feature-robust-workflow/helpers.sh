# ---------------------------------------------------------------------------
# Temporary git repo setup
# ---------------------------------------------------------------------------

TMPDIR_BASE=$(mktemp -d)
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

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

# Create the workflow/<session-id>.json state file in WORKFLOW_DIR
# Usage: write_state <session_id> <json_content>
write_state() {
    local sid="${1:-}"
    local json="${2:-}"
    mkdir -p "$WORKFLOW_DIR"
    printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

# ---------------------------------------------------------------------------
# Helper: all-complete state JSON
# ---------------------------------------------------------------------------

ALL_COMPLETE_JSON() {
    local sid="${1:-test-session}"
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
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
    "cleanup":           {"status": "complete", "updated_at": "2026-04-11T10:08:00.000Z"}
  }
}
EOF
}

ALL_PENDING_JSON() {
    local sid="${1:-test-session}"
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
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
    "user_verification": {"status": "pending", "updated_at": null},
    "cleanup":           {"status": "pending", "updated_at": null}
  }
}
EOF
}

COMMIT_JSON='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""},"session_id":"test-session"}'

# ---------------------------------------------------------------------------
# workflow-gate.js helpers
# ---------------------------------------------------------------------------

run_gate() {
    local repo="$1" json="$2"
    # AGENTS_CONFIG_DIR="$repo" so isAgentsSessionRepo() (issue #1138) treats the
    # commit target as the agents session repo — i.e. the gate enforces workflow
    # state, matching the historical single-repo behavior these tests assume.
    echo "$json" | CLAUDE_PROJECT_DIR="$repo" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" AGENTS_CONFIG_DIR="$repo" node "$GATE_HOOK" 2>/dev/null || true
}

# Cross-repo variant (issue #1138): the agents session lives in $agents_repo but
# the commit targets $target_repo. When $target_repo is NOT the agents session
# repo, the gate must skip workflow-state enforcement (approve / bypass).
# $json should carry a `git -C <target_repo> commit ...` command so resolveRepoDir
# points at the foreign repo.
run_gate_cross_repo() {
    local agents_repo="$1" target_repo="$2" json="$3"
    echo "$json" | CLAUDE_PROJECT_DIR="$target_repo" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" AGENTS_CONFIG_DIR="$agents_repo" node "$GATE_HOOK" 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# workflow-mark.js helpers
# ---------------------------------------------------------------------------

run_mark_hook() {
    local repo="$1" json="$2"
    echo "$json" | CLAUDE_PROJECT_DIR="$repo" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$MARK_HOOK" 2>/dev/null || true
}

# Read the state file and extract steps.<step>.status using node.
# Prints the status string, or "MISSING" if the file / step is absent.
read_state_status() {
    local sid="$1" step="$2"
    local state_file="$WORKFLOW_DIR/${sid}.json"
    if [ ! -f "$state_file" ]; then
        echo "MISSING"
        return
    fi
    node -e "
      try {
        const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
        const step = s.steps && s.steps['$step'];
        console.log(step && step.status ? step.status : 'MISSING');
      } catch (e) { console.log('MISSING'); }
    " "$state_file" 2>/dev/null || echo "MISSING"
}

expect_state_step() {
    local desc="$1" sid="$2" step="$3" expected="$4"
    local actual
    actual=$(read_state_status "$sid" "$step")
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc — expected steps.$step.status=$expected, got: $actual"
    fi
}

expect_no_state_change() {
    local desc="$1" sid="$2" step="$3" expected_unchanged="$4"
    local actual
    actual=$(read_state_status "$sid" "$step")
    if [ "$actual" = "$expected_unchanged" ]; then
        pass "$desc"
    else
        fail "$desc — expected steps.$step.status to remain $expected_unchanged, got: $actual"
    fi
}

# ---------------------------------------------------------------------------
# State file helpers
# ---------------------------------------------------------------------------

get_state_file() {
    local sid="$1"
    echo "$WORKFLOW_DIR/${sid}.json"
}

# ---------------------------------------------------------------------------
# session-start.js helpers
# ---------------------------------------------------------------------------

run_session_start() {
    local json="$1"
    shift
    echo "$json" | "$@" node "$SESSION_START" 2>/dev/null
}

# ---------------------------------------------------------------------------
# workflow-mark builders
# ---------------------------------------------------------------------------

# Helper: build a PostToolUse-style hook input JSON with a Bash command and
# tool_response.exit_code=0. Escape embedded double quotes in $cmd.
build_mark_json() {
    local cmd="$1" sid="${2:-test-session}"
    # Escape backslashes and double quotes in $cmd for JSON
    local esc=${cmd//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"%s\\n","stderr":""},"session_id":"%s"}' "$esc" "$esc" "$sid"
}

# Helper: build a hook input JSON for WORKFLOW_RESET_FROM commands.
# Like build_mark_json but takes the raw command string (no escaping needed
# for the reset commands which use only alphanumeric step names).
build_reset_json() {
    local cmd="$1" sid="${2:-test-session}"
    local esc=${cmd//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"%s\\n","stderr":""},"session_id":"%s"}' "$esc" "$esc" "$sid"
}
