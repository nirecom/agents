# shellcheck shell=bash
# Tests: hooks/workflow-gate.js, hooks/workflow-mark.js
# Tags: workflow, gate, hook, bin, git
#
# Shared helpers + fixtures for the main-workflow-evidence dispatcher.
# Sourced by main-workflow-evidence.sh and the case-group files in this folder.

ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM"
    mkdir -p "$repo"
    git -C "$repo" init -q
    # Disable inherited global core.hooksPath (points to agents/hooks pre-commit,
    # which blocks commits it cannot resolve to a linked worktree).
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q --no-verify -m "initial"
    echo "$repo"
}

write_state() {
    local sid="$1" json="$2"
    mkdir -p "$WORKFLOW_DIR"
    printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

read_state_status() {
    local sid="$1" step="$2"
    local state_file="$WORKFLOW_DIR/${sid}.json"
    if [ ! -f "$state_file" ]; then echo "MISSING"; return; fi
    node -e "
      try {
        const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
        const step = s.steps && s.steps['$step'];
        console.log(step && step.status ? step.status : 'MISSING');
      } catch (e) { console.log('MISSING'); }
    " "$state_file" 2>/dev/null || echo "MISSING"
}

# Read an arbitrary nested field from steps.<step>.<field> (e.g. skip_reason).
# Prints "MISSING" when the file, step, or field is absent.
read_state_field() {
    local sid="$1" step="$2" field="$3"
    local state_file="$WORKFLOW_DIR/${sid}.json"
    if [ ! -f "$state_file" ]; then echo "MISSING"; return; fi
    node -e "
      try {
        const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
        const step = s.steps && s.steps['$step'];
        if (!step || step['$field'] === undefined || step['$field'] === null) {
          console.log('MISSING');
        } else {
          console.log(step['$field']);
        }
      } catch (e) { console.log('MISSING'); }
    " "$state_file" 2>/dev/null || echo "MISSING"
}

expect_state_step() {
    local desc="$1" sid="$2" step="$3" expected="$4"
    local actual
    actual=$(read_state_status "$sid" "$step")
    if [ "$actual" = "$expected" ]; then pass "$desc"
    else fail "$desc — expected steps.$step.status=$expected, got: $actual"; fi
}

# State JSON where all steps are complete EXCEPT a given step
ALL_COMPLETE_EXCEPT() {
    local except_step="$1" sid="${2:-test-session}"
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "$([ "$except_step" = "write_tests" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "write_tests" ] && echo "null" || echo '"2026-04-11T10:03:00.000Z"')},
    "review_tests":      {"status": "$([ "$except_step" = "review_tests" ] && echo "pending" || echo "skipped")", "updated_at": "2026-04-11T10:03:30.000Z"},
    "run_tests":         {"status": "$([ "$except_step" = "run_tests" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "run_tests" ] && echo "null" || echo '"2026-04-11T10:04:00.000Z"')},
    "review_security":   {"status": "$([ "$except_step" = "review_security" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "review_security" ] && echo "null" || echo '"2026-04-11T10:04:30.000Z"')},
    "docs":              {"status": "$([ "$except_step" = "docs" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "docs" ] && echo "null" || echo '"2026-04-11T10:05:00.000Z"')},
    "user_verification": {"status": "$([ "$except_step" = "user_verification" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "user_verification" ] && echo "null" || echo '"2026-04-11T10:06:00.000Z"')},
    "cleanup":           {"status": "$([ "$except_step" = "cleanup" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "cleanup" ] && echo "null" || echo '"2026-04-11T10:07:00.000Z"')}
  }
}
EOF
}

ALL_COMPLETE_EXCEPT_TWO() {
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
    "write_tests":       {"status": "pending", "updated_at": null},
    "review_tests":      {"status": "skipped", "updated_at": "2026-04-11T10:03:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "docs":              {"status": "pending", "updated_at": null},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"}
  }
}
EOF
}

# Convert path to mixed-mode (C:/...) for node compatibility on Windows
to_node_path() {
    cygpath -m "$1" 2>/dev/null || echo "$1"
}

run_gate() {
    local json="$1"
    echo "$json" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$GATE_HOOK" 2>/dev/null
}

run_mark() {
    local json="$1"
    echo "$json" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$MARK_HOOK" 2>/dev/null || true
}

build_mark_json() {
    local cmd="$1" sid="${2:-test-session}" exit_code="${3:-0}"
    local esc=${cmd//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":%s,"stdout":"%s\\n","stderr":""},"session_id":"%s"}' \
        "$esc" "$exit_code" "$esc" "$sid"
}
