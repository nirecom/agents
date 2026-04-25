#!/bin/bash
# Tests for evidence-based write_tests/docs enforcement
# in workflow-gate.js (PreToolUse) and workflow-mark.js (PostToolUse)
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_HOOK="$DOTFILES_DIR/claude-global/hooks/workflow-gate.js"
MARK_HOOK="$DOTFILES_DIR/claude-global/hooks/workflow-mark.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

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
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "$([ "$except_step" = "write_tests" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "write_tests" ] && echo "null" || echo '"2026-04-11T10:03:00.000Z"')},
    "run_tests":         {"status": "$([ "$except_step" = "run_tests" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "run_tests" ] && echo "null" || echo '"2026-04-11T10:04:00.000Z"')},
    "review_security":   {"status": "$([ "$except_step" = "review_security" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "review_security" ] && echo "null" || echo '"2026-04-11T10:04:30.000Z"')},
    "docs":              {"status": "$([ "$except_step" = "docs" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "docs" ] && echo "null" || echo '"2026-04-11T10:05:00.000Z"')},
    "user_verification": {"status": "$([ "$except_step" = "user_verification" ] && echo "pending" || echo "complete")", "updated_at": $([ "$except_step" = "user_verification" ] && echo "null" || echo '"2026-04-11T10:06:00.000Z"')}
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
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "pending", "updated_at": null},
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

# ===========================================================================
# workflow-gate.js — evidence-based checks
# ===========================================================================

echo ""
echo "=== WS-EV-1: tests/ file staged, write_tests=pending → gate approves ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="ev1-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"
# Stage a test file
mkdir -p "$REPO/tests"
echo "test content" > "$REPO/tests/my-test.sh"
git -C "$REPO" add tests/my-test.sh

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"approve"'; then
    pass "WS-EV-1. tests/ staged + write_tests=pending → approve"
else
    fail "WS-EV-1. expected approve, got: $GATE_OUT"
fi

echo ""
echo "=== WS-EV-2: docs/*.md file staged, docs=pending → gate approves ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="ev2-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT docs "$SID")"
# Stage a doc file
mkdir -p "$REPO/docs"
echo "doc content" > "$REPO/docs/guide.md"
git -C "$REPO" add docs/guide.md

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"approve"'; then
    pass "WS-EV-2. docs/ staged + docs=pending → approve"
else
    fail "WS-EV-2. expected approve, got: $GATE_OUT"
fi

echo ""
echo "=== WS-EV-3: no tests/ staged, write_tests=pending → gate blocks ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="ev3-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"
# Stage a non-test file only
echo "source code" > "$REPO/app.js"
git -C "$REPO" add app.js

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"block"' && echo "$GATE_OUT" | grep -q 'write_tests'; then
    pass "WS-EV-3. no tests/ staged + write_tests=pending → block mentioning write_tests"
else
    fail "WS-EV-3. expected block mentioning write_tests, got: $GATE_OUT"
fi

echo ""
echo "=== WS-EV-4: no docs staged, docs=pending → gate blocks ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="ev4-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT docs "$SID")"
# Stage a non-doc file only
echo "source code" > "$REPO/app.js"
git -C "$REPO" add app.js

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"block"' && echo "$GATE_OUT" | grep -q 'docs'; then
    pass "WS-EV-4. no docs staged + docs=pending → block mentioning docs"
else
    fail "WS-EV-4. expected block mentioning docs, got: $GATE_OUT"
fi

echo ""
echo "=== WS-EV-5: claude-global/ only staged, write_tests=pending → gate blocks ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="ev5-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"
# Stage a file in claude-global/ only (no tests/)
mkdir -p "$REPO/claude-global"
echo "config" > "$REPO/claude-global/settings.json"
git -C "$REPO" add claude-global/settings.json

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"block"' && echo "$GATE_OUT" | grep -q 'write_tests'; then
    pass "WS-EV-5. claude-global/ only + write_tests=pending → block (no exempt)"
else
    fail "WS-EV-5. expected block mentioning write_tests, got: $GATE_OUT"
fi

# ===========================================================================
# workflow-mark.js — MARK_STEP rejection + NOT_NEEDED handlers
# ===========================================================================

echo ""
echo "=== WS-EV-6: MARK_STEP write_tests_complete → rejected, NOT recorded ==="

REPO=$(setup_repo)
SID="ev6-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_write_tests_complete>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

if echo "$MARK_OUT" | grep -q "NOT recorded"; then
    pass "WS-EV-6a. MARK_STEP write_tests_complete → additionalContext contains 'NOT recorded'"
else
    fail "WS-EV-6a. expected 'NOT recorded' in output, got: $MARK_OUT"
fi

ACTUAL_STATUS=$(read_state_status "$SID" "write_tests")
if [ "$ACTUAL_STATUS" = "pending" ]; then
    pass "WS-EV-6b. write_tests state remains pending"
else
    fail "WS-EV-6b. expected write_tests=pending, got: $ACTUAL_STATUS"
fi

echo ""
echo "=== WS-EV-7: MARK_STEP docs_complete → rejected, NOT recorded ==="

REPO=$(setup_repo)
SID="ev7-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT docs "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_docs_complete>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

if echo "$MARK_OUT" | grep -q "NOT recorded"; then
    pass "WS-EV-7a. MARK_STEP docs_complete → additionalContext contains 'NOT recorded'"
else
    fail "WS-EV-7a. expected 'NOT recorded' in output, got: $MARK_OUT"
fi

ACTUAL_STATUS=$(read_state_status "$SID" "docs")
if [ "$ACTUAL_STATUS" = "pending" ]; then
    pass "WS-EV-7b. docs state remains pending"
else
    fail "WS-EV-7b. expected docs=pending, got: $ACTUAL_STATUS"
fi

echo ""
echo "=== WS-EV-8: WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason> → write_tests=skipped ==="

REPO=$(setup_repo)
SID="ev8-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: hook refactor, no test coverage affected>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-EV-8. WORKFLOW_WRITE_TESTS_NOT_NEEDED → write_tests=skipped" \
    "$SID" "write_tests" "skipped"

EV8_REASON=$(read_state_field "$SID" "write_tests" "skip_reason")
if [ "$EV8_REASON" = "hook refactor, no test coverage affected" ]; then
    pass "WS-EV-8b. write_tests.skip_reason recorded"
else
    fail "WS-EV-8b. expected skip_reason='hook refactor, no test coverage affected', got: $EV8_REASON"
fi

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
