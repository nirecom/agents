#!/bin/bash
# tests/feature-833-review-tests-gate/section-g.sh
# Tests: hooks/workflow-gate/review-tests-checker.js, hooks/lib/workflow-state/state-io.js
# Tags: workflow, gate, hook, review-tests, checker, state-io, scope:issue-specific
#
# Section G: checkReviewTests unit tests and markReviewTestsComplete error handling.
# Sourced by tests/feature-833-review-tests-gate.sh. Inherits parent helpers
# (PASS, FAIL, TMPDIR_BASE, WORKFLOW_DIR, run_with_timeout, NOW_ISO).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CHECKER_NODE="$_AGENTS_DIR_NODE/hooks/workflow-gate/review-tests-checker.js"
STATE_IO_NODE="$_AGENTS_DIR_NODE/hooks/lib/workflow-state/state-io.js"

# ============================================================================
# Section G: checkReviewTests unit tests + markReviewTestsComplete error guard
# ============================================================================
echo ""
echo "=== Section G: checkReviewTests unit + markReviewTestsComplete error guard ==="

run_g1() {
    # G1: docsOnly=true -> checkReviewTests returns skip
    local out
    out=$(run_with_timeout 10 node -e "
const {checkReviewTests} = require('$CHECKER_NODE');
const r = checkReviewTests('review_tests', null, {docsOnly:true, writeTestsEvidenceBypassed:false, repoDir:'.'});
process.stdout.write(r.action === 'skip' ? 'PASS' : 'FAIL:'+r.action);
" 2>/dev/null)
    if [ "$out" = "PASS" ]; then
        pass "G1. docsOnly=true -> checkReviewTests returns skip"
    else
        fail "G1. docsOnly=true -> expected skip, got: $out"
    fi
}

run_g2() {
    # G2: review_tests=skipped in state -> checkReviewTests returns skip
    local out
    out=$(run_with_timeout 10 node -e "
const {checkReviewTests} = require('$CHECKER_NODE');
const r = checkReviewTests('review_tests', {status:'skipped'}, {docsOnly:false, writeTestsEvidenceBypassed:false, repoDir:'.'});
process.stdout.write(r.action === 'skip' ? 'PASS' : 'FAIL:'+r.action);
" 2>/dev/null)
    if [ "$out" = "PASS" ]; then
        pass "G2. review_tests=skipped in state -> checkReviewTests returns skip"
    else
        fail "G2. review_tests=skipped -> expected skip, got: $out"
    fi
}

run_g3() {
    # G3: markReviewTestsComplete with empty token -> throws, state unchanged
    local plans_tmp sid initial_status result_status threw
    plans_tmp="$(mktemp -d)"
    sid="g3-$$"
    # Create initial state via state writer
    run_with_timeout 10 node -e "
const m = require('$STATE_IO_NODE');
const state = m.createInitialState(process.argv[1], {cwd: process.argv[2]});
m.writeState(process.argv[1], state);
" -- "$sid" "$plans_tmp" 2>/dev/null
    initial_status=$(run_with_timeout 5 node -e "
const m = require('$STATE_IO_NODE');
const s = m.readState(process.argv[1]);
const st = s && s.steps && s.steps.review_tests;
process.stdout.write(st ? st.status : 'MISSING');
" -- "$sid" 2>/dev/null)
    # Call markReviewTestsComplete with empty token -> should throw
    threw=$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" run_with_timeout 10 node -e "
const m = require('$STATE_IO_NODE');
try {
    m.markReviewTestsComplete(process.argv[1], '', {});
    process.stdout.write('NO_THROW');
} catch(e) {
    process.stdout.write(e.message.includes('non-empty') ? 'THREW_OK' : 'THREW_OTHER:'+e.message);
}
" -- "$sid" 2>/dev/null)
    # Verify state is still initial (review_tests not updated to complete)
    result_status=$(run_with_timeout 5 node -e "
const m = require('$STATE_IO_NODE');
const s = m.readState(process.argv[1]);
const st = s && s.steps && s.steps.review_tests;
process.stdout.write(st ? st.status : 'MISSING');
" -- "$sid" 2>/dev/null)
    rm -rf "$plans_tmp"
    if [ "$threw" = "THREW_OK" ] && [ "$result_status" = "pending" ]; then
        pass "G3. markReviewTestsComplete with empty token throws + state unchanged (review_tests=pending)"
    else
        fail "G3. expected THREW_OK+pending, got threw=$threw initial=$initial_status result=$result_status"
    fi
}

run_g4() {
    # G4: writeTestsEvidenceBypassed=true + status!=complete -> skip
    local out
    out=$(run_with_timeout 10 node -e "
const {checkReviewTests} = require('$CHECKER_NODE');
const r = checkReviewTests('review_tests', {status:'pending'}, {docsOnly:false, writeTestsEvidenceBypassed:true, repoDir:'.'});
process.stdout.write(r.action === 'skip' ? 'PASS' : 'FAIL:'+r.action);
" 2>/dev/null)
    if [ "$out" = "PASS" ]; then
        pass "G4. writeTestsEvidenceBypassed=true + pending -> checkReviewTests returns skip"
    else
        fail "G4. writeTestsEvidenceBypassed -> expected skip, got: $out"
    fi
}

run_g5() {
    # G5: status=complete + warnings_summary set -> block/warnings-pending
    local out
    out=$(run_with_timeout 10 node -e "
const {checkReviewTests} = require('$CHECKER_NODE');
const r = checkReviewTests('review_tests', {status:'complete', warnings_summary:'some gaps'}, {docsOnly:false, writeTestsEvidenceBypassed:false, repoDir:'.'});
process.stdout.write(r.action === 'block' && r.reason === 'warnings-pending' ? 'PASS' : 'FAIL:'+JSON.stringify(r));
" 2>/dev/null)
    if [ "$out" = "PASS" ]; then
        pass "G5. warnings_summary set -> checkReviewTests block/warnings-pending"
    else
        fail "G5. warnings_summary -> expected block/warnings-pending, got: $out"
    fi
}

run_g6() {
    # G6: markReviewTestsComplete success -> wsid field written to state
    local sid result_wsid result_token
    sid="g6-$$-$RANDOM"
    run_with_timeout 10 node -e "
const m = require('$STATE_IO_NODE');
const state = m.createInitialState(process.argv[1], {cwd: '.'});
m.writeState(process.argv[1], state);
" -- "$sid" 2>/dev/null
    run_with_timeout 10 node -e "
const m = require('$STATE_IO_NODE');
m.markReviewTestsComplete(process.argv[1], 'test-token-g6', {});
" -- "$sid" 2>/dev/null
    result_wsid=$(run_with_timeout 5 node -e "
const m = require('$STATE_IO_NODE');
const s = m.readState(process.argv[1]);
const rt = s && s.steps && s.steps.review_tests;
process.stdout.write(rt && 'wsid' in rt ? 'HAS_WSID' : 'NO_WSID');
" -- "$sid" 2>/dev/null)
    result_token=$(run_with_timeout 5 node -e "
const m = require('$STATE_IO_NODE');
const s = m.readState(process.argv[1]);
const rt = s && s.steps && s.steps.review_tests;
process.stdout.write(rt && rt.token ? rt.token : 'NO_TOKEN');
" -- "$sid" 2>/dev/null)
    if [ "$result_wsid" = "HAS_WSID" ] && [ "$result_token" = "test-token-g6" ]; then
        pass "G6. markReviewTestsComplete success -> wsid field + token written to state"
    else
        fail "G6. expected HAS_WSID+test-token-g6, got wsid=$result_wsid token=$result_token"
    fi
}

run_g3b() {
    # G3b: markReviewTestsComplete graceful-null path -> wsid field always present (null or value),
    # status becomes complete. Exercises the null-coalescence branch: wsid = resolver() || null.
    local sid result_wsid result_status
    sid="g3b-$$-$RANDOM"
    run_with_timeout 10 node -e "
const m = require('$STATE_IO_NODE');
const state = m.createInitialState(process.argv[1], {cwd: '.'});
m.writeState(process.argv[1], state);
m.markReviewTestsComplete(process.argv[1], 'token-g3b', {});
" -- "$sid" 2>/dev/null
    result_wsid=$(run_with_timeout 5 node -e "
const m = require('$STATE_IO_NODE');
const s = m.readState(process.argv[1]);
const rt = s && s.steps && s.steps.review_tests;
// wsid field is always written (null or a sid string).
process.stdout.write(rt && 'wsid' in rt ? 'HAS_WSID' : 'NO_WSID');
" -- "$sid" 2>/dev/null)
    result_status=$(run_with_timeout 5 node -e "
const m = require('$STATE_IO_NODE');
const s = m.readState(process.argv[1]);
const rt = s && s.steps && s.steps.review_tests;
process.stdout.write(rt ? rt.status : 'MISSING');
" -- "$sid" 2>/dev/null)
    if [ "$result_status" = "complete" ] && [ "$result_wsid" = "HAS_WSID" ]; then
        pass "G3b. markReviewTestsComplete always writes wsid field (null or sid), status=complete"
    else
        fail "G3b. expected complete+HAS_WSID, got status=$result_status wsid=$result_wsid"
    fi
}

run_g1
run_g2
run_g3
run_g3b
run_g4
run_g5
run_g6
