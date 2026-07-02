#!/usr/bin/env bash
# Tests: hooks/workflow-run-tests.js
# Tags: workflow, tests, runner, hook, bin, scope:common
# L3 gap (what this test does NOT catch):
# - Real Claude Code session where PostToolUse fires after a live bash test run
# - Actual hook registration and event delivery via settings.json
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
# Tests for hooks/workflow-run-tests.js
# This hook is a PostToolUse handler that auto-marks run_tests based on Bash command + exit code.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Windows-compatible path for require() inside node -e scripts:
# Git Bash /c/... paths fail in require() on Windows (Node maps /c/ to C:\c\ not C:\).
DOTFILES_WIN="$(cygpath -m "$DOTFILES_DIR" 2>/dev/null || echo "$DOTFILES_DIR")"
RUN_TESTS_HOOK="$DOTFILES_DIR/hooks/workflow-run-tests.js"
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

# run_run_tests_hook_with_stdout <command> <exit_code> <session_id> <stdout_content>
# Builds the PostToolUse stdin JSON with tool_response.stdout included.
# Uses node JSON.stringify to safely embed command and stdout_content (handles
# quotes, newlines, backslashes without manual escaping).
run_run_tests_hook_with_stdout() {
    local command="$1" exit_code="$2" sid="$3" stdout_content="$4"
    # Use node to build the JSON payload safely — avoids manual bash escaping of
    # arbitrary content (newlines, quotes, backslashes in command/stdout).
    local json
    json=$(node -e "
const payload = {
  tool_name: 'Bash',
  tool_input: { command: process.argv[1] },
  tool_response: { exit_code: parseInt(process.argv[2], 10), stdout: process.argv[3] },
  session_id: process.argv[4]
};
process.stdout.write(JSON.stringify(payload));
" "$command" "$exit_code" "$stdout_content" "$sid" 2>/dev/null)
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

# seed_write_tests <session_id> <status>
# Seeds the session state file with write_tests at the given status by calling
# markStep directly. markStep creates a full step skeleton (all other steps
# pending) and is preserved by subsequent hook runs against the same sid.
# The run_tests guard (#1139) reads write_tests status before marking complete.
seed_write_tests() {
    local sid="$1" status="$2"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node -e "
      const m = require('$DOTFILES_WIN/hooks/lib/workflow-state');
      m.markStep(process.argv[1], 'write_tests', process.argv[2]);
    " "$sid" "$status" >/dev/null 2>&1 || true
}

# seed_run_tests <session_id> <status>
# Seeds the session state file with run_tests at the given status by calling
# markStep directly. Used by C-DEMOTE to pre-populate run_tests=complete before
# the demotion test fires.
seed_run_tests() {
    local sid="$1" status="$2"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node -e "
      const m = require('$DOTFILES_WIN/hooks/lib/workflow-state');
      m.markStep(process.argv[1], 'run_tests', process.argv[2]);
    " "$sid" "$status" >/dev/null 2>&1 || true
}

# get_write_tests_status <session_id>
# Reads write_tests.status from the workflow state file. Prints status or "absent".
get_write_tests_status() {
    local sid="$1"
    node -e "
try {
  const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  console.log(s.steps && s.steps.write_tests ? s.steps.write_tests.status : 'absent');
} catch(e) { console.log('absent'); }
" "$WORKFLOW_DIR/$sid.json" 2>/dev/null || echo "absent"
}

# ---------------------------------------------------------------------------
# === Normal cases ===
# ---------------------------------------------------------------------------

echo "=== workflow-run-tests: Normal cases ==="

# N1: pytest tests/ + exit=0 → run_tests: pending
# C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
# a bare runner with no contract → active demotion to pending.
SID="n1-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook "pytest tests/" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "N1. pytest tests/ + exit=0 → run_tests=pending (C′: no contract → active demotion)"
else
    fail "N1. pytest tests/ + exit=0 → expected run_tests=pending (C′: no contract), got: $STATUS"
fi

# N2: bash tests/feature-foo.sh + exit=0 → run_tests: pending
# C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
# a bare runner with no contract → active demotion to pending.
SID="n2-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook "bash tests/feature-foo.sh" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "N2. bash tests/feature-foo.sh + exit=0 → run_tests=pending (C′: no contract → active demotion)"
else
    fail "N2. bash tests/feature-foo.sh + exit=0 → expected run_tests=pending (C′: no contract), got: $STATUS"
fi

# N3: timeout 120 bash tests/bar.sh + exit=0 → run_tests: pending
# C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
# a bare runner with no contract → active demotion to pending.
SID="n3-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook "timeout 120 bash tests/bar.sh" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "N3. timeout 120 bash tests/bar.sh + exit=0 → run_tests=pending (C′: no contract → active demotion)"
else
    fail "N3. timeout 120 bash tests/bar.sh + exit=0 → expected run_tests=pending (C′: no contract), got: $STATUS"
fi

# ---------------------------------------------------------------------------
# === write_tests guard cases (#1139) ===
# The hook must only mark run_tests=complete when write_tests is complete or
# skipped. If write_tests is pending/absent, the exit=0 mark is suppressed so a
# write-tests subagent running the suite cannot prematurely satisfy run_tests.
# Fail-open: the exit≠0 (pending) branch is unaffected by the guard.
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-run-tests: write_tests guard cases (#1139) ==="

# G1: write_tests=complete + bash tests/foo.sh exit=0 → run_tests=pending
# C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
# a bare runner with no contract → active demotion to pending (guard no longer the binding constraint here).
SID="g1-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook "bash tests/foo.sh" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "G1. write_tests=complete + exit=0 + no contract → run_tests=pending (C′: contract absent → active demotion)"
else
    fail "G1. write_tests=complete + exit=0 + no contract → expected run_tests=pending (C′), got: $STATUS"
fi

# G2: write_tests=skipped + pytest tests/ exit=0 → run_tests=pending
# C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
# a bare runner with no contract → active demotion to pending.
SID="g2-$$-$RANDOM"
seed_write_tests "$SID" "skipped"
run_run_tests_hook "pytest tests/" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "G2. write_tests=skipped + exit=0 + no contract → run_tests=pending (C′: contract absent → active demotion)"
else
    fail "G2. write_tests=skipped + exit=0 + no contract → expected run_tests=pending (C′), got: $STATUS"
fi

# G3: write_tests=pending + bash tests/foo.sh exit=0 → run_tests NOT complete (guard blocks)
SID="g3-$$-$RANDOM"
seed_write_tests "$SID" "pending"
run_run_tests_hook "bash tests/foo.sh" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" != "complete" ]; then
    pass "G3. write_tests=pending + exit=0 → run_tests NOT complete (guard blocks), got: $STATUS"
else
    fail "G3. write_tests=pending + exit=0 → expected NOT complete (guard blocks), got: $STATUS"
fi

# G4: no state file at all + pytest tests/ exit=0 → run_tests NOT complete
# (write_tests absent = not complete/skipped → guard blocks; readState fail-open)
SID="g4-$$-$RANDOM"
# Intentionally no seed — no state file exists for this sid.
run_run_tests_hook "pytest tests/" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" != "complete" ]; then
    pass "G4. no state file + exit=0 → run_tests NOT complete (write_tests absent), got: $STATUS"
else
    fail "G4. no state file + exit=0 → expected NOT complete (write_tests absent), got: $STATUS"
fi

# G5: write_tests=pending + bash tests/foo.sh exit=1 → run_tests=pending + last_run_failed
# (exit≠0 branch is unaffected by the guard — failures must still be recorded)
SID="g5-$$-$RANDOM"
seed_write_tests "$SID" "pending"
run_run_tests_hook "bash tests/foo.sh" 1 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "G5. write_tests=pending + exit=1 → run_tests=pending (guard does not affect failure branch)"
else
    fail "G5. write_tests=pending + exit=1 → expected run_tests=pending, got: $STATUS"
fi
G5_FAILED=$(node -e "
try {
  const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const rt = s.steps && s.steps.run_tests;
  console.log(rt && rt.last_run_failed === true ? 'yes' : 'no');
} catch(e) { console.log('no'); }
" "$WORKFLOW_DIR/$SID.json" 2>/dev/null || echo "no")
if [ "$G5_FAILED" = "yes" ]; then
    pass "G5b. write_tests=pending + exit=1 → last_run_failed=true (failure branch intact)"
else
    fail "G5b. write_tests=pending + exit=1 → expected last_run_failed=true, got: $G5_FAILED"
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

# ED8: ls tests/ && pytest tests/ + exit=0 → run_tests: pending
# C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
# a bare runner with no contract → active demotion to pending.
SID="ed8-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook "ls tests/ && pytest tests/" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "ED8. ls tests/ && pytest tests/ + exit=0 → run_tests=pending (C′: no contract → active demotion)"
else
    fail "ED8. ls tests/ && pytest tests/ + exit=0 → expected pending (C′: no contract), got: $STATUS"
fi

# ED9: git -C /some/path add tests/foo.sh + exit=0 → state absent (bare git -C false-positive guard)
SID="ed9-$$-$RANDOM"
run_run_tests_hook "git -C /some/path add tests/foo.sh" 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED9. git -C <path> add tests/foo.sh + exit=0 → state absent/unchanged (bare git -C excluded)"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED9. git -C <path> add tests/foo.sh + exit=0 → expected absent (bare git -C), got run_tests=$STATUS"
fi

# ED10: git -C "path with spaces" add tests/foo.sh + exit=0 → state absent (quoted -C path guard)
SID="ed10-$$-$RANDOM"
run_run_tests_hook 'git -C "path with spaces" add tests/foo.sh' 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED10. git -C \"path with spaces\" add tests/foo.sh + exit=0 → state absent/unchanged (quoted -C excluded)"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED10. git -C \"path with spaces\" add tests/foo.sh + exit=0 → expected absent (quoted -C), got run_tests=$STATUS"
fi

# ED11: node script.js && wc -l tests/foo.sh + exit=0 → state absent
# (compound: no segment is a test runner; tests/ appears only in a read-only wc segment)
SID="ed11-$$-$RANDOM"
run_run_tests_hook "node script.js && wc -l tests/foo.sh" 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED11. node script.js && wc -l tests/foo.sh + exit=0 → state absent (no runner segment)"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED11. node script.js && wc -l tests/foo.sh + exit=0 → expected absent (non-runner segment refs tests/), got run_tests=$STATUS"
fi

# ED12: cd repo && pytest tests/ + exit=0 → run_tests: pending
# C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
# a bare runner with no contract → active demotion to pending.
SID="ed12-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook "cd repo && pytest tests/" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "ED12. cd repo && pytest tests/ + exit=0 → run_tests=pending (C′: no contract → active demotion)"
else
    fail "ED12. cd repo && pytest tests/ + exit=0 → expected pending (C′: no contract), got: $STATUS"
fi

# ED13: echo "a && pytest tests/" + exit=0 → state absent (quote-aware split regression)
# (the && is inside double quotes — must NOT split; whole command is a read-only echo)
SID="ed13-$$-$RANDOM"
run_run_tests_hook 'echo "a && pytest tests/"' 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED13. echo \"a && pytest tests/\" + exit=0 → state absent (quote-aware: no split inside quotes)"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED13. echo \"a && pytest tests/\" + exit=0 → expected absent (quoted && must not split), got run_tests=$STATUS"
fi

# ED14: node x.js || wc -l tests/foo.sh + exit=0 → state absent (|| operator false-positive guard)
# (segment 1 `node x.js` is not a test runner; segment 2 `wc -l tests/foo.sh` is read-only excluded;
#  splitting on || must prevent bare tests/ mention from triggering complete)
SID="ed14-$$-$RANDOM"
run_run_tests_hook "node x.js || wc -l tests/foo.sh" 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED14. node x.js || wc -l tests/foo.sh + exit=0 → state absent (|| operator: non-runner segment refs tests/)"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED14. node x.js || wc -l tests/foo.sh + exit=0 → expected absent (|| split: non-runner + read-only), got run_tests=$STATUS"
fi

# ED15: node gen.js | grep tests/foo.sh + exit=0 → state absent (| pipe operator false-positive guard)
# (segment 1 `node gen.js` has no test indicator; segment 2 `grep tests/foo.sh` is read-only excluded;
#  splitting on | must prevent false complete)
SID="ed15-$$-$RANDOM"
run_run_tests_hook "node gen.js | grep tests/foo.sh" 0 "$SID"
if check_state_file_absent "$SID"; then
    pass "ED15. node gen.js | grep tests/foo.sh + exit=0 → state absent (| pipe: read-only segment refs tests/)"
else
    STATUS=$(get_run_tests_status "$SID")
    fail "ED15. node gen.js | grep tests/foo.sh + exit=0 → expected absent (| pipe: non-runner + read-only), got run_tests=$STATUS"
fi

# ---------------------------------------------------------------------------
# === Idempotency cases ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-run-tests: Idempotency cases ==="

# I1: run exit=0 twice → run_tests=pending (both runs: no contract → active demotion)
# C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
# a bare runner with no contract → active demotion to pending.
SID="i1-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook "pytest tests/" 0 "$SID"
run_run_tests_hook "pytest tests/" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "I1. pytest + exit=0 twice → run_tests=pending (C′: no contract → active demotion on both runs)"
else
    fail "I1. pytest + exit=0 twice → expected pending (C′: no contract), got: $STATUS"
fi

# I2: exit=0 then exit=1 → pending. Under C′ the first call (exit=0, no contract) already yields pending
#  (active demotion — no run-all.sh provenance / no contract), and the second call (exit=1) stays pending via
#  the exit≠0 fast-path. Final status pending holds regardless of order. (write_tests seed retained; harmless.)
SID="i2-$$-$RANDOM"
seed_write_tests "$SID" "complete"
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
# === workflow-run-tests: C′ contract-trust cases (#1242) ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-run-tests: C' contract-trust cases (#1242) ==="

# C-DEMOTE: seed run_tests=complete (stale), then run a non-run-all.sh command
# with no contract → active demotion back to pending.
# Verifies C1 fix: stale complete + no-contract test command → active demotion.
SID="cdemote-$$-$RANDOM"
seed_write_tests "$SID" "complete"
seed_run_tests "$SID" "complete"
run_run_tests_hook "bash tests/foo.sh" 0 "$SID"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "C-DEMOTE. stale run_tests=complete + no-provenance + no-contract → active demotion to pending"
else
    fail "C-DEMOTE. stale run_tests=complete + no-provenance + no-contract → expected pending (C1 demotion), got: $STATUS"
fi

# C-VALID: bash tests/run-all.sh tests/foo.sh, exit=0, valid contract (PASS=2 FAIL=0 SKIP=1 EXECUTED=3),
# write_tests=complete → run_tests=complete.
SID="cvalid-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh tests/foo.sh" \
    0 \
    "$SID" \
    "Results: PASS=2  FAIL=0  SKIP=1
RUN_CONTRACT: PASS=2 FAIL=0 SKIP=1 EXECUTED=3"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "complete" ]; then
    pass "C-VALID. run-all.sh + exit=0 + valid contract (PASS=2 FAIL=0 SKIP=1) + write_tests=complete → complete"
else
    fail "C-VALID. run-all.sh + exit=0 + valid contract → expected complete, got: $STATUS"
fi

# SKIPPED: absolute-path run-all.sh provenance (e.g. /home/user/agents/tests/run-all.sh or a worktree abs path)
# Because: RUN_ALL_SH_RE anchors on the relative `tests/run-all.sh` reference; an absolute path is a known
#   provenance false-NEGATIVE (documented Out-of-scope in the detail plan). Harmless: no contract in stdout → pending, never false-green.
# L3 gap: only a real session invoking run-all.sh via an absolute path would exercise this; not reproducible at this L2 layer.

# C-NOPROV: bash tests/foo.sh (no run-all.sh), exit=0, one valid RUN_CONTRACT line,
# write_tests=complete → pending (provenance fail).
SID="cnoprov-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/foo.sh" \
    0 \
    "$SID" \
    "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "C-NOPROV. bash tests/foo.sh (no run-all.sh) + valid contract → pending (provenance fail)"
else
    fail "C-NOPROV. no provenance + valid contract → expected pending, got: $STATUS"
fi

# C-NOMATCH: bash tests/run-all.sh, exit=0, contract with executed=0,
# write_tests=complete → pending (executed=0).
SID="cnomatch-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh" \
    0 \
    "$SID" \
    "RUN_CONTRACT: PASS=0 FAIL=0 SKIP=0 EXECUTED=0"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "C-NOMATCH. run-all.sh + executed=0 contract → pending (no-match gate)"
else
    fail "C-NOMATCH. run-all.sh + executed=0 → expected pending, got: $STATUS"
fi

# C-ALLSKIP: bash tests/run-all.sh, exit=0, all-skip contract (PASS=0 FAIL=0 SKIP=3 EXECUTED=3),
# write_tests=complete → pending (PASS+FAIL=0, all-skip boundary).
SID="callskip-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh" \
    0 \
    "$SID" \
    "RUN_CONTRACT: PASS=0 FAIL=0 SKIP=3 EXECUTED=3"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "C-ALLSKIP. run-all.sh + all-skip contract (PASS+FAIL=0) → pending (all-skip boundary)"
else
    fail "C-ALLSKIP. all-skip (PASS=0 FAIL=0 SKIP=3) → expected pending, got: $STATUS"
fi

# C-PIPE: bash tests/run-all.sh tests/*.sh | grep PASS, exit=0, stdout="PASS" only
# (RUN_CONTRACT line consumed by pipe — 0 contract lines), write_tests=complete → pending.
# Accidental pipe/filter masking → 0 contract lines → null → pending. U3 regression.
SID="cpipe-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh tests/*.sh | grep PASS" \
    0 \
    "$SID" \
    "PASS"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "C-PIPE. run-all.sh | grep (pipe consumed contract) + 0 contract lines → pending (U3 regression)"
else
    fail "C-PIPE. pipe drop of contract (0 lines) → expected pending, got: $STATUS"
fi

# C-FAIL: bash tests/run-all.sh, exit=1, valid contract (FAIL=0), write_tests=complete
# → pending (exit≠0 fast-path, regardless of contract content).
SID="cfail-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh" \
    1 \
    "$SID" \
    "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "C-FAIL. run-all.sh + exit=1 + valid contract → pending (exit≠0 fast-path)"
else
    fail "C-FAIL. exit=1 → expected pending (fast-path), got: $STATUS"
fi

# C-GUARD: bash tests/run-all.sh, exit=0, valid contract, write_tests=PENDING
# → run_tests NOT complete (PR #1165 write_tests guard preserved).
SID="cguard-$$-$RANDOM"
seed_write_tests "$SID" "pending"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh" \
    0 \
    "$SID" \
    "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" != "complete" ]; then
    pass "C-GUARD. valid contract + write_tests=pending → NOT complete (write_tests guard preserved), got: $STATUS"
else
    fail "C-GUARD. valid contract + write_tests=pending → expected NOT complete, got: $STATUS"
fi

# C-WRTSKIP: bash tests/run-all.sh, exit=0, valid contract, write_tests=skipped
# → run_tests=complete (skipped satisfies write_tests guard).
SID="cwrtskip-$$-$RANDOM"
seed_write_tests "$SID" "skipped"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh" \
    0 \
    "$SID" \
    "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "complete" ]; then
    pass "C-WRTSKIP. valid contract + write_tests=skipped → complete (skipped passes guard)"
else
    fail "C-WRTSKIP. valid contract + write_tests=skipped → expected complete, got: $STATUS"
fi

# C-DUPFORGE: bash tests/run-all.sh foo.sh; echo 'RUN_CONTRACT: ...', exit=0,
# stdout has TWO well-formed RUN_CONTRACT lines (real + forged), write_tests=complete
# → pending (exactly-one rule: ≥2 → ambiguous → active demotion).
SID="cdupforge-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh foo.sh; echo 'RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1'" \
    0 \
    "$SID" \
    "Results: PASS=1  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1
RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "C-DUPFORGE. 2 RUN_CONTRACT lines (real+forged) → pending (exactly-one: ambiguous)"
else
    fail "C-DUPFORGE. 2 contract lines → expected pending (exactly-one rule), got: $STATUS"
fi

# C-DUPLEGIT: bash tests/run-all.sh (no echo), exit=0, stdout has TWO well-formed
# RUN_CONTRACT lines (fixture/stdout-pollution collision, not deliberate forge),
# write_tests=complete → pending (exactly-one: 2 lines → ambiguous).
SID="cduplegit-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh" \
    0 \
    "$SID" \
    "Results: PASS=1  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1
RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "C-DUPLEGIT. 2 RUN_CONTRACT lines (fixture collision, no echo in cmd) → pending (exactly-one: ambiguous)"
else
    fail "C-DUPLEGIT. 2 contract lines (fixture collision) → expected pending (exactly-one rule), got: $STATUS"
fi

# C-XFORM: bash tests/run-all.sh, exit=0, stdout ONE valid RUN_CONTRACT line
# (representing a sed-rewritten value — injected directly as fixture, no sed executed here),
# write_tests=complete → COMPLETE.
#
# DOCUMENTED ACCEPTED SCOPE BOUNDARY: deliberate stdout value-rewriting (sed/awk) is
# OUT OF SCOPE for #1242, which targets accidental pipe/filter masking. Deliberate
# rewriting is at the same trust level as manual sentinel forgery — the contract is
# trusted here by design. See detail-plan axis (iv) "Accepted scope boundary".
SID="cxform-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh" \
    0 \
    "$SID" \
    "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "complete" ]; then
    pass "C-XFORM. run-all.sh + valid contract (deliberate sed-rewrite injected) → complete (accepted scope boundary)"
else
    fail "C-XFORM. deliberate rewrite accepted boundary → expected complete, got: $STATUS"
fi

# C-PASSTHRU: bash tests/run-all.sh, exit=0, stdout with honest FAIL=2 contract
# (common pass-through filters like tee/cat preserve honest FAIL count),
# write_tests=complete → pending (FAIL>0 → not complete).
# Common pass-through filters keep the honest FAIL count → no false-green.
SID="cpassthru-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh" \
    0 \
    "$SID" \
    "Results: PASS=1  FAIL=2  SKIP=0
RUN_CONTRACT: PASS=1 FAIL=2 SKIP=0 EXECUTED=3"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "C-PASSTHRU. run-all.sh + FAIL=2 contract (tee/cat preserves honest count) → pending"
else
    fail "C-PASSTHRU. FAIL=2 honest contract → expected pending, got: $STATUS"
fi

# C-FILTERDROP: bash tests/run-all.sh tests/foo.sh | tail -n 1, exit=0,
# stdout="Results: PASS=1  FAIL=0  SKIP=0" (RUN_CONTRACT line dropped by tail),
# write_tests=complete → pending (0 contract lines → null → pending).
# Accidental filter drop → 0 contract lines → null → pending.
SID="cfilterdrop-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh tests/foo.sh | tail -n 1" \
    0 \
    "$SID" \
    "Results: PASS=1  FAIL=0  SKIP=0"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "C-FILTERDROP. run-all.sh | tail (drops contract) → 0 contract lines → pending"
else
    fail "C-FILTERDROP. contract dropped by tail (0 lines) → expected pending, got: $STATUS"
fi

# C-MALFORMED: non-integer contract field (PASS=abc) does not match the strict \d+ regex
# → 0 well-formed lines → null → active demotion to pending. Exercises the parseInt/isNaN
# guard (detail-plan Risks §3).
SID="cmalformed-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh" \
    0 \
    "$SID" \
    "Results: PASS=1  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=abc FAIL=0 SKIP=0 EXECUTED=1"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "C-MALFORMED. non-integer contract field (PASS=abc) → 0 well-formed lines → pending"
else
    fail "C-MALFORMED. non-integer contract field (PASS=abc) → expected pending (null → demotion), got: $STATUS"
fi

# C-BADORDER: contract fields in wrong order → strict fixed-order regex yields 0 well-formed
# lines → null → pending. Locks the fixed PASS/FAIL/SKIP/EXECUTED order (detail-plan axis iii:
# no forward-compat parser).
SID="cbadorder-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh" \
    0 \
    "$SID" \
    "Results: PASS=1  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=1 SKIP=0 FAIL=0 EXECUTED=1"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "pending" ]; then
    pass "C-BADORDER. contract fields in wrong order → 0 well-formed lines → pending"
else
    fail "C-BADORDER. contract fields in wrong order → expected pending (fixed-order regex), got: $STATUS"
fi

# C-VALID-IDEMP: two successive valid-contract runs remain complete (idempotency category;
# pairs with I1's two-no-contract-runs demotion).
SID="cvalididemp-$$-$RANDOM"
seed_write_tests "$SID" "complete"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh tests/foo.sh" \
    0 \
    "$SID" \
    "Results: PASS=2  FAIL=0  SKIP=1
RUN_CONTRACT: PASS=2 FAIL=0 SKIP=1 EXECUTED=3"
run_run_tests_hook_with_stdout \
    "bash tests/run-all.sh tests/foo.sh" \
    0 \
    "$SID" \
    "Results: PASS=2  FAIL=0  SKIP=1
RUN_CONTRACT: PASS=2 FAIL=0 SKIP=1 EXECUTED=3"
STATUS=$(get_run_tests_status "$SID")
if [ "$STATUS" = "complete" ]; then
    pass "C-VALID-IDEMP. two successive valid-contract runs → complete (idempotency)"
else
    fail "C-VALID-IDEMP. two successive valid-contract runs → expected complete, got: $STATUS"
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
