#!/usr/bin/env bash
# TDD tests for claude-global/hooks/workflow-run-tests.js
# This hook is a PostToolUse handler that auto-marks run_tests based on Bash command + exit code.
# NOTE: workflow-run-tests.js does NOT exist yet. All tests are expected to FAIL (TDD).
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_TESTS_HOOK="$DOTFILES_DIR/claude-global/hooks/workflow-run-tests.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 180 "$@"
    else
        perl -e 'alarm 180; exec @ARGV' -- "$@"
    fi
}

# ---------------------------------------------------------------------------
# Temporary workspace
# ---------------------------------------------------------------------------

TMPDIR_BASE=$(mktemp -d)
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# run_run_tests_hook <command> <exit_code> <session_id>
# Builds the PostToolUse stdin JSON and pipes it to the hook.
# Escapes command for JSON embedding.
run_run_tests_hook() {
    local command="$1" exit_code="$2" sid="$3"
    # Escape backslashes and double quotes for JSON
    local esc=${command//\\/\\\\}
    esc=${esc//\"/\\\"}
    local json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$esc\"},\"tool_response\":{\"exit_code\":$exit_code},\"session_id\":\"$sid\"}"
    echo "$json" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$RUN_TESTS_HOOK" 2>/dev/null || true
}

# get_run_tests_status <session_id>
# Reads run_tests.status from the workflow state file.
# Prints the status string, or "absent" if the file/key is missing.
get_run_tests_status() {
    local sid="$1"
    node -e "
try {
  const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  console.log(s.steps && s.steps.run_tests ? s.steps.run_tests.status : 'absent');
} catch(e) { console.log('absent'); }
" "$WORKFLOW_DIR/$sid.json" 2>/dev/null || echo "absent"
}

# check_state_file_absent <session_id>
# Returns 0 (true) if no state file exists for sid, or if run_tests key is absent.
check_state_file_absent() {
    local sid="$1"
    local state_file="$WORKFLOW_DIR/$sid.json"
    if [ ! -f "$state_file" ]; then
        return 0  # absent — ok
    fi
    local status
    status=$(get_run_tests_status "$sid")
    [ "$status" = "absent" ]
}

# ---------------------------------------------------------------------------
# === Normal cases ===
# ---------------------------------------------------------------------------

echo "=== workflow-run-tests: Normal cases ==="

# N1: pytest tests/ + exit=0 → run_tests: complete
SID="n1-$$-$RANDOM"
run_run_tests_hook "pytest tests/" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "complete" ]; then
    pass "N1. pytest tests/ + exit=0 → run_tests=complete"
else
    fail "N1. pytest tests/ + exit=0 → expected run_tests=complete, got: $STATUS"
fi

# N2: bash tests/feature-foo.sh + exit=0 → run_tests: complete
SID="n2-$$-$RANDOM"
run_run_tests_hook "bash tests/feature-foo.sh" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "complete" ]; then
    pass "N2. bash tests/feature-foo.sh + exit=0 → run_tests=complete"
else
    fail "N2. bash tests/feature-foo.sh + exit=0 → expected run_tests=complete, got: $STATUS"
fi

# N3: timeout 120 bash tests/bar.sh + exit=0 → run_tests: complete
SID="n3-$$-$RANDOM"
run_run_tests_hook "timeout 120 bash tests/bar.sh" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "complete" ]; then
    pass "N3. timeout 120 bash tests/bar.sh + exit=0 → run_tests=complete"
else
    fail "N3. timeout 120 bash tests/bar.sh + exit=0 → expected run_tests=complete, got: $STATUS"
fi

# ---------------------------------------------------------------------------
# === Error cases ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-run-tests: Error cases ==="

# E1: pytest tests/ + exit=1 → run_tests: pending (with last_run_failed)
SID="e1-$$-$RANDOM"
run_run_tests_hook "pytest tests/" 1 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "E1. pytest tests/ + exit=1 → run_tests=pending"
else
    fail "E1. pytest tests/ + exit=1 → expected run_tests=pending, got: $STATUS"
fi

# Also verify last_run_failed is set
E1_FAILED=$(node -e "
try {
  const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const rt = s.steps && s.steps.run_tests;
  console.log(rt && rt.last_run_failed === true ? 'yes' : 'no');
} catch(e) { console.log('no'); }
" "$WORKFLOW_DIR/$SID.json" 2>/dev/null || echo "no")
if [ "$E1_FAILED" = "yes" ]; then
    pass "E1b. pytest tests/ + exit=1 → last_run_failed=true"
else
    fail "E1b. pytest tests/ + exit=1 → expected last_run_failed=true, got: $E1_FAILED"
fi

# E2: bash tests/foo.sh + exit=2 → run_tests: pending
SID="e2-$$-$RANDOM"
run_run_tests_hook "bash tests/foo.sh" 2 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "E2. bash tests/foo.sh + exit=2 → run_tests=pending"
else
    fail "E2. bash tests/foo.sh + exit=2 → expected run_tests=pending, got: $STATUS"
fi

# ---------------------------------------------------------------------------
# === Edge cases — commands that should NOT trigger run_tests marking ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-run-tests: Edge cases (no-op commands) ==="

# ED1: ls tests/ + exit=0 → state absent/unchanged
SID="ed1-$$-$RANDOM"
run_run_tests_hook "ls tests/" 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED1. ls tests/ + exit=0 → state absent/unchanged"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED1. ls tests/ + exit=0 → expected absent, got run_tests=$STATUS"
fi

# ED2: cat tests/foo.sh + exit=0 → state absent/unchanged
SID="ed2-$$-$RANDOM"
run_run_tests_hook "cat tests/foo.sh" 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED2. cat tests/foo.sh + exit=0 → state absent/unchanged"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED2. cat tests/foo.sh + exit=0 → expected absent, got run_tests=$STATUS"
fi

# ED3: grep foo tests/ + exit=0 → state absent/unchanged
SID="ed3-$$-$RANDOM"
run_run_tests_hook "grep foo tests/" 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED3. grep foo tests/ + exit=0 → state absent/unchanged"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED3. grep foo tests/ + exit=0 → expected absent, got run_tests=$STATUS"
fi

# ED4: git diff tests/ + exit=0 → state absent/unchanged
SID="ed4-$$-$RANDOM"
run_run_tests_hook "git diff tests/" 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED4. git diff tests/ + exit=0 → state absent/unchanged"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED4. git diff tests/ + exit=0 → expected absent, got run_tests=$STATUS"
fi

# ED5: git add tests/foo.sh + exit=0 → state absent/unchanged
SID="ed5-$$-$RANDOM"
run_run_tests_hook "git add tests/foo.sh" 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED5. git add tests/foo.sh + exit=0 → state absent/unchanged"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED5. git add tests/foo.sh + exit=0 → expected absent, got run_tests=$STATUS"
fi

# ED6: git commit -m "fix tests/" + exit=0 → state absent/unchanged
SID="ed6-$$-$RANDOM"
run_run_tests_hook 'git commit -m "fix tests/"' 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED6. git commit -m \"fix tests/\" + exit=0 → state absent/unchanged"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED6. git commit -m \"fix tests/\" + exit=0 → expected absent, got run_tests=$STATUS"
fi

# ED7: echo "<<WORKFLOW_MARK_STEP_foo_complete>>" + exit=0 → state absent/unchanged (sentinel excluded)
SID="ed7-$$-$RANDOM"
run_run_tests_hook 'echo "<<WORKFLOW_MARK_STEP_foo_complete>>"' 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED7. sentinel echo + exit=0 → state absent/unchanged"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED7. sentinel echo + exit=0 → expected absent, got run_tests=$STATUS"
fi

# ED8: ls tests/ && pytest tests/ + exit=0 → state absent/unchanged
# (compound command: first token is ls, not a test runner)
SID="ed8-$$-$RANDOM"
run_run_tests_hook "ls tests/ && pytest tests/" 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED8. ls tests/ && pytest tests/ + exit=0 → state absent/unchanged (compound: first token ls)"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED8. ls tests/ && pytest tests/ + exit=0 → expected absent (compound cmd), got run_tests=$STATUS"
fi

# ---------------------------------------------------------------------------
# === Idempotency cases ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-run-tests: Idempotency cases ==="

# I1: run exit=0 twice → still complete
SID="i1-$$-$RANDOM"
run_run_tests_hook "pytest tests/" 0 "$SID"
run_run_tests_hook "pytest tests/" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "complete" ]; then
    pass "I1. pytest + exit=0 twice → run_tests=complete (idempotent)"
else
    fail "I1. pytest + exit=0 twice → expected complete, got: $STATUS"
fi

# I2: run exit=0 then exit=1 → reverts to pending (last-run-wins)
SID="i2-$$-$RANDOM"
run_run_tests_hook "pytest tests/" 0 "$SID"
run_run_tests_hook "pytest tests/" 1 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "I2. exit=0 then exit=1 → run_tests=pending (last-run-wins)"
else
    fail "I2. exit=0 then exit=1 → expected pending, got: $STATUS"
fi

# ---------------------------------------------------------------------------
# === Security cases ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-run-tests: Security cases ==="

# SC1: hook stdout contains no secrets/credentials — must output '{}'
SID="sc1-$$-$RANDOM"
OUTPUT=$(run_run_tests_hook "pytest tests/" 0 "$SID" 2>/dev/null || true)
if echo "$OUTPUT" | node -e "
let b=''; process.stdin.on('data',c=>b+=c);
process.stdin.on('end',()=>{
  const s=b.trim();
  // stdout must be empty or valid JSON starting with {
  if(s===''||s==='{}'){process.exit(0);}
  try{JSON.parse(s);process.exit(0);}catch(e){process.exit(1);}
})
" 2>/dev/null; then
    pass "SC1. hook stdout is empty or valid JSON (no raw secrets)"
else
    fail "SC1. hook stdout is not valid JSON or empty: $OUTPUT"
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
