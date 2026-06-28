#!/bin/bash
# C1-C6: Unit tests for is-bugfix-session.js and state-io.js additions (T0-A SSOT module).
# Expected to FAIL until write-code implements the new module and getSkippableSteps.
# Usage: bash test-ssot-module.sh <AGENTS_DIR>
set -uo pipefail

AGENTS_DIR="${1:?AGENTS_DIR required as \$1}"
SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"

ERRORS=0
PASS_COUNT=0
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }

WIN_AGENTS_DIR="$(node -e "const p=require('path');process.stdout.write(p.resolve(process.argv[1]));" -- "$AGENTS_DIR")"

TMPDIR_ROOT="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs'),crypto=require('crypto');
const d=path.join(os.tmpdir(),'1147-ssot-'+crypto.randomBytes(6).toString('hex'));
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
# C1: isBugfixBranch() branch name classification
# ---------------------------------------------------------------------------
echo "=== C1: isBugfixBranch() — branch name pattern ==="
C1_OUT="$(AGENTS_REQ="$WIN_AGENTS_DIR" run_with_timeout node -e "
try {
    const {isBugfixBranch} = require(process.env.AGENTS_REQ + '/hooks/lib/workflow-state/is-bugfix-session');
    console.log('fix/foo:', isBugfixBranch('fix/foo'));
    console.log('main:', isBugfixBranch('main'));
    console.log('feature/x:', isBugfixBranch('feature/x'));
    console.log('fix/:', isBugfixBranch('fix/'));
    console.log('FIX/bar:', isBugfixBranch('FIX/bar'));
} catch(e) {
    console.log('MODULE_NOT_FOUND: ' + e.message);
}
" 2>&1 || true)"

if echo "$C1_OUT" | grep -q "MODULE_NOT_FOUND\|Cannot find module"; then
    fail "C1: is-bugfix-session.js not found (expected — T0-A not yet implemented)"
else
    if echo "$C1_OUT" | grep -q "fix/foo: true" && \
       echo "$C1_OUT" | grep -q "main: false" && \
       echo "$C1_OUT" | grep -q "feature/x: false" && \
       echo "$C1_OUT" | grep -q "fix/: false"; then
        pass "C1: isBugfixBranch() classifies branches correctly"
    else
        fail "C1: isBugfixBranch() produced unexpected results: $C1_OUT"
    fi
fi

# ---------------------------------------------------------------------------
# C2: createInitialState gets is_bugfix flag from git_branch
# ---------------------------------------------------------------------------
echo "=== C2: createInitialState — is_bugfix flag from git_branch ==="
C2_OUT="$(AGENTS_REQ="$WIN_AGENTS_DIR" run_with_timeout node -e "
try {
    const {createInitialState} = require(process.env.AGENTS_REQ + '/hooks/lib/workflow-state/state-io');
    const s1 = createInitialState('test-c2-fix', {git_branch: 'fix/x', cwd: '/tmp'});
    const s2 = createInitialState('test-c2-main', {git_branch: 'main', cwd: '/tmp'});
    const s3 = createInitialState('test-c2-null', {git_branch: null, cwd: '/tmp'});
    console.log('fix/x is_bugfix:', s1.is_bugfix);
    console.log('main is_bugfix:', s2.is_bugfix);
    console.log('null is_bugfix:', s3.is_bugfix);
} catch(e) {
    console.log('ERROR: ' + e.message);
}
" 2>&1 || true)"

if echo "$C2_OUT" | grep -q "Cannot find module"; then
    fail "C2: createInitialState module not found (expected — T0-A not yet implemented)"
elif echo "$C2_OUT" | grep -q "ERROR"; then
    fail "C2: createInitialState is_bugfix flag — runtime error (expected — T0-A not yet implemented)"
elif echo "$C2_OUT" | grep -q "is_bugfix: undefined"; then
    fail "C2: createInitialState does not set is_bugfix yet (expected — T0-A not yet implemented)"
else
    if echo "$C2_OUT" | grep -q "fix/x is_bugfix: true" && \
       echo "$C2_OUT" | grep -q "main is_bugfix: false" && \
       echo "$C2_OUT" | grep -q "null is_bugfix: false"; then
        pass "C2: createInitialState sets is_bugfix correctly from git_branch"
    else
        fail "C2: createInitialState is_bugfix flag unexpected: $C2_OUT"
    fi
fi

# ---------------------------------------------------------------------------
# C3: isBugfixSession — init-time flag wins over branch drift
# ---------------------------------------------------------------------------
echo "=== C3: isBugfixSession — init-time is_bugfix flag priority ==="
SID_C3="test-c3-$$"
cat > "$CLAUDE_WORKFLOW_DIR/${SID_C3}.json" <<EOF
{
  "version": 1, "session_id": "${SID_C3}", "created_at": "${NOW_ISO}",
  "is_bugfix": true, "git_branch": "main",
  "steps": {
    "workflow_init": {"status":"complete","updated_at":null},
    "clarify_intent": {"status":"complete","updated_at":null},
    "write_tests": {"status":"pending","updated_at":null},
    "review_tests": {"status":"pending","updated_at":null},
    "user_verification": {"status":"pending","updated_at":null}
  },
  "workflow_type": "wf-code"
}
EOF

C3_OUT="$(AGENTS_REQ="$WIN_AGENTS_DIR" run_with_timeout node -e "
try {
    const {isBugfixSession} = require(process.env.AGENTS_REQ + '/hooks/lib/workflow-state/is-bugfix-session');
    console.log('result:', isBugfixSession('${SID_C3}'));
} catch(e) {
    console.log('MODULE_NOT_FOUND: ' + e.message);
}
" 2>&1 || true)"

if echo "$C3_OUT" | grep -q "MODULE_NOT_FOUND\|Cannot find module"; then
    fail "C3: isBugfixSession — module not found (expected — T0-A not yet implemented)"
else
    if echo "$C3_OUT" | grep -q "result: true"; then
        pass "C3: isBugfixSession returns true when is_bugfix=true in state (init-time flag priority)"
    else
        fail "C3: isBugfixSession flag priority unexpected: $C3_OUT"
    fi
fi

# ---------------------------------------------------------------------------
# C4: isBugfixSession — old state fallback (no is_bugfix field, uses git_branch)
# ---------------------------------------------------------------------------
echo "=== C4: isBugfixSession — old state fallback via git_branch ==="
SID_C4A="test-c4a-$$"
SID_C4B="test-c4b-$$"
cat > "$CLAUDE_WORKFLOW_DIR/${SID_C4A}.json" <<EOF
{"version":1,"session_id":"${SID_C4A}","created_at":"${NOW_ISO}","git_branch":"fix/x","steps":{"workflow_init":{"status":"complete","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"review_tests":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null}},"workflow_type":"wf-code"}
EOF
cat > "$CLAUDE_WORKFLOW_DIR/${SID_C4B}.json" <<EOF
{"version":1,"session_id":"${SID_C4B}","created_at":"${NOW_ISO}","git_branch":"main","steps":{"workflow_init":{"status":"complete","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"review_tests":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null}},"workflow_type":"wf-code"}
EOF

C4_OUT="$(AGENTS_REQ="$WIN_AGENTS_DIR" run_with_timeout node -e "
try {
    const {isBugfixSession} = require(process.env.AGENTS_REQ + '/hooks/lib/workflow-state/is-bugfix-session');
    console.log('fix/x fallback:', isBugfixSession('${SID_C4A}'));
    console.log('main fallback:', isBugfixSession('${SID_C4B}'));
} catch(e) {
    console.log('MODULE_NOT_FOUND: ' + e.message);
}
" 2>&1 || true)"

if echo "$C4_OUT" | grep -q "MODULE_NOT_FOUND\|Cannot find module"; then
    fail "C4: isBugfixSession old-state fallback — module not found (expected — T0-A not yet implemented)"
else
    if echo "$C4_OUT" | grep -q "fix/x fallback: true" && \
       echo "$C4_OUT" | grep -q "main fallback: false"; then
        pass "C4: isBugfixSession falls back to git_branch when is_bugfix field absent"
    else
        fail "C4: isBugfixSession old-state fallback unexpected: $C4_OUT"
    fi
fi

# ---------------------------------------------------------------------------
# C5: getSkippableSteps — BUGFIX state excludes write_tests and review_tests
# ---------------------------------------------------------------------------
echo "=== C5: getSkippableSteps — BUGFIX excludes write_tests and review_tests ==="
SID_C5="test-c5-$$"
write_state "$SID_C5" "true" "fix/x"

C5_OUT="$(AGENTS_REQ="$WIN_AGENTS_DIR" run_with_timeout node -e "
try {
    const {getSkippableSteps} = require(process.env.AGENTS_REQ + '/hooks/lib/workflow-state/state-io');
    const steps = getSkippableSteps('${SID_C5}');
    console.log('write_tests in skippable:', steps.includes('write_tests'));
    console.log('review_tests in skippable:', steps.includes('review_tests'));
    console.log('research in skippable:', steps.includes('research'));
} catch(e) {
    console.log('MODULE_NOT_FOUND: ' + e.message);
}
" 2>&1 || true)"

if echo "$C5_OUT" | grep -q "MODULE_NOT_FOUND\|Cannot find module\|is not a function"; then
    fail "C5: getSkippableSteps — module or function not found (expected — T0-A not yet implemented)"
else
    if echo "$C5_OUT" | grep -q "write_tests in skippable: false" && \
       echo "$C5_OUT" | grep -q "review_tests in skippable: false" && \
       echo "$C5_OUT" | grep -q "research in skippable: true"; then
        pass "C5: getSkippableSteps excludes write_tests and review_tests for BUGFIX"
    else
        fail "C5: getSkippableSteps BUGFIX exclusion unexpected: $C5_OUT"
    fi
fi

# ---------------------------------------------------------------------------
# C6: getSkippableSteps — non-BUGFIX state includes write_tests and review_tests
# ---------------------------------------------------------------------------
echo "=== C6: getSkippableSteps — non-BUGFIX includes write_tests and review_tests ==="
SID_C6="test-c6-$$"
write_state "$SID_C6" "false" "feature/foo"

C6_OUT="$(AGENTS_REQ="$WIN_AGENTS_DIR" run_with_timeout node -e "
try {
    const {getSkippableSteps} = require(process.env.AGENTS_REQ + '/hooks/lib/workflow-state/state-io');
    const steps = getSkippableSteps('${SID_C6}');
    console.log('write_tests in skippable:', steps.includes('write_tests'));
    console.log('review_tests in skippable:', steps.includes('review_tests'));
} catch(e) {
    console.log('MODULE_NOT_FOUND: ' + e.message);
}
" 2>&1 || true)"

if echo "$C6_OUT" | grep -q "MODULE_NOT_FOUND\|Cannot find module\|is not a function"; then
    fail "C6: getSkippableSteps non-BUGFIX — module or function not found (expected — T0-A not yet implemented)"
else
    if echo "$C6_OUT" | grep -q "write_tests in skippable: true" && \
       echo "$C6_OUT" | grep -q "review_tests in skippable: true"; then
        pass "C6: getSkippableSteps includes write_tests and review_tests for non-BUGFIX"
    else
        fail "C6: getSkippableSteps non-BUGFIX inclusion unexpected: $C6_OUT"
    fi
fi

# ---------------------------------------------------------------------------
echo ""
TOTAL=$((PASS_COUNT + ERRORS))
echo "${PASS_COUNT}/${TOTAL} passed, ${ERRORS} failed (C1-C6)"
exit "$ERRORS"
