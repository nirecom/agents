#!/bin/bash
# Tests: hooks/workflow-mark/review-tests-handler.js, hooks/workflow-state/state-io/review-tests.js
# Tags: scope:issue-specific review-tests fingerprint handler
#
# Tests for the fingerprint-based review_tests handler (#2327 stage 2):
# COMPLETE/WARNINGS record only when payload fingerprint matches handler's own
# computed manifest digest; mismatch/no-payload/calc-error → signalFatal (exit 2).
# WARNINGS no longer uses token||"warnings" fallback. review_scope_manifest {v:1,files}
# written; token and reopen_reason tombstoned on both COMPLETE and WARNINGS.
#
# TDD: tests FAIL until plan-2327 stage-2 implementation lands.

MARK_HOOK="$AGENTS_DIR/hooks/workflow-mark.js"
STATE_IO="$AGENTS_DIR/hooks/workflow-state/state-io.js"
EVIDENCE="$AGENTS_DIR/hooks/workflow-gate/review-tests-evidence.js"
AGENTS_N="$(np "$AGENTS_DIR")"
EVIDENCE_N="$(np "$EVIDENCE")"

setup_repo() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    harness_git_init "$repo"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.autocrlf false
    printf 'init\n' > "$repo/init.txt"
    git -C "$repo" add init.txt
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

stage_file() {
    local repo="$1" relpath="$2" content="${3:-content}"
    mkdir -p "$(dirname "$repo/$relpath")"
    printf '%s\n' "$content" > "$repo/$relpath"
    git -C "$repo" add "$relpath"
}

# write_state_json <sid> [<warnings_summary>] — the optional summary is seeded so a
# rejected sentinel can be shown to leave it byte-identical.
write_state_json() {
    local sid="$1" ws="${2:-}" now ws_json=""
    now="$(node -e "process.stdout.write(new Date().toISOString())" 2>/dev/null)"
    [ -n "$ws" ] && ws_json=",\"warnings_summary\":\"$ws\""
    printf '%s\n' "{\"version\":1,\"session_id\":\"$sid\",\"git_branch\":\"feature/x\",\"created_at\":\"$now\",\"steps\":{\"review_tests\":{\"status\":\"pending\",\"token\":\"oldtoken\",\"reopen_reason\":\"write-code-stale\"$ws_json,\"updated_at\":\"$now\"}}}" \
        > "$WORKFLOW_STATE_DIR/${sid}.json"
}

SEEDED_WS="W-seeded: 1 prior advisory finding"

compute_fingerprint() {
    local repo_n="$1"
    run_with_timeout 15 node -e "
try {
  var e = require('$EVIDENCE_N');
  if(typeof e.computeReviewScopeFingerprint !== 'function') {
    process.stdout.write(''); process.exit(0);
  }
  var r = e.computeReviewScopeFingerprint('$repo_n');
  process.stdout.write(r && r.ok && r.fingerprint ? r.fingerprint : '');
}
catch(err) { process.stdout.write(''); }
" 2>/dev/null
}

build_mark_json() {
    local cmd="$1" sid="$2" cwd="${3:-}"
    run_with_timeout 10 node -e "
var j = {tool_name:'Bash',tool_input:{command:process.argv[1]},tool_response:{exit_code:0,stdout:'',stderr:''},session_id:process.argv[2]};
if(process.argv[3]) j.cwd = process.argv[3];
process.stdout.write(JSON.stringify(j));
" -- "$cmd" "$sid" "$cwd" 2>/dev/null
}

run_mark() {
    local repo="$1" json="$2"
    local repo_n; repo_n="$(np "$repo")"
    echo "$json" | run_with_timeout 30 env \
        CLAUDE_PROJECT_DIR="$repo_n" \
        WORKFLOW_STATE_DIR="$WORKFLOW_STATE_DIR" \
        AGENTS_CONFIG_DIR="$AGENTS_N" \
        node "$MARK_HOOK" 2>/dev/null
}

run_mark_rc() {
    local repo="$1" json="$2"
    local repo_n; repo_n="$(np "$repo")"
    echo "$json" | run_with_timeout 30 env \
        CLAUDE_PROJECT_DIR="$repo_n" \
        WORKFLOW_STATE_DIR="$WORKFLOW_STATE_DIR" \
        AGENTS_CONFIG_DIR="$AGENTS_N" \
        node "$MARK_HOOK" >/dev/null 2>/dev/null
    echo $?
}

read_step_field() {
    local sid="$1" field="$2"
    run_with_timeout 5 node -e "
try {
  var S = require('$AGENTS_N/hooks/workflow-state/state-io.js');
  var s = S.readState(process.argv[1]);
  var rt = s && s.steps && s.steps.review_tests;
  var v = rt && rt['$field'];
  process.stdout.write(v == null ? (rt && '$field' in rt ? 'NULL' : 'MISSING') : JSON.stringify(v));
}
catch(e) { process.stdout.write('MISSING'); }
" -- "$sid" 2>/dev/null
}

read_step_status() {
    local sid="$1"
    run_with_timeout 5 node -e "
try {
  var S = require('$AGENTS_N/hooks/workflow-state/state-io.js');
  var s = S.readState(process.argv[1]);
  var rt = s && s.steps && s.steps.review_tests;
  process.stdout.write(rt && rt.status ? rt.status : 'MISSING');
}
catch(e) { process.stdout.write('MISSING'); }
" -- "$sid" 2>/dev/null
}

# ============================================================================
case_begin "complete-matching-fingerprint-records" "hooks/workflow-mark/review-tests-handler.js"
# ============================================================================

echo "=== COMPLETE with matching fingerprint → records manifest, tombstones token ==="

REPO_C1="$(setup_repo "h-complete-ok")"
REPO_C1_N="$(np "$REPO_C1")"
stage_file "$REPO_C1" "tests/foo.sh" "echo test"
stage_file "$REPO_C1" "hooks/impl.js" "v1"

FP_C1="$(compute_fingerprint "$REPO_C1_N")"

if [ -z "$FP_C1" ]; then
    fail "C1 setup: computeReviewScopeFingerprint not available (impl pending)"
else
    SID_C1="hc1-$$"
    write_state_json "$SID_C1"
    SENTINEL_C1="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=$FP_C1>>\""
    run_mark "$REPO_C1" "$(build_mark_json "$SENTINEL_C1" "$SID_C1" "$REPO_C1_N")" >/dev/null

    STATUS_C1="$(read_step_status "$SID_C1")"
    MANIFEST_C1="$(read_step_field "$SID_C1" "review_scope_manifest")"
    TOKEN_C1="$(read_step_field "$SID_C1" "token")"

    if [ "$STATUS_C1" = "complete" ]; then
        pass "COMPLETE with matching fingerprint → status=complete"
    else
        fail "COMPLETE matching: status" "got=$STATUS_C1"
    fi

    if echo "$MANIFEST_C1" | grep -q '"v":1'; then
        pass "COMPLETE: review_scope_manifest {v:1} written"
    else
        fail "COMPLETE: review_scope_manifest" "got=$MANIFEST_C1"
    fi

    if [ "$TOKEN_C1" = "MISSING" ]; then
        pass "COMPLETE: token tombstoned (absent from projection)"
    else
        fail "COMPLETE: token should be tombstoned" "got=$TOKEN_C1"
    fi

    REOPEN_C1="$(read_step_field "$SID_C1" "reopen_reason")"
    if [ "$REOPEN_C1" = "MISSING" ]; then
        pass "COMPLETE: reopen_reason tombstoned"
    else
        fail "COMPLETE: reopen_reason should be tombstoned" "got=$REOPEN_C1"
    fi
fi

case_end

# ============================================================================
case_begin "complete-mismatch-signals-fatal" "hooks/workflow-mark/review-tests-handler.js"
# ============================================================================

echo "=== COMPLETE with mismatched fingerprint → signalFatal, nothing recorded ==="

REPO_C2="$(setup_repo "h-complete-mismatch")"
stage_file "$REPO_C2" "tests/foo.sh" "echo test"

SID_C2="hc2-$$"
write_state_json "$SID_C2"
# Wrong fingerprint
SENTINEL_C2="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=0000000000000000>>\""
RC_C2="$(run_mark_rc "$REPO_C2" "$(build_mark_json "$SENTINEL_C2" "$SID_C2" "$(np "$REPO_C2")")")"
STATUS_C2="$(read_step_status "$SID_C2")"

if [ "$RC_C2" = "2" ]; then
    pass "COMPLETE mismatch: signalFatal (exit 2)"
else
    fail "COMPLETE mismatch: expected exit 2 (signalFatal)" "got=$RC_C2"
fi
if [ "$STATUS_C2" = "pending" ]; then
    pass "COMPLETE mismatch: nothing recorded (status=pending)"
else
    fail "COMPLETE mismatch: expected pending" "got=$STATUS_C2"
fi

case_end

# ============================================================================
case_begin "complete-no-payload-signals-fatal" "hooks/workflow-mark/review-tests-handler.js"
# ============================================================================

echo "=== COMPLETE with no fingerprint payload → signalFatal, nothing recorded ==="

REPO_C3="$(setup_repo "h-complete-nofp")"
stage_file "$REPO_C3" "tests/foo.sh" "echo test"

SID_C3="hc3-$$"
write_state_json "$SID_C3"
# No fingerprint= in payload
SENTINEL_C3="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: someother=info>>\""
RC_C3="$(run_mark_rc "$REPO_C3" "$(build_mark_json "$SENTINEL_C3" "$SID_C3" "$(np "$REPO_C3")")")"
STATUS_C3="$(read_step_status "$SID_C3")"

if [ "$RC_C3" = "2" ]; then
    pass "COMPLETE no-payload: signalFatal (exit 2)"
else
    fail "COMPLETE no-payload: expected exit 2" "got=$RC_C3"
fi
if [ "$STATUS_C3" = "pending" ]; then
    pass "COMPLETE no-payload: nothing recorded"
else
    fail "COMPLETE no-payload: expected pending" "got=$STATUS_C3"
fi

case_end

# ============================================================================
case_begin "warnings-matching-fingerprint-records" "hooks/workflow-mark/review-tests-handler.js"
# ============================================================================

echo "=== WARNINGS with matching fingerprint → records, no token fallback ==="

REPO_W1="$(setup_repo "h-warnings-ok")"
REPO_W1_N="$(np "$REPO_W1")"
stage_file "$REPO_W1" "tests/foo.sh" "echo warnings-test"

FP_W1="$(compute_fingerprint "$REPO_W1_N")"

if [ -z "$FP_W1" ]; then
    fail "W1 setup: computeReviewScopeFingerprint not available (impl pending)"
else
    SID_W1="hw1-$$"
    write_state_json "$SID_W1"
    SENTINEL_W1="echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS: fingerprint=$FP_W1 warnings=2>>\""
    run_mark "$REPO_W1" "$(build_mark_json "$SENTINEL_W1" "$SID_W1" "$REPO_W1_N")" >/dev/null

    STATUS_W1="$(read_step_status "$SID_W1")"
    MANIFEST_W1="$(read_step_field "$SID_W1" "review_scope_manifest")"
    TOKEN_W1="$(read_step_field "$SID_W1" "token")"
    WARNINGS_W1="$(read_step_field "$SID_W1" "warnings_summary")"

    [ "$STATUS_W1" = "complete" ] && pass "WARNINGS matching: status=complete" || fail "WARNINGS matching: status" "got=$STATUS_W1"
    echo "$MANIFEST_W1" | grep -q '"v":1' && pass "WARNINGS: review_scope_manifest written" || fail "WARNINGS: manifest" "got=$MANIFEST_W1"
    [ "$TOKEN_W1" = "MISSING" ] && pass "WARNINGS: token tombstoned" || fail "WARNINGS: token should be tombstoned" "got=$TOKEN_W1"
    [ "$WARNINGS_W1" != "MISSING" ] && pass "WARNINGS: warnings_summary recorded" || fail "WARNINGS: warnings_summary missing"
fi

case_end

# ============================================================================
case_begin "warnings-no-token-fallback" "hooks/workflow-mark/review-tests-handler.js"
# ============================================================================

echo "=== WARNINGS without fingerprint no longer falls back to token=warnings ==="

REPO_W2="$(setup_repo "h-warnings-nofp")"
stage_file "$REPO_W2" "tests/foo.sh" "echo wtest"

SID_W2="hw2-$$"
write_state_json "$SID_W2"
# Old-style WARNINGS without fingerprint= (and without token=) — must signalFatal
SENTINEL_W2="echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS: warnings=3>>\""
RC_W2="$(run_mark_rc "$REPO_W2" "$(build_mark_json "$SENTINEL_W2" "$SID_W2" "$(np "$REPO_W2")")")"
STATUS_W2="$(read_step_status "$SID_W2")"

if [ "$RC_W2" = "2" ]; then
    pass "WARNINGS no-fingerprint: signalFatal (no token||'warnings' fallback)"
else
    fail "WARNINGS no-fingerprint: expected exit 2" "got=$RC_W2"
fi
if [ "$STATUS_W2" = "pending" ]; then
    pass "WARNINGS no-fingerprint: nothing recorded"
else
    fail "WARNINGS no-fingerprint: expected pending" "got=$STATUS_W2"
fi

case_end

# ============================================================================
case_begin "warnings-mismatch-signals-fatal" "hooks/workflow-mark/review-tests-handler.js"
# ============================================================================

echo "=== WARNINGS with mismatched fingerprint → signalFatal, nothing recorded (symmetric with COMPLETE) ==="

REPO_W3="$(setup_repo "h-warnings-mismatch")"
REPO_W3_N="$(np "$REPO_W3")"
stage_file "$REPO_W3" "tests/foo.sh" "echo w3-v1"
# Stale fingerprint: digest of the staged set before a re-edit; literal fallback while impl is pending.
FP_W3="$(compute_fingerprint "$REPO_W3_N")"
[ -n "$FP_W3" ] || FP_W3="0000000000000000"
stage_file "$REPO_W3" "tests/foo.sh" "echo w3-v2-re-edited"

SID_W3="hw3-$$"
write_state_json "$SID_W3" "$SEEDED_WS"
SENTINEL_W3="echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS: fingerprint=$FP_W3 warnings=2>>\""
RC_W3="$(run_mark_rc "$REPO_W3" "$(build_mark_json "$SENTINEL_W3" "$SID_W3" "$REPO_W3_N")")"
STATUS_W3="$(read_step_status "$SID_W3")"
WARNINGS_W3="$(read_step_field "$SID_W3" "warnings_summary")"

if [ "$RC_W3" = "2" ]; then
    pass "WARNINGS mismatch: signalFatal (exit 2)"
else
    fail "WARNINGS mismatch: expected exit 2 (signalFatal)" "got=$RC_W3"
fi
if [ "$STATUS_W3" = "pending" ]; then
    pass "WARNINGS mismatch: nothing recorded (status=pending)"
else
    fail "WARNINGS mismatch: expected pending" "got=$STATUS_W3"
fi
if [ "$WARNINGS_W3" = "\"$SEEDED_WS\"" ]; then
    pass "WARNINGS mismatch: seeded warnings_summary unchanged (new summary not recorded)"
else
    fail "WARNINGS mismatch: warnings_summary must stay the seeded value" "got=$WARNINGS_W3"
fi
# Rejected WARNINGS must leave the prior state untouched: no manifest written,
# seeded token / reopen_reason NOT tombstoned (tombstoning only on accepted record).
MANIFEST_W3="$(read_step_field "$SID_W3" "review_scope_manifest")"
TOKEN_W3="$(read_step_field "$SID_W3" "token")"
REOPEN_W3="$(read_step_field "$SID_W3" "reopen_reason")"
[ "$MANIFEST_W3" = "MISSING" ] && pass "WARNINGS mismatch: review_scope_manifest not written" || fail "WARNINGS mismatch: manifest must not be written" "got=$MANIFEST_W3"
[ "$TOKEN_W3" = '"oldtoken"' ] && pass "WARNINGS mismatch: token unchanged" || fail "WARNINGS mismatch: token must stay oldtoken" "got=$TOKEN_W3"
[ "$REOPEN_W3" = '"write-code-stale"' ] && pass "WARNINGS mismatch: reopen_reason unchanged" || fail "WARNINGS mismatch: reopen_reason must stay" "got=$REOPEN_W3"

case_end

# ============================================================================
case_begin "fingerprint-calc-failure-signals-fatal" "hooks/workflow-mark/review-tests-handler.js"
# ============================================================================

echo "=== handler fingerprint calc failure (project dir is not a git repo) → exit 2, no state change ==="

# CLAUDE_PROJECT_DIR points at a plain directory: the handler cannot compute its
# own manifest digest, so it must fail closed for both COMPLETE and WARNINGS.
NOGIT_DIR="$TMPDIR_BASE/h-nogit"
mkdir -p "$NOGIT_DIR/tests"
printf 'echo x\n' > "$NOGIT_DIR/tests/foo.sh"
NOGIT_N="$(np "$NOGIT_DIR")"
for _kind in COMPLETE WARNINGS; do
    _sid="hcf-$_kind-$$"
    write_state_json "$_sid" "$SEEDED_WS"
    if [ "$_kind" = "COMPLETE" ]; then
        _sent="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=0123456789abcdef>>\""
    else
        _sent="echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS: fingerprint=0123456789abcdef warnings=1>>\""
    fi
    _rc="$(run_mark_rc "$NOGIT_DIR" "$(build_mark_json "$_sent" "$_sid" "$NOGIT_N")")"
    _st="$(read_step_status "$_sid")"
    _tok="$(read_step_field "$_sid" "token")"
    _man="$(read_step_field "$_sid" "review_scope_manifest")"
    [ "$_rc" = "2" ] && pass "calc-failure $_kind: exit 2" || fail "calc-failure $_kind: expected exit 2" "got=$_rc"
    [ "$_st" = "pending" ] && pass "calc-failure $_kind: status stays pending" || fail "calc-failure $_kind: status" "got=$_st"
    [ "$_tok" = '"oldtoken"' ] && [ "$_man" = "MISSING" ] && pass "calc-failure $_kind: token/manifest unchanged" || fail "calc-failure $_kind: state mutated" "token=$_tok manifest=$_man"
    _ws="$(read_step_field "$_sid" "warnings_summary")"
    _ro="$(read_step_field "$_sid" "reopen_reason")"
    [ "$_ws" = "\"$SEEDED_WS\"" ] && pass "calc-failure $_kind: seeded warnings_summary unchanged" || fail "calc-failure $_kind: warnings_summary mutated" "got=$_ws"
    [ "$_ro" = '"write-code-stale"' ] && pass "calc-failure $_kind: reopen_reason unchanged" || fail "calc-failure $_kind: reopen_reason mutated" "got=$_ro"
done

case_end

# ============================================================================
case_begin "state-io-markReviewTestsComplete-new-signature" "hooks/workflow-state/state-io/review-tests.js"
# ============================================================================

echo "=== markReviewTestsComplete: new signature records manifest and tombstones ==="

SID_S1="hs1-$$"
MANIFEST_ARG='{"tests/foo.sh":"abc123def456abcd1234567890abcdef"}'

NEW_SIG_OUT=$(run_with_timeout 15 node -e "
try {
  var S = require('$AGENTS_N/hooks/workflow-state/state-io.js');
  var sid = '$SID_S1';
  var state = S.createInitialState(sid, {cwd:'.'});
  S.writeState(sid, state);
  // Seed the fields that must be tombstoned so their absence below is non-vacuous.
  S.markStep(sid, 'review_tests', 'pending', {token:'oldtoken', reopen_reason:'write-code-stale'});
  var seeded = (S.readState(sid).steps || {}).review_tests || {};
  if(!('token' in seeded) || !('reopen_reason' in seeded)) { process.stdout.write('SEED_FAILED:' + JSON.stringify(seeded)); process.exit(0); }
  var files = $MANIFEST_ARG;
  // New signature: markReviewTestsComplete(sessionId, manifestFiles, extraFields)
  S.markReviewTestsComplete(sid, files, {});
  var s = S.readState(sid);
  var rt = s && s.steps && s.steps.review_tests;
  var fails = [];
  if(!rt || rt.status !== 'complete') fails.push('status:'+JSON.stringify(rt && rt.status));
  if(!rt || !rt.review_scope_manifest || rt.review_scope_manifest.v !== 1)
    fails.push('manifest:'+JSON.stringify(rt && rt.review_scope_manifest));
  if(rt && 'token' in rt) fails.push('token-not-tombstoned:'+JSON.stringify(rt.token));
  if(rt && 'reopen_reason' in rt) fails.push('reopen_reason-not-tombstoned');
  process.stdout.write(fails.length === 0 ? 'PASS' : 'FAIL:' + fails.join(';'));
}
catch(e) { process.stdout.write('ERROR:' + e.message); }
" 2>/dev/null)
[ "$NEW_SIG_OUT" = "PASS" ] && pass "markReviewTestsComplete: manifest written, token/reopen_reason tombstoned" || fail "markReviewTestsComplete new signature" "$NEW_SIG_OUT"

case_end
