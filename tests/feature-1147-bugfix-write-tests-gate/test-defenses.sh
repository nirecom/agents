#!/bin/bash
# C7-C11: Integration tests for workflow-mark and workflow-gate BUGFIX defenses (T0-A).
# C7,C9,C10a expected to FAIL until write-code implements the guards.
# C8,C10b,C11 verify existing behavior is preserved.
# Usage: bash test-defenses.sh <AGENTS_DIR>
set -uo pipefail

AGENTS_DIR="${1:?AGENTS_DIR required as \$1}"
SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"

ERRORS=0
PASS_COUNT=0
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }

WIN_AGENTS_DIR="$(node -e "const p=require('path');process.stdout.write(p.resolve(process.argv[1]));" -- "$AGENTS_DIR")"

HOOK_MARK="$AGENTS_DIR/hooks/workflow-mark.js"
HOOK_GATE="$AGENTS_DIR/hooks/workflow-gate.js"

TMPDIR_ROOT="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs'),crypto=require('crypto');
const d=path.join(os.tmpdir(),'1147-def-'+crypto.randomBytes(6).toString('hex'));
fs.mkdirSync(d,{recursive:true});
process.stdout.write(d);
")"
export CLAUDE_WORKFLOW_DIR="$TMPDIR_ROOT/workflow"
export CLAUDE_ENV_FILE="$TMPDIR_ROOT/claude_env"
mkdir -p "$CLAUDE_WORKFLOW_DIR"
cleanup() { rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

NOW_ISO=$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
# shellcheck source=helpers.sh
. "$SUITE_DIR/helpers.sh"

# ---------------------------------------------------------------------------
# C7: First defense (BUGFIX reject): WRITE_TESTS_NOT_NEEDED blocked for BUGFIX
# ---------------------------------------------------------------------------
echo "=== C7: workflow-mark — WRITE_TESTS_NOT_NEEDED rejected for BUGFIX session ==="
SID_C7="test-c7-$$"
write_state "$SID_C7" "true" "fix/my-bug"
write_env_file "$SID_C7"

SENTINEL_C7='<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: no tests needed>>'
C7_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"echo \"'"$SENTINEL_C7"'\""},"tool_response":{"output":"'"$SENTINEL_C7"'","exit_code":0},"session_id":"'"$SID_C7"'"}'

C7_OUT="$(run_hook "$C7_PAYLOAD")"
C7_STATUS="$(read_step_status "$SID_C7" "write_tests")"

if echo "$C7_OUT" | grep -qi "bugfix\|not allowed\|blocked\|cannot skip\|rejected\|forbidden"; then
    if [ "$C7_STATUS" = "pending" ]; then
        pass "C7: WRITE_TESTS_NOT_NEEDED rejected for BUGFIX; write_tests remains pending"
    else
        fail "C7: rejection message found but write_tests not pending (status: $C7_STATUS)"
    fi
else
    fail "C7: expected BUGFIX rejection in workflow-mark output; got: $C7_OUT | write_tests=$C7_STATUS (T0-A not yet implemented)"
fi

# ---------------------------------------------------------------------------
# C8: First defense (non-BUGFIX pass): WRITE_TESTS_NOT_NEEDED accepted
# ---------------------------------------------------------------------------
echo "=== C8: workflow-mark — WRITE_TESTS_NOT_NEEDED accepted for non-BUGFIX session ==="
SID_C8="test-c8-$$"
write_state "$SID_C8" "false" "feature/bar"
write_env_file "$SID_C8"

SENTINEL_C8='<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: no tests needed for docs-only>>'
C8_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"echo \"'"$SENTINEL_C8"'\""},"tool_response":{"output":"'"$SENTINEL_C8"'","exit_code":0},"session_id":"'"$SID_C8"'"}'

run_hook "$C8_PAYLOAD" > /dev/null 2>&1 || true

C8_STATUS="$(read_step_status "$SID_C8" "write_tests")"
if [ "$C8_STATUS" = "skipped" ]; then
    pass "C8: WRITE_TESTS_NOT_NEEDED accepted for non-BUGFIX; write_tests recorded as skipped"
else
    fail "C8: WRITE_TESTS_NOT_NEEDED for non-BUGFIX — write_tests not skipped (status: $C8_STATUS)"
fi

# ---------------------------------------------------------------------------
# C9: Second defense — workflow-gate blocks BUGFIX with write_tests=skipped
# ---------------------------------------------------------------------------
echo "=== C9: workflow-gate — blocks BUGFIX commit when write_tests=skipped ==="

REPO_C9="$TMPDIR_ROOT/repo-c9"
mkdir -p "$REPO_C9"
git init -q "$REPO_C9"
git -C "$REPO_C9" checkout -q -b "fix/my-bug" 2>/dev/null || git -C "$REPO_C9" symbolic-ref HEAD "refs/heads/fix/my-bug"

SID_C9="test-c9-$$"
write_state_with_steps "$SID_C9" "true" "fix/my-bug" "skipped" "skipped"
write_env_file "$SID_C9"

C9_PAYLOAD="$(REPO_DIR="$REPO_C9" node -e "
const d=process.env.REPO_DIR;
process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    tool_input: {command: 'git commit -m test', cwd: d},
    session_id: process.argv[1]
}));
" -- "$SID_C9")"

C9_OUT="$(AGENTS_CONFIG_DIR="$REPO_C9" CLAUDE_PROJECT_DIR="$REPO_C9" run_gate "$C9_PAYLOAD")"

if echo "$C9_OUT" | grep -q '"decision":"block"'; then
    if echo "$C9_OUT" | grep -qi "write_tests"; then
        pass "C9: workflow-gate blocks BUGFIX commit when write_tests=skipped"
    else
        fail "C9: workflow-gate blocked but not for write_tests: $C9_OUT"
    fi
else
    fail "C9: workflow-gate should block BUGFIX commit with write_tests=skipped, got: $C9_OUT (T0-A not yet implemented)"
fi

# ---------------------------------------------------------------------------
# C10: Second defense — review_tests blocked for BUGFIX; non-BUGFIX skip accepted
# ---------------------------------------------------------------------------
echo "=== C10: workflow-gate — review_tests blocked for BUGFIX; skipped OK for non-BUGFIX ==="

# C10a: BUGFIX with write_tests=complete but review_tests=skipped → block
REPO_C10="$TMPDIR_ROOT/repo-c10"
mkdir -p "$REPO_C10"
git init -q "$REPO_C10"
git -C "$REPO_C10" checkout -q -b "fix/my-bug-2" 2>/dev/null || git -C "$REPO_C10" symbolic-ref HEAD "refs/heads/fix/my-bug-2"

SID_C10A="test-c10a-$$"
write_state_with_steps "$SID_C10A" "true" "fix/my-bug-2" "complete" "skipped"
write_env_file "$SID_C10A"

C10A_PAYLOAD="$(REPO_DIR="$REPO_C10" node -e "
const d=process.env.REPO_DIR;
process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    tool_input: {command: 'git commit -m test', cwd: d},
    session_id: process.argv[1]
}));
" -- "$SID_C10A")"

C10A_OUT="$(AGENTS_CONFIG_DIR="$REPO_C10" CLAUDE_PROJECT_DIR="$REPO_C10" run_gate "$C10A_PAYLOAD")"

if echo "$C10A_OUT" | grep -q '"decision":"block"' && echo "$C10A_OUT" | grep -qi "review_tests"; then
    pass "C10a: workflow-gate blocks BUGFIX commit when review_tests=skipped"
else
    fail "C10a: expected block for review_tests on BUGFIX, got: $C10A_OUT (T0-A not yet implemented)"
fi

# C10b: non-BUGFIX with write_tests=complete and review_tests=skipped → approve
REPO_C10B="$TMPDIR_ROOT/repo-c10b"
mkdir -p "$REPO_C10B"
git init -q "$REPO_C10B"
git -C "$REPO_C10B" checkout -q -b "feature/new-thing" 2>/dev/null || git -C "$REPO_C10B" symbolic-ref HEAD "refs/heads/feature/new-thing"

SID_C10B="test-c10b-$$"
write_state_with_steps "$SID_C10B" "false" "feature/new-thing" "complete" "skipped" "complete"
write_env_file "$SID_C10B"

C10B_PAYLOAD="$(REPO_DIR="$REPO_C10B" node -e "
const d=process.env.REPO_DIR;
process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    tool_input: {command: 'git commit -m test', cwd: d},
    session_id: process.argv[1]
}));
" -- "$SID_C10B")"

C10B_OUT="$(AGENTS_CONFIG_DIR="$REPO_C10B" CLAUDE_PROJECT_DIR="$REPO_C10B" run_gate "$C10B_PAYLOAD")"

if echo "$C10B_OUT" | grep -q '"decision":"approve"'; then
    pass "C10b: workflow-gate approves non-BUGFIX commit when review_tests=skipped"
else
    fail "C10b: expected approve for review_tests=skipped on non-BUGFIX, got: $C10B_OUT"
fi

# ---------------------------------------------------------------------------
# C11: Evidence bypass preserved — staged tests/ overrides write_tests=skipped for BUGFIX
# ---------------------------------------------------------------------------
echo "=== C11: workflow-gate — staged tests/ evidence bypasses write_tests=skipped even for BUGFIX ==="

REPO_C11="$TMPDIR_ROOT/repo-c11"
mkdir -p "$REPO_C11"
git init -q "$REPO_C11"
git -C "$REPO_C11" checkout -q -b "fix/evidence-bypass" 2>/dev/null || git -C "$REPO_C11" symbolic-ref HEAD "refs/heads/fix/evidence-bypass"

mkdir -p "$REPO_C11/tests"
printf '#!/bin/bash\n# placeholder test\n' > "$REPO_C11/tests/dummy-test.sh"
git -C "$REPO_C11" add "tests/dummy-test.sh"

SID_C11="test-c11-$$"
write_state_with_steps "$SID_C11" "true" "fix/evidence-bypass" "skipped" "skipped"
write_env_file "$SID_C11"

C11_PAYLOAD="$(REPO_DIR="$REPO_C11" node -e "
const d=process.env.REPO_DIR;
process.stdout.write(JSON.stringify({
    tool_name: 'Bash',
    tool_input: {command: 'git commit -m test', cwd: d},
    session_id: process.argv[1]
}));
" -- "$SID_C11")"

C11_OUT="$(AGENTS_CONFIG_DIR="$REPO_C11" CLAUDE_PROJECT_DIR="$REPO_C11" run_gate "$C11_PAYLOAD")"

# write_tests must NOT appear in the block reason (evidence bypasses it)
if echo "$C11_OUT" | grep -q '"decision":"block"' && echo "$C11_OUT" | grep -qi "write_tests"; then
    fail "C11: write_tests evidence bypass not respected for BUGFIX — still blocked for write_tests: $C11_OUT"
elif echo "$C11_OUT" | grep -q '"decision":"approve"' || \
     (echo "$C11_OUT" | grep -q '"decision":"block"' && ! echo "$C11_OUT" | grep -qi "write_tests"); then
    pass "C11: staged tests/ evidence bypasses write_tests=skipped even for BUGFIX"
else
    fail "C11: unexpected gate output: $C11_OUT (T0-A not yet implemented)"
fi

# ---------------------------------------------------------------------------
echo ""
TOTAL=$((PASS_COUNT + ERRORS))
echo "${PASS_COUNT}/${TOTAL} passed, ${ERRORS} failed (C7-C11)"
exit "$ERRORS"
