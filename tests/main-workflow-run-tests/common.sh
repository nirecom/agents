# shellcheck shell=bash
# Shared helpers + fixtures for the main-workflow-run-tests dispatcher.
# Sourced by main-workflow-run-tests.sh and the case-group files in this folder.

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

# LAST_HOOK_STDOUT / LAST_HOOK_EXIT — populated by every hook-invocation helper
# below so callers (notably check_state_file_absent) can assert the hook cleanly
# no-op'd (exit 0 + valid JSON) rather than crashed. A crash also writes no state,
# so the state-file check alone cannot distinguish "clean no-op" from "crashed".
LAST_HOOK_STDOUT=""
LAST_HOOK_EXIT=0

# run_run_tests_hook <command> <exit_code> <session_id>
# Builds the PostToolUse stdin JSON and pipes it to the hook.
# Escapes command for JSON embedding.
run_run_tests_hook() {
    local command="$1" exit_code="$2" sid="$3"
    # Escape backslashes and double quotes for JSON
    local esc=${command//\\/\\\\}
    esc=${esc//\"/\\\"}
    local json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$esc\"},\"tool_response\":{\"exit_code\":$exit_code},\"session_id\":\"$sid\"}"
    # Capture stdout + exit code instead of swallowing with `|| true`. The `local`
    # declaration is split from the assignment so `set -e` cannot abort here and
    # $? reflects the hook's real exit (a `local x=$(...)` would mask the code).
    LAST_HOOK_STDOUT=$(echo "$json" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$RUN_TESTS_HOOK" 2>/dev/null)
    LAST_HOOK_EXIT=$?
    printf '%s' "$LAST_HOOK_STDOUT"
}

# run_run_tests_hook_multiline <command> <exit_code> <session_id>
# Newline-safe variant of run_run_tests_hook. Builds the stdin JSON via node
# JSON.stringify so embedded literal newlines in <command> are encoded as \n
# (the manual bash escaping in run_run_tests_hook only handles quotes/backslashes,
# not newlines, and would emit invalid JSON for a multiline command).
run_run_tests_hook_multiline() {
    local command="$1" exit_code="$2" sid="$3"
    local json
    json=$(node -e "
const payload = {
  tool_name: 'Bash',
  tool_input: { command: process.argv[1] },
  tool_response: { exit_code: parseInt(process.argv[2], 10) },
  session_id: process.argv[3]
};
process.stdout.write(JSON.stringify(payload));
" "$command" "$exit_code" "$sid" 2>/dev/null)
    LAST_HOOK_STDOUT=$(echo "$json" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$RUN_TESTS_HOOK" 2>/dev/null)
    LAST_HOOK_EXIT=$?
    printf '%s' "$LAST_HOOK_STDOUT"
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
    LAST_HOOK_STDOUT=$(echo "$json" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$RUN_TESTS_HOOK" 2>/dev/null)
    LAST_HOOK_EXIT=$?
    printf '%s' "$LAST_HOOK_STDOUT"
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
# Returns 0 (true) only when the hook cleanly no-op'd: exit 0 + valid-JSON stdout
# AND no run_tests state was written. A crash / non-JSON stdout also writes no
# state, so the state-file check alone would falsely pass; the exit+JSON guard
# distinguishes a clean no-op from a crash. Must be called after a helper that
# populated LAST_HOOK_EXIT / LAST_HOOK_STDOUT (all run_run_tests_hook* variants).
check_state_file_absent() {
    local sid="$1"
    local state_file="$WORKFLOW_DIR/$sid.json"
    # Hook must have exited 0 (a crash exits non-zero and also writes no state).
    if [ "${LAST_HOOK_EXIT:-1}" -ne 0 ]; then
        return 1
    fi
    # Hook stdout must be valid JSON (a clean no-op prints `{}`; empty is treated
    # as `{}`). A crash may print a partial/garbage payload — reject it.
    if ! printf '%s' "${LAST_HOOK_STDOUT:-}" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{JSON.parse(d||"{}")}catch(e){process.exit(1)}})' 2>/dev/null; then
        return 1
    fi
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
