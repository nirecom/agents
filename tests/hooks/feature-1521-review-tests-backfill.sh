#!/bin/bash
# Tests: hooks/workflow-mark/review-tests-handler.js
# Tags: scope:issue-specific integration review-tests backfill fingerprint
#
# Backfill integration tests B1-B6 (write_tests auto-complete on COMPLETE/WARNINGS).
# B7-B8: WARNINGS_ACCEPTED fingerprint refresh (#2287 fix). See detail plan §2-7.
# Sentinels now use fingerprint= (was token=) per #2327.
# TDD: B1/B5/B7/B8 FAIL until fingerprint impl lands.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MARK_HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark.js"
GATE_HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate.js"
REVIEW_TESTS_HANDLER="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark/review-tests-handler.js"
REVIEW_TESTS_EVIDENCE="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate/review-tests-evidence.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' -- "$secs" "$@"
    fi
}

# ---------------------------------------------------------------------------
# Tmpdir + state isolation
# ---------------------------------------------------------------------------
TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'rtb-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export WORKFLOW_STATE_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR

NOW_ISO="$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")"

# workflow-gate gates only the repo its own checkout belongs to: run_gate launches it from a copy
# of this checkout attached to the fixture repo.
# shellcheck source=tests/lib/session-repo-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/session-repo-fixture.sh"
GATE_CHECKOUT="$TMPDIR_BASE/gate-checkout"
session_repo_fixture_create "$GATE_CHECKOUT" || { echo "FAIL: cannot copy the checkout for the gate"; exit 1; }
GATE_HOOK="$(session_repo_fixture_path "$GATE_CHECKOUT" hooks/workflow-gate.js)"

# ---------------------------------------------------------------------------
# Repo / worktree setup
# ---------------------------------------------------------------------------
setup_main_checkout() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" config core.autocrlf false
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

setup_linked_worktree() {
    local name="$1"
    local main; main="$(setup_main_checkout "$name-main")"
    local wt="$TMPDIR_BASE/$name-wt"
    git -C "$main" worktree add -q -b "feature/$name" "$wt" 2>/dev/null
    echo "$main|$wt"
}

stage_test_file() {
    local repo="$1" relpath="$2" content="$3"
    local dir
    dir="$(dirname "$repo/$relpath")"
    mkdir -p "$dir"
    printf '%s' "$content" > "$repo/$relpath"
    git -C "$repo" add "$relpath"
}

# Compute review-scope fingerprint. Calls computeReviewScopeFingerprint (new)
# or falls back to computeStagedTestsToken (old) for transition period.
compute_fingerprint() {
    local repo="$1"
    local repo_n
    repo_n="$(cygpath -m "$repo" 2>/dev/null || echo "$repo")"
    run_with_timeout 15 node -e "
        try {
            var m = require(process.argv[1]);
            if (typeof m.computeReviewScopeFingerprint === 'function') {
                var r = m.computeReviewScopeFingerprint(process.argv[2]);
                process.stdout.write(r && r.ok && r.fingerprint ? r.fingerprint : 'NULL');
            } else if (typeof m.computeStagedTestsToken === 'function') {
                var t = m.computeStagedTestsToken(process.argv[2]);
                process.stdout.write(t == null ? 'NULL' : String(t));
            } else {
                process.stdout.write('MISSING_FN');
            }
        } catch (e) {
            process.stdout.write('ERROR:' + e.message);
        }
    " -- "$REVIEW_TESTS_EVIDENCE" "$repo_n" 2>/dev/null
}

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------
write_state() {
    local sid="$1" json="$2"
    mkdir -p "$WORKFLOW_DIR"
    printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

SCRIPT_CHECKOUT_ROOT_N="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT" 2>/dev/null || echo "$SCRIPT_CHECKOUT_ROOT")"
read_state_step() {
    local sid="$1" step="$2"
    local f="$WORKFLOW_DIR/${sid}.json"
    [ -f "$f" ] || { echo "MISSING"; return; }
    WORKFLOW_STATE_DIR="$WORKFLOW_DIR" run_with_timeout 5 node -e "
      try {
        const S = require(process.argv[2] + '/hooks/workflow-state/state-io.js');
        const s = S.readState(process.argv[1]);
        const st = s && s.steps && s.steps['$step'];
        console.log(st && st.status ? st.status : 'MISSING');
      } catch(e){ console.log('MISSING'); }
    " "$sid" "$SCRIPT_CHECKOUT_ROOT_N" 2>/dev/null || echo "MISSING"
}

state_json() {
    local sid="$1" wt="$2" rt="$3"
    cat <<EOF
{
  "version": 1, "session_id": "$sid", "git_branch": "feature/x",
  "created_at": "$NOW_ISO",
  "steps": {
    "workflow_init":  {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":    {"status": "$wt", "updated_at": "$NOW_ISO"},
    "review_tests":   {"status": "$rt", "updated_at": "$NOW_ISO"}
  }
}
EOF
}

state_json_full() {
    local sid="$1" rt_status="$2" rt_manifest="${3:-}"
    local rt_extra=""
    if [ -n "$rt_manifest" ]; then
        rt_extra=", \"review_scope_manifest\": $rt_manifest"
    fi
    cat <<EOF
{
  "version": 1, "session_id": "$sid", "git_branch": "feature/b7",
  "created_at": "$NOW_ISO",
  "steps": {
    "workflow_init":      {"status": "complete", "updated_at": "$NOW_ISO"},
    "clarify_intent":     {"status": "complete", "updated_at": "$NOW_ISO"},
    "research":           {"status": "complete", "updated_at": "$NOW_ISO"},
    "outline":            {"status": "complete", "updated_at": "$NOW_ISO"},
    "detail":             {"status": "complete", "updated_at": "$NOW_ISO"},
    "branching_complete": {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":        {"status": "complete", "updated_at": "$NOW_ISO"},
    "review_tests":       {"status": "$rt_status", "updated_at": "$NOW_ISO"$rt_extra},
    "review_security":    {"status": "complete", "updated_at": "$NOW_ISO"},
    "run_tests":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "docs":               {"status": "complete", "updated_at": "$NOW_ISO"},
    "user_verification":  {"status": "complete", "updated_at": "$NOW_ISO"},
    "cleanup":            {"status": "complete", "updated_at": "$NOW_ISO"},
    "pre_final_report_gate": {"status": "complete", "updated_at": "$NOW_ISO"}
  }
}
EOF
}

build_mark_json() {
    local cmd="$1" sid="$2" exit_code="${3:-0}" cwd="${4:-}"
    run_with_timeout 10 node -e "
      const j = {
        tool_name: 'Bash',
        tool_input: { command: process.argv[1] },
        tool_response: { exit_code: Number(process.argv[3]), stdout: '', stderr: '' },
        session_id: process.argv[2]
      };
      if (process.argv[4]) j.cwd = process.argv[4];
      console.log(JSON.stringify(j));
    " -- "$cmd" "$sid" "$exit_code" "$cwd"
}

RC=0
run_mark() {
    local project_dir="$1" json="$2"
    echo "$json" | run_with_timeout 30 env CLAUDE_PROJECT_DIR="$project_dir" \
        WORKFLOW_STATE_DIR="$WORKFLOW_DIR" node "$MARK_HOOK" >/dev/null 2>&1
    RC=$?
}

run_gate() {
    local cwd="$1" json="$2"
    local cwd_n; cwd_n="$(cygpath -m "$cwd" 2>/dev/null || echo "$cwd")"
    # The gate's checkout is attached to the fixture repo so the #1138 cross-repo bypass
    # does not approve before review_tests is evaluated.
    session_repo_fixture_attach "$GATE_CHECKOUT" "$cwd" || return 1
    local common_dir main_dir
    common_dir="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    main_dir="$(dirname "$common_dir")"
    main_dir="$(cygpath -m "$main_dir" 2>/dev/null || echo "$main_dir")"
    echo "$json" | run_with_timeout 30 env \
        CLAUDE_PROJECT_DIR="$cwd_n" \
        WORKFLOW_STATE_DIR="$WORKFLOW_DIR" \
        AGENTS_MAIN_ROOT="$main_dir" \
        node "$GATE_HOOK" 2>/dev/null
}

build_gate_json() {
    local cmd="$1" sid="$2" cwd="$3"
    run_with_timeout 10 node -e "
      const j = {
        tool_name: 'Bash',
        tool_input: { command: process.argv[1] },
        session_id: process.argv[2],
        cwd: process.argv[3]
      };
      console.log(JSON.stringify(j));
    " -- "$cmd" "$sid" "$cwd" 2>/dev/null
}

is_block() { echo "$1" | grep -q '"block"' || echo "$1" | grep -q '"deny"'; }
is_approve() { echo "$1" | grep -q '"approve"' || echo "$1" | grep -q '"allow"'; }

SOURCES_PRESENT=1
[ -f "$REVIEW_TESTS_HANDLER" ] || SOURCES_PRESENT=0
[ -f "$REVIEW_TESTS_EVIDENCE" ] || SOURCES_PRESENT=0
if [ "$SOURCES_PRESENT" -eq 0 ]; then
    echo "INFO: source files not yet present — tests will FAIL by design (TDD red phase)"
fi

# ============================================================================
# B1: main path — write_tests+review_tests pending, tests/ staged → both complete
# ============================================================================
echo "=== B1: backfill on COMPLETE with staged tests ==="
SID_B1="b1-$$"
PAIR_B1="$(setup_linked_worktree "b1")"
WT_B1="${PAIR_B1#*|}"
stage_test_file "$WT_B1" "tests/example.sh" "echo test B1"
FP_B1="$(compute_fingerprint "$WT_B1")"
write_state "$SID_B1" "$(state_json "$SID_B1" pending pending)"
SENTINEL_B1="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=$FP_B1>>\""
run_mark "$WT_B1" "$(build_mark_json "$SENTINEL_B1" "$SID_B1" 0 "$WT_B1")"
RT_B1="$(read_state_step "$SID_B1" review_tests)"
WTS_B1="$(read_state_step "$SID_B1" write_tests)"
if [ "$RT_B1" = "complete" ] && [ "$WTS_B1" = "complete" ]; then
    pass "B1. COMPLETE + staged tests → review_tests AND write_tests complete"
else
    fail "B1. expected both complete, got review_tests=$RT_B1 write_tests=$WTS_B1"
fi

# ============================================================================
# B2: no evidence — src.js staged only → review_tests complete, write_tests pending
# ============================================================================
echo "=== B2: no backfill without tests/ evidence ==="
SID_B2="b2-$$"
PAIR_B2="$(setup_linked_worktree "b2")"
WT_B2="${PAIR_B2#*|}"
printf 'src change\n' > "$WT_B2/src.js"
git -C "$WT_B2" add src.js 2>/dev/null || true
FP_B2="$(compute_fingerprint "$WT_B2")"
write_state "$SID_B2" "$(state_json "$SID_B2" pending pending)"
SENTINEL_B2="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=$FP_B2>>\""
run_mark "$WT_B2" "$(build_mark_json "$SENTINEL_B2" "$SID_B2" 0 "$WT_B2")"
RT_B2="$(read_state_step "$SID_B2" review_tests)"
WTS_B2="$(read_state_step "$SID_B2" write_tests)"
if [ "$RT_B2" = "complete" ] && [ "$WTS_B2" = "pending" ]; then
    pass "B2. no staged tests → review_tests complete, write_tests stays pending"
else
    fail "B2. expected review_tests=complete write_tests=pending, got rt=$RT_B2 wt=$WTS_B2"
fi

# ============================================================================
# B3: idempotent — write_tests already complete → stays complete
# ============================================================================
echo "=== B3: idempotent when write_tests already complete ==="
SID_B3="b3-$$"
PAIR_B3="$(setup_linked_worktree "b3")"
WT_B3="${PAIR_B3#*|}"
stage_test_file "$WT_B3" "tests/example.sh" "echo test B3"
FP_B3="$(compute_fingerprint "$WT_B3")"
write_state "$SID_B3" "$(state_json "$SID_B3" complete pending)"
SENTINEL_B3="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=$FP_B3>>\""
run_mark "$WT_B3" "$(build_mark_json "$SENTINEL_B3" "$SID_B3" 0 "$WT_B3")"
RT_B3="$(read_state_step "$SID_B3" review_tests)"
WTS_B3="$(read_state_step "$SID_B3" write_tests)"
if [ "$RT_B3" = "complete" ] && [ "$WTS_B3" = "complete" ]; then
    pass "B3. write_tests already complete → stays complete (no regression)"
else
    fail "B3. expected both complete, got review_tests=$RT_B3 write_tests=$WTS_B3"
fi

# ============================================================================
# B4: WARNINGS path — write_tests stays pending (no backfill on WARNINGS)
# ============================================================================
echo "=== B4: WARNINGS does not backfill write_tests ==="
SID_B4="b4-$$"
PAIR_B4="$(setup_linked_worktree "b4")"
WT_B4="${PAIR_B4#*|}"
stage_test_file "$WT_B4" "tests/example.sh" "echo test B4"
FP_B4="$(compute_fingerprint "$WT_B4")"
write_state "$SID_B4" "$(state_json "$SID_B4" pending pending)"
SENTINEL_B4="echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS: fingerprint=$FP_B4 warnings=2>>\""
run_mark "$WT_B4" "$(build_mark_json "$SENTINEL_B4" "$SID_B4" 0 "$WT_B4")"
RT_B4="$(read_state_step "$SID_B4" review_tests)"
WTS_B4="$(read_state_step "$SID_B4" write_tests)"
if [ "$RT_B4" = "complete" ] && [ "$WTS_B4" = "pending" ]; then
    pass "B4. WARNINGS → review_tests complete, write_tests stays pending (no backfill)"
else
    fail "B4. expected review_tests=complete write_tests=pending, got rt=$RT_B4 wt=$WTS_B4"
fi

# ============================================================================
# B5: linked worktree CWD — CLAUDE_PROJECT_DIR=main, cwd=linked wt → backfill fires
# ============================================================================
echo "=== B5: linked-worktree cwd divergence → backfill still fires ==="
SID_B5="b5-$$"
PAIR_B5="$(setup_linked_worktree "b5")"
MAIN_B5="${PAIR_B5%%|*}"
WT_B5="${PAIR_B5#*|}"
stage_test_file "$WT_B5" "tests/example.sh" "echo test B5"
FP_B5="$(compute_fingerprint "$WT_B5")"
write_state "$SID_B5" "$(state_json "$SID_B5" pending pending)"
SENTINEL_B5="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=$FP_B5>>\""
run_mark "$MAIN_B5" "$(build_mark_json "$SENTINEL_B5" "$SID_B5" 0 "$WT_B5")"
RT_B5="$(read_state_step "$SID_B5" review_tests)"
WTS_B5="$(read_state_step "$SID_B5" write_tests)"
if [ "$RT_B5" = "complete" ] && [ "$WTS_B5" = "complete" ]; then
    pass "B5. cwd divergence → backfill resolves against linked wt"
else
    fail "B5. expected both complete, got review_tests=$RT_B5 write_tests=$WTS_B5"
fi

# ============================================================================
# B6: fail-open — corrupt state JSON → exit 0 (no crash)
# ============================================================================
echo "=== B6: fail-open on corrupt state ==="
SID_B6="b6-$$"
PAIR_B6="$(setup_linked_worktree "b6")"
WT_B6="${PAIR_B6#*|}"
stage_test_file "$WT_B6" "tests/example.sh" "echo test B6"
FP_B6="$(compute_fingerprint "$WT_B6")"
printf '{ this is not valid json' > "$WORKFLOW_DIR/${SID_B6}.json"
SENTINEL_B6="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=$FP_B6>>\""
run_mark "$WT_B6" "$(build_mark_json "$SENTINEL_B6" "$SID_B6" 0 "$WT_B6")"
if [ "$RC" -eq 0 ]; then
    pass "B6. corrupt state JSON → process exits 0 (fail-open)"
else
    fail "B6. expected exit 0 on corrupt state, got exit code: $RC"
fi

# ============================================================================
# B7: #2287 fix — WARNINGS → re-edit test and re-stage → WARNINGS_ACCEPTED
#     → gate skips (before fix: stale fingerprint block)
# ============================================================================
echo "=== B7: WARNINGS_ACCEPTED refreshes fingerprint → gate skips ==="
SID_B7="b7-$$"
PAIR_B7="$(setup_linked_worktree "b7")"
WT_B7="${PAIR_B7#*|}"

stage_test_file "$WT_B7" "tests/example.sh" "echo test B7 v1"
FP_B7_V1="$(compute_fingerprint "$WT_B7")"

write_state "$SID_B7" "$(state_json_full "$SID_B7" pending)"
SENTINEL_B7_WARN="echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS: fingerprint=$FP_B7_V1 warnings=1>>\""
run_mark "$WT_B7" "$(build_mark_json "$SENTINEL_B7_WARN" "$SID_B7" 0 "$WT_B7")"
RT_B7_AFTER_WARN="$(read_state_step "$SID_B7" review_tests)"

stage_test_file "$WT_B7" "tests/example.sh" "echo test B7 v2 revised"

SENTINEL_B7_ACCEPTED="echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: addressed coverage gap>>\""
run_mark "$WT_B7" "$(build_mark_json "$SENTINEL_B7_ACCEPTED" "$SID_B7" 0 "$WT_B7")"

WT_B7_N="$(cygpath -m "$WT_B7" 2>/dev/null || echo "$WT_B7")"
GATE_B7_JSON="$(build_gate_json "git commit -m test-b7" "$SID_B7" "$WT_B7_N")"
GATE_B7_RESULT="$(run_gate "$WT_B7" "$GATE_B7_JSON")"

if [ "$RT_B7_AFTER_WARN" = "complete" ]; then
    pass "B7 precond: WARNINGS records complete"
else
    fail "B7 precond: WARNINGS should set complete, got=$RT_B7_AFTER_WARN"
fi

if is_approve "$GATE_B7_RESULT"; then
    pass "B7. after WARNINGS_ACCEPTED refresh, gate approves (fresh fingerprint)"
else
    fail "B7. expected gate approve after WARNINGS_ACCEPTED refresh, got=$GATE_B7_RESULT"
fi

# ============================================================================
# B8: After WARNINGS_ACCEPTED, editing tests AGAIN → gate blocks (stale)
# ============================================================================
echo "=== B8: edit tests after WARNINGS_ACCEPTED → gate blocks (stale fingerprint) ==="
stage_test_file "$WT_B7" "tests/example.sh" "echo test B7 v3 after-acceptance"

GATE_B8_JSON="$(build_gate_json "git commit -m test-b8" "$SID_B7" "$WT_B7_N")"
GATE_B8_RESULT="$(run_gate "$WT_B7" "$GATE_B8_JSON")"

if is_block "$GATE_B8_RESULT" && echo "$GATE_B8_RESULT" | grep -q 'stale-fingerprint'; then
    pass "B8. editing tests after WARNINGS_ACCEPTED → gate blocks (stale)"
else
    fail "B8. expected gate block after re-edit post WARNINGS_ACCEPTED, got=$GATE_B8_RESULT"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
TOTAL=$((PASS + FAIL))
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"

if [ "$FAIL" -eq 0 ]; then
    exit 0
else
    exit 1
fi
