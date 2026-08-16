#!/usr/bin/env bash
# Tests: hooks/block-tests-direct.js
# Tags: workflow, hook, bin, macos, env, write-tests-gate, exit-code, dir-names-pin, scope:common, TL2
# Test suite for hooks/block-tests-direct.js PreToolUse hook.

# CLAUDE_BLOCK_TESTS_DIR_NAMES — what value each case is testing. Cases that do
# not pass it explicitly run with the variable UNSET (run_hook unsets it inside
# its subshell), so an exported value in the developer's shell can never
# redirect what the default-path cases (A*, B*, C15-C21, D*, E*, F*) exercise:
# they assert the hook's own built-in default, `tests`. C22/C23 pin a custom
# list to prove the override works; C24 pins the literal default so the built-in
# and the documented default cannot drift apart silently.

# Exit-code contract: this PreToolUse hook expresses its verdict in the stdout
# JSON (decision approve/block), NOT in its exit status, so it must exit 0 in
# BOTH directions. Every subprocess call below captures the real status and
# asserts 0 — a swallowed `|| true` would hide a crash-after-printing.
set -uo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DOTFILES_DIR/hooks/block-tests-direct.js"
ERRORS=0
PASS_COUNT=0

# ---------------------------------------------------------------------------
# Portable timeout wrapper (macOS does not have timeout)
# ---------------------------------------------------------------------------
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# ---------------------------------------------------------------------------
# Temp dir / env file setup
# ---------------------------------------------------------------------------
# Fixture isolation (rules/test/fixture-isolation.md): the parent Claude Code
# session exports CLAUDE_SESSION_ID, so a hook spawned here would resolve the
# LIVE session and read its real state instead of the fixture below.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# Two spellings of the same temp dir: the shell writes fixtures through the
# POSIX path, node resolves the drive-letter form.
TMPDIR_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t btest)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
TMPDIR_ROOT_N="$(node_path "$TMPDIR_ROOT")"
CLAUDE_WORKFLOW_DIR="$TMPDIR_ROOT/workflow"
CLAUDE_ENV_FILE="$TMPDIR_ROOT/claude_env"
WF_DIR_N="$TMPDIR_ROOT_N/workflow"
ENV_FILE_N="$TMPDIR_ROOT_N/claude_env"
mkdir -p "$CLAUDE_WORKFLOW_DIR"

cleanup() {
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: write state file
# make_state <session_id> <write_tests_status>
# ---------------------------------------------------------------------------
make_state() {
    local session_id="$1"
    local write_tests_status="$2"
    cat > "$CLAUDE_WORKFLOW_DIR/${session_id}.json" <<EOF
{
  "version": 1,
  "session_id": "${session_id}",
  "steps": {
    "write_tests": {"status": "${write_tests_status}", "updated_at": null}
  }
}
EOF
}

# ---------------------------------------------------------------------------
# Helper: write env file with session id
# make_env_file <session_id>
# ---------------------------------------------------------------------------
make_env_file() {
    local session_id="$1"
    printf 'CLAUDE_SESSION_ID=%s\n' "$session_id" > "$CLAUDE_ENV_FILE"
}

# run_hook <json> [KEY=VAL ...]. Sets HOOK_RC (real exit status) and HOOK_OUT
# (stdout). CLAUDE_BLOCK_TESTS_DIR_NAMES is unset first, so an unpinned caller
# exercises the hook's built-in default, not an inherited value.
# IMPORTANT: call bare, never as `result=$(run_hook ...)` — that forks
# run_hook into a subshell, so `HOOK_RC=$?` assigns to the subshell's copy
# and the caller's HOOK_RC keeps a stale value (D24-mutation pins this).
HOOK_RC=0
HOOK_OUT=""
run_hook() {
    local json="$1"
    shift
    local extra_env=("$@")
    # Write JSON to a temp file to avoid shell quoting issues
    local input_file
    input_file="$(mktemp "$TMPDIR_ROOT/hook_input.XXXXXX")"
    printf '%s' "$json" > "$input_file"
    HOOK_OUT=$(
        (
            unset CLAUDE_BLOCK_TESTS_DIR_NAMES
            export CLAUDE_ENV_FILE="$ENV_FILE_N"
            export CLAUDE_WORKFLOW_DIR="$WF_DIR_N"
            for kv in "${extra_env[@]+"${extra_env[@]}"}"; do export "$kv"; done
            run_with_timeout node "$HOOK" < "$input_file" 2>/dev/null
        )
    )
    HOOK_RC=$?
    rm -f "$input_file"
}

# decision_of <hook-stdout> — the `decision` field, or the empty string when the
# payload is not the JSON object the hook is supposed to print.
decision_of() {
    node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
fail() {
    echo "FAIL: $1"
    ERRORS=$((ERRORS + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

# _assert_decision <want> <id> <desc> <json> [KEY=VAL ...]
# Both directions assert the SAME exit-code contract (rc=0): the verdict lives in
# the JSON, so `block` must not be expressed as a non-zero status either.
_assert_decision() {
    local want="$1" id="$2" desc="$3" json="$4"
    shift 4
    local extra_env=("$@")
    local result decision problems=""
    run_hook "$json" "${extra_env[@]+"${extra_env[@]}"}"
    result="$HOOK_OUT"
    decision=$(decision_of "$result")
    [ "$decision" = "$want" ] || problems="$problems [decision='${decision:-<none>}', expected ${want}]"
    [ "$HOOK_RC" -eq 0 ] || problems="$problems [hook exited ${HOOK_RC}, a PreToolUse hook must exit 0 for a ${want} verdict]"
    if [ -z "$problems" ]; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} —${problems} raw: ${result}"
    fi
}

assert_approve() { _assert_decision approve "$@"; }
assert_block() { _assert_decision block "$@"; }

# ---------------------------------------------------------------------------
# Session setup shortcut: set env file + state file together
# setup_session <session_id> <write_tests_status>
# ---------------------------------------------------------------------------
setup_session() {
    local session_id="$1"
    local status="$2"
    make_env_file "$session_id"
    make_state "$session_id" "$status"
}

# ===========================================================================
# Section A — Normal cases
# ===========================================================================
echo ""
echo "=== Section A — Normal cases ==="

# A1: Write + src/foo.js + pending → approve (no tests/ component)
setup_session "sess-a1" "pending"
assert_approve "A1" "Write + src/foo.js + pending → approve (no tests/ component)" \
    '{"tool_name":"Write","tool_input":{"file_path":"src/foo.js"},"session_id":"sess-a1","agent_id":""}'

# A2: Write + tests/foo.sh + pending + no agent_id → block
setup_session "sess-a2" "pending"
assert_block "A2" "Write + tests/foo.sh + pending + no agent_id → block" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a2","agent_id":""}'

# A3 (#2013): in_progress is now an UNSETTLED state, not a settled one. The
# PostToolUse auto-mark records write_tests in_progress on the first dispatch,
# so approving on in_progress would open the direct-write path for the whole
# step. Only `complete` / `skipped` (A4/A5) settle it.
setup_session "sess-a3" "in_progress"
assert_block "A3" "Write + tests/foo.sh + in_progress → block (unsettled after the #2013 auto-mark)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a3","agent_id":""}'

# A4: Write + tests/foo.sh + complete → approve
setup_session "sess-a4" "complete"
assert_approve "A4" "Write + tests/foo.sh + complete → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a4","agent_id":""}'

# A5: Write + tests/foo.sh + skipped → approve
setup_session "sess-a5" "skipped"
assert_approve "A5" "Write + tests/foo.sh + skipped → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a5","agent_id":""}'

# A6: Edit + tests/foo.sh + pending → block
setup_session "sess-a6" "pending"
assert_block "A6" "Edit + tests/foo.sh + pending → block" \
    '{"tool_name":"Edit","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a6","agent_id":""}'

# A7: MultiEdit + tests/foo.sh + pending → block
setup_session "sess-a7" "pending"
assert_block "A7" "MultiEdit + tests/foo.sh + pending → block" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a7","agent_id":""}'

# A8: Bash + no file_path + pending → approve (tool_name not in Write/Edit/MultiEdit)
setup_session "sess-a8" "pending"
assert_approve "A8" "Bash + no file_path + pending → approve (wrong tool)" \
    '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"sess-a8","agent_id":""}'

# A9: Write + tests/foo.sh + pending + agent_id="sub-xxx" → approve (subagent)
setup_session "sess-a9" "pending"
assert_approve "A9" "Write + tests/foo.sh + pending + agent_id=sub-xxx → approve (subagent)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a9","agent_id":"sub-xxx"}'

# ===========================================================================
# Section B — Error / fail-open
# ===========================================================================
echo ""
echo "=== Section B — Error / fail-open ==="

# B10: no CLAUDE_ENV_FILE env var set → approve (fail-open)
b10_input='{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-b10","agent_id":""}'
b10_input_file="$(mktemp "$TMPDIR_ROOT/b10_input.XXXXXX")"
printf '%s' "$b10_input" > "$b10_input_file"
b10_result=$(
    (
        unset CLAUDE_ENV_FILE CLAUDE_BLOCK_TESTS_DIR_NAMES
        export CLAUDE_WORKFLOW_DIR="$WF_DIR_N"
        run_with_timeout node "$HOOK" < "$b10_input_file" 2>/dev/null
    )
)
b10_rc=$?
rm -f "$b10_input_file"
b10_decision=$(decision_of "$b10_result")
b10_problems=""
[ "$b10_decision" = "approve" ] || b10_problems="$b10_problems [decision='${b10_decision:-<none>}', expected approve]"
[ "$b10_rc" -eq 0 ] || b10_problems="$b10_problems [hook exited ${b10_rc}, expected 0]"
if [ -z "$b10_problems" ]; then
    pass "B10. no CLAUDE_ENV_FILE → approve (fail-open), hook exits 0"
else
    fail "B10. no CLAUDE_ENV_FILE →${b10_problems} raw: ${b10_result}"
fi

# B11: CLAUDE_ENV_FILE set with session_id but no state file → approve (fail-open)
make_env_file "sess-b11"
rm -f "$CLAUDE_WORKFLOW_DIR/sess-b11.json"
assert_approve "B11" "state file missing → approve (fail-open)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-b11","agent_id":""}'

# B12: state file JSON corrupt → approve (fail-open)
make_env_file "sess-b12"
printf 'NOT VALID JSON {{{{' > "$CLAUDE_WORKFLOW_DIR/sess-b12.json"
assert_approve "B12" "state file JSON corrupt → approve (fail-open)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-b12","agent_id":""}'

# B13: a state file whose `steps` map is empty. readState projects the FULL
# step list, materialising write_tests as `pending`, so the hook's `!status`
# fail-open branch is unreachable through readState and the unsettled verdict
# stands. The case pins that reality rather than the branch the hook still
# carries; see the note filed with this suite.
make_env_file "sess-b13"
cat > "$CLAUDE_WORKFLOW_DIR/sess-b13.json" <<'EOF'
{
  "version": 1,
  "session_id": "sess-b13",
  "steps": {}
}
EOF
assert_block "B13" "empty steps map → block (projection materialises write_tests as pending)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-b13","agent_id":""}'

# B14: stdin malformed JSON → approve (fail-open)
make_env_file "sess-b14"
make_state "sess-b14" "pending"
b14_input_file="$(mktemp "$TMPDIR_ROOT/b14_input.XXXXXX")"
printf '%s' 'NOT VALID JSON' > "$b14_input_file"
b14_result=$(
    (
        unset CLAUDE_BLOCK_TESTS_DIR_NAMES
        export CLAUDE_ENV_FILE="$ENV_FILE_N"
        export CLAUDE_WORKFLOW_DIR="$WF_DIR_N"
        run_with_timeout node "$HOOK" < "$b14_input_file" 2>/dev/null
    )
)
b14_rc=$?
rm -f "$b14_input_file"
b14_decision=$(decision_of "$b14_result")
b14_problems=""
[ "$b14_decision" = "approve" ] || b14_problems="$b14_problems [decision='${b14_decision:-<none>}', expected approve]"
[ "$b14_rc" -eq 0 ] || b14_problems="$b14_problems [hook exited ${b14_rc}, expected 0]"
if [ -z "$b14_problems" ]; then
    pass "B14. stdin malformed JSON → approve (fail-open), hook exits 0"
else
    fail "B14. stdin malformed JSON —${b14_problems} raw: ${b14_result}"
fi

# ===========================================================================
# Section C — Edge cases
# ===========================================================================
echo ""
echo "=== Section C — Edge cases ==="

# C15: foo/tests/bar/baz.sh (mid-path tests/) → block
setup_session "sess-c15" "pending"
assert_block "C15" "foo/tests/bar/baz.sh + pending → block (tests/ mid-path)" \
    '{"tool_name":"Write","tool_input":{"file_path":"foo/tests/bar/baz.sh"},"session_id":"sess-c15","agent_id":""}'

# C16: integration-tests/foo.sh → approve (not isolated component)
setup_session "sess-c16" "pending"
assert_approve "C16" "integration-tests/foo.sh + pending → approve (not isolated tests/ component)" \
    '{"tool_name":"Write","tool_input":{"file_path":"integration-tests/foo.sh"},"session_id":"sess-c16","agent_id":""}'

# C17: Windows backslash path C:\git\dotfiles\tests\foo.sh → block
setup_session "sess-c17" "pending"
assert_block "C17" "Windows backslash path tests\\foo.sh + pending → block" \
    '{"tool_name":"Write","tool_input":{"file_path":"C:\\git\\dotfiles\\tests\\foo.sh"},"session_id":"sess-c17","agent_id":""}'

# C18: Unix absolute /home/user/tests/foo.sh → block
setup_session "sess-c18" "pending"
assert_block "C18" "/home/user/tests/foo.sh + pending → block (Unix absolute)" \
    '{"tool_name":"Write","tool_input":{"file_path":"/home/user/tests/foo.sh"},"session_id":"sess-c18","agent_id":""}'

# C19: Git Bash style /c/git/dotfiles/tests/foo.sh → block
setup_session "sess-c19" "pending"
assert_block "C19" "/c/git/dotfiles/tests/foo.sh + pending → block (Git Bash style)" \
    '{"tool_name":"Write","tool_input":{"file_path":"/c/git/dotfiles/tests/foo.sh"},"session_id":"sess-c19","agent_id":""}'

# C20: file_path="" (empty string) → approve
setup_session "sess-c20" "pending"
assert_approve "C20" "file_path=empty string → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":""},"session_id":"sess-c20","agent_id":""}'

# C21: file_path="tests/" (directory only, no filename) → approve
setup_session "sess-c21" "pending"
assert_approve "C21" "file_path=tests/ (directory only) → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/"},"session_id":"sess-c21","agent_id":""}'

# C22: spec/foo.js + CLAUDE_BLOCK_TESTS_DIR_NAMES=spec,__tests__ → block
setup_session "sess-c22" "pending"
assert_block "C22" "spec/foo.js + CLAUDE_BLOCK_TESTS_DIR_NAMES=spec,__tests__ → block" \
    '{"tool_name":"Write","tool_input":{"file_path":"spec/foo.js"},"session_id":"sess-c22","agent_id":""}' \
    "CLAUDE_BLOCK_TESTS_DIR_NAMES=spec,__tests__"

# C23: tests/foo.sh + CLAUDE_BLOCK_TESTS_DIR_NAMES=spec,__tests__ → approve (tests not in custom list)
setup_session "sess-c23" "pending"
assert_approve "C23" "tests/foo.sh + CLAUDE_BLOCK_TESTS_DIR_NAMES=spec,__tests__ → approve (not in custom list)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-c23","agent_id":""}' \
    "CLAUDE_BLOCK_TESTS_DIR_NAMES=spec,__tests__"

# C24: the default value, pinned literally. Every unpinned case above runs with
# CLAUDE_BLOCK_TESTS_DIR_NAMES unset and so asserts whatever the hook's built-in
# default happens to be. This case states that default out loud — `tests` — and
# proves the explicit spelling and the implicit one agree, so a change to the
# built-in default becomes a visible failure here instead of a silent
# reinterpretation of the whole suite.
setup_session "sess-c24" "pending"
assert_block "C24" "tests/foo.sh + CLAUDE_BLOCK_TESTS_DIR_NAMES=tests (default pinned explicitly) → block" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-c24","agent_id":""}' \
    "CLAUDE_BLOCK_TESTS_DIR_NAMES=tests"

# C24b: the counter-anchor for C24 — with the default pinned, a directory that is
# NOT in it still approves, so C24's block is attributable to `tests` being in
# the list rather than to the hook blocking everything once the var is set.
setup_session "sess-c24b" "pending"
assert_approve "C24b" "spec/foo.js + CLAUDE_BLOCK_TESTS_DIR_NAMES=tests → approve (spec not in the default)" \
    '{"tool_name":"Write","tool_input":{"file_path":"spec/foo.js"},"session_id":"sess-c24b","agent_id":""}' \
    "CLAUDE_BLOCK_TESTS_DIR_NAMES=tests"

# ===========================================================================
# Section D — Idempotency
# ===========================================================================
echo ""
echo "=== Section D — Idempotency ==="

# D24: same stdin twice → same decision both times
setup_session "sess-d24" "pending"
d24_json='{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-d24","agent_id":""}'
run_hook "$d24_json"; d24_result1="$HOOK_OUT"; d24_rc1=$HOOK_RC
run_hook "$d24_json"; d24_result2="$HOOK_OUT"; d24_rc2=$HOOK_RC
d24_dec1=$(decision_of "$d24_result1")
d24_dec2=$(decision_of "$d24_result2")
d24_problems=""
[ "$d24_dec1" = "$d24_dec2" ] && [ -n "$d24_dec1" ] ||
    d24_problems="$d24_problems [decisions '${d24_dec1:-<none>}' then '${d24_dec2:-<none>}']"
{ [ "$d24_rc1" -eq 0 ] && [ "$d24_rc2" -eq 0 ]; } ||
    d24_problems="$d24_problems [exit codes ${d24_rc1} then ${d24_rc2}, both must be 0]"
if [ -z "$d24_problems" ]; then
    pass "D24. same stdin twice → same decision (${d24_dec1}) and exit 0 both times"
else
    fail "D24. idempotency —${d24_problems}"
fi

# ===========================================================================
# Section E — Security
# ===========================================================================
echo ""
echo "=== Section E — Security ==="

# E25: ../../etc/tests/exploit.sh + pending → block (path traversal still matches tests/)
setup_session "sess-e25" "pending"
assert_block "E25" "../../etc/tests/exploit.sh + pending → block (path traversal with tests/)" \
    '{"tool_name":"Write","tool_input":{"file_path":"../../etc/tests/exploit.sh"},"session_id":"sess-e25","agent_id":""}'

# E26: tests/$(rm -rf /).sh + pending → block and no shell execution (pure string match)
setup_session "sess-e26" "pending"
assert_block "E26" 'tests/$(rm -rf /).sh + pending → block (no shell execution)' \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/$(rm -rf /).sh"},"session_id":"sess-e26","agent_id":""}'

# E27: DENY_MESSAGE drift check — hook must export DENY_MESSAGE matching expected string
EXPECTED_DENY_MESSAGE="write_tests step is still pending. Run /write-tests first — it spawns a subagent that writes tests/ autonomously. If tests are genuinely not needed, mark the step skipped with: echo \"<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {reason}>>\""
HOOK_ABS="$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")"
e27_result=$(node -e "
var hookPath = process.argv[1];
try {
  var m = require(hookPath);
  if (typeof m.DENY_MESSAGE === 'string') {
    process.stdout.write(m.DENY_MESSAGE);
  } else {
    process.stdout.write('ERROR: DENY_MESSAGE not exported or not a string');
  }
} catch(e) {
  process.stdout.write('ERROR: ' + e.message);
}
" -- "$HOOK_ABS" 2>/dev/null)

if [ "$e27_result" = "$EXPECTED_DENY_MESSAGE" ]; then
    pass "E27. DENY_MESSAGE exported and matches expected string"
else
    fail "E27. DENY_MESSAGE drift — expected: '${EXPECTED_DENY_MESSAGE}' — got: '${e27_result}'"
fi

# ===========================================================================
# Section F — Integration (broad)
# ===========================================================================
echo ""
echo "=== Section F — Integration (broad) ==="

# F28: real state file (write_tests=pending) + main-style stdin (no agent_id) → block
setup_session "sess-f28" "pending"
assert_block "F28" "real state + write_tests=pending + no agent_id → block (integration)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/integration.sh"},"session_id":"sess-f28","agent_id":""}'

# F29: real state file (write_tests=pending) + agent_id="sub-abc" → approve
setup_session "sess-f29" "pending"
assert_approve "F29" "real state + write_tests=pending + agent_id=sub-abc → approve (subagent, integration)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/integration.sh"},"session_id":"sess-f29","agent_id":"sub-abc"}'

# ===========================================================================
# Section G — Mutation test (HOOK_RC capture)
# ===========================================================================
echo ""
echo "=== Section G — Mutation test (HOOK_RC capture) ==="

# G30: a deliberately-bad "hook" that prints an approve verdict on stdout but
# exits 1. Under the old `result=$(run_hook ...)` bug, HOOK_RC would be set
# inside a subshell and this case would still read 0. Pinning HOOK_RC==1 here
# proves run_hook's fix (HOOK_RC assigned in the caller's own scope) actually
# detects a crash-after-printing hook.
BAD_HOOK="$TMPDIR_ROOT/bad_hook.js"
cat > "$BAD_HOOK" <<'EOF'
process.stdout.write(JSON.stringify({decision: "approve"}));
process.exit(1);
EOF
ORIG_HOOK="$HOOK"
HOOK="$BAD_HOOK"
run_hook '{"tool_name":"Write","tool_input":{"file_path":"src/foo.js"},"session_id":"sess-g30","agent_id":""}'
g30_decision=$(decision_of "$HOOK_OUT")
g30_rc="$HOOK_RC"
HOOK="$ORIG_HOOK"
if [ "$g30_decision" = "approve" ] && [ "$g30_rc" -eq 1 ]; then
    pass "G30. bad hook (approve stdout, exit 1) → HOOK_RC correctly captured as 1"
else
    fail "G30. bad hook mutation test — decision='${g30_decision}' HOOK_RC=${g30_rc} (expected approve/1)"
fi

# ===========================================================================
# Results
# ===========================================================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS_COUNT + ERRORS))
echo "${PASS_COUNT}/${TOTAL} tests passed, ${ERRORS} failed"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "${ERRORS} test(s) failed"
    exit 1
fi
