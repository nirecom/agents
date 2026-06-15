#!/bin/bash
# Tests: hooks/workflow-gate.js, hooks/workflow-mark.js
# Tags: workflow, gate, hook, sentinel, bin
# Tests for WORKFLOW_{RESEARCH,PLAN,WRITE_TESTS}_NOT_NEEDED skip sentinels
# and DOCS_NOT_NEEDED deprecation.
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_HOOK="$AGENTS_DIR/hooks/workflow-gate.js"
MARK_HOOK="$AGENTS_DIR/hooks/workflow-mark.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper (macOS has no `timeout` by default)
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 180 "$@"
    else
        perl -e 'alarm 180; exec @ARGV' -- "$@"
    fi
}

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

# State JSON where all steps are complete EXCEPT a given step (pending)
ALL_COMPLETE_EXCEPT() {
    local except_step="$1" sid="${2:-test-session}"
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "$([ "$except_step" = "research" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "research" ] && echo "null" || echo '"2026-04-11T10:01:00.000Z"')},
    "outline":           {"status": "$([ "$except_step" = "outline" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "outline" ] && echo "null" || echo '"2026-04-11T10:02:00.000Z"')},
    "detail":            {"status": "$([ "$except_step" = "detail" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "detail" ] && echo "null" || echo '"2026-04-11T10:02:30.000Z"')},
    "write_tests":       {"status": "$([ "$except_step" = "write_tests" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "write_tests" ] && echo "null" || echo '"2026-04-11T10:03:00.000Z"')},
    "code":              {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "verify":            {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "$([ "$except_step" = "docs" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "docs" ] && echo "null" || echo '"2026-04-11T10:06:00.000Z"')},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
}

# State JSON where the given step is "skipped" and others are all complete.
# Reason is optional; when provided it is stored in skip_reason.
ALL_COMPLETE_WITH_SKIPPED() {
    local skipped_step="$1" sid="${2:-test-session}" reason="${3:-}"
    local skip_json
    if [ -n "$reason" ]; then
        skip_json='{"status": "skipped", "updated_at": "2026-04-11T10:03:00.000Z", "skip_reason": "'"$reason"'"}'
    else
        skip_json='{"status": "skipped", "updated_at": "2026-04-11T10:03:00.000Z"}'
    fi
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "$([ "$skipped_step" = "research" ] && echo -n "__SKIP__" || echo "complete")", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "$([ "$skipped_step" = "outline" ] && echo -n "__SKIP__" || echo "complete")", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "$([ "$skipped_step" = "detail" ] && echo -n "__SKIP__" || echo "complete")", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "$([ "$skipped_step" = "write_tests" ] && echo -n "__SKIP__" || echo "complete")", "updated_at": "2026-04-11T10:03:00.000Z"},
    "code":              {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "verify":            {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
}

# Build a state JSON where a single named step is given a raw object JSON literal.
# This is used to construct "skipped" states precisely.
build_state_with_override() {
    local sid="$1" step="$2" override_json="$3"
    node -e "
      const sid = process.argv[1];
      const step = process.argv[2];
      const override = JSON.parse(process.argv[3]);
      const STEPS = ['workflow_init','clarify_intent','research','outline','detail','branching_complete','write_tests','review_tests','run_tests','review_security','docs','user_verification','cleanup'];
      const steps = {};
      for (const s of STEPS) {
        steps[s] = { status: 'complete', updated_at: '2026-04-11T10:00:00.000Z' };
      }
      steps[step] = override;
      const state = {
        version: 1,
        session_id: sid,
        created_at: '2026-04-11T10:00:00.000Z',
        steps,
      };
      console.log(JSON.stringify(state, null, 2));
    " "$sid" "$step" "$override_json"
}

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

build_mark_json_no_sid() {
    local cmd="$1" exit_code="${2:-0}"
    local esc=${cmd//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":%s,"stdout":"%s\\n","stderr":""}}' \
        "$esc" "$exit_code" "$esc"
}

EMPTY_TRANSCRIPT_DIR="$TMPDIR_BASE/transcripts-empty"
mkdir -p "$EMPTY_TRANSCRIPT_DIR"

SCRIPT_DIR="$(dirname "$0")/main-workflow-skip-sentinels"

# shellcheck source=./main-workflow-skip-sentinels/not-needed-happy.sh
. "$SCRIPT_DIR/not-needed-happy.sh"
# shellcheck source=./main-workflow-skip-sentinels/not-needed-errors.sh
. "$SCRIPT_DIR/not-needed-errors.sh"
# shellcheck source=./main-workflow-skip-sentinels/gate-migration.sh
. "$SCRIPT_DIR/gate-migration.sh"
# shellcheck source=./main-workflow-skip-sentinels/no-sid.sh
. "$SCRIPT_DIR/no-sid.sh"
# shellcheck source=./main-workflow-skip-sentinels/combo-security.sh
. "$SCRIPT_DIR/combo-security.sh"

# ===========================================================================
# Results
# ===========================================================================

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
