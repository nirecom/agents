#!/bin/bash
# Tests: review-tests-handler write_tests backfill (COMPLETE path, evidence-gated)
# Tags: scope:issue-specific integration review-tests backfill
#
# Integration tests (L2) for the write_tests backfill added to the
# WORKFLOW_REVIEW_TESTS_COMPLETE path in hooks/workflow-mark/review-tests-handler.js.
#
# Behavior under test: when REVIEW_TESTS_COMPLETE lands and marks
# review_tests=complete, the handler also backfills write_tests=complete IFF
# completion evidence exists (staged/committed tests/ under the resolved repo
# cwd). This closes the #1521 gap where a linked-worktree session left
# write_tests=pending even after tests were written and reviewed.
#
# Cases:
#   B1 main path      : write_tests+review_tests pending, tests/ staged → both complete
#   B2 no evidence    : no tests/ staged → review_tests complete, write_tests pending
#   B3 idempotent     : write_tests already complete → stays complete
#   B4 WARNINGS path  : WARNINGS sentinel → NO backfill (write_tests stays pending)
#   B5 linked worktree: CLAUDE_PROJECT_DIR=main, stdin cwd=linked wt → backfill fires
#   B6 fail-open      : corrupt/missing state → exit 0, no exception
#
# L3 gap (what this test does NOT catch):
# - Whether the real Claude Code PreToolUse/PostToolUse hook is actually invoked
#   with the linked-worktree path in stdin `cwd`. Only a live `claude -p` session
#   (RUN_TL3) exercises the harness stdin cwd wiring end-to-end. This L2 test
#   spawns workflow-mark.js directly with a synthesized stdin payload, so it
#   verifies handler + resolver logic but not the harness contract that supplies
#   the cwd. B5 is the closest-to-action guard for that wiring at L2.
#
# Pre-implementation expectation: B1 and B5 FAIL until the backfill lands.
# B2/B3/B4/B6 pass on current code (no backfill = pending preserved / idempotent).

set -u

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MARK_HOOK="$AGENTS_DIR/hooks/workflow-mark.js"
REVIEW_TESTS_HANDLER="$AGENTS_DIR/hooks/workflow-mark/review-tests-handler.js"
REVIEW_TESTS_EVIDENCE="$AGENTS_DIR/hooks/workflow-gate/review-tests-evidence.js"

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
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

NOW_ISO="$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")"

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

# Returns "<main_repo>|<wt_path>" — worktree on a feature branch.
setup_linked_worktree() {
    local name="$1"
    local main; main="$(setup_main_checkout "$name-main")"
    local wt="$TMPDIR_BASE/$name-wt"
    git -C "$main" worktree add -q -b "feature/$name" "$wt" 2>/dev/null
    echo "$main|$wt"
}

# Stage a tests/ file with given content in the repo.
stage_test_file() {
    local repo="$1" relpath="$2" content="$3"
    local dir
    dir="$(dirname "$repo/$relpath")"
    mkdir -p "$dir"
    printf '%s' "$content" > "$repo/$relpath"
    git -C "$repo" add "$relpath"
}

# Compute the deterministic token for currently-staged tests under repo.
compute_token() {
    local repo="$1"
    run_with_timeout 10 node -e "
        try {
            const m = require(process.argv[1]);
            const t = m.computeStagedTestsToken(process.argv[2]);
            process.stdout.write(t == null ? 'NULL' : String(t));
        } catch (e) {
            process.stdout.write('ERROR:' + e.message);
        }
    " -- "$REVIEW_TESTS_EVIDENCE" "$repo" 2>/dev/null
}

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------
write_state() {
    local sid="$1" json="$2"
    mkdir -p "$WORKFLOW_DIR"
    printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

read_state_step() {
    local sid="$1" step="$2"
    local f="$WORKFLOW_DIR/${sid}.json"
    [ -f "$f" ] || { echo "MISSING"; return; }
    run_with_timeout 5 node -e "
      try {
        const s = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
        const st = s.steps && s.steps['$step'];
        console.log(st && st.status ? st.status : 'MISSING');
      } catch(e){ console.log('MISSING'); }
    " "$f" 2>/dev/null || echo "MISSING"
}

# Minimal state JSON with write_tests / review_tests overrides.
# Args: sid write_tests_status review_tests_status
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

# Build mark hook JSON (PostToolUse Bash). cwd optional.
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

# Run workflow-mark.js. Args: project_dir json  → returns exit code via global RC.
RC=0
run_mark() {
    local project_dir="$1" json="$2"
    echo "$json" | run_with_timeout 30 env CLAUDE_PROJECT_DIR="$project_dir" \
        CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$MARK_HOOK" >/dev/null 2>&1
    RC=$?
}

# --- Pre-implementation file gate ---
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
TOKEN_B1="$(compute_token "$WT_B1")"
write_state "$SID_B1" "$(state_json "$SID_B1" pending pending)"
SENTINEL_B1="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=$TOKEN_B1>>\""
run_mark "$WT_B1" "$(build_mark_json "$SENTINEL_B1" "$SID_B1" 0 "$WT_B1")"
RT_B1="$(read_state_step "$SID_B1" review_tests)"
WTS_B1="$(read_state_step "$SID_B1" write_tests)"
if [ "$RT_B1" = "complete" ] && [ "$WTS_B1" = "complete" ]; then
    pass "B1. COMPLETE + staged tests → review_tests AND write_tests complete"
else
    fail "B1. expected both complete, got review_tests=$RT_B1 write_tests=$WTS_B1"
fi

# ============================================================================
# B2: no evidence — no tests/ staged → review_tests complete, write_tests pending
# ============================================================================
echo "=== B2: no backfill without evidence ==="
SID_B2="b2-$$"
PAIR_B2="$(setup_linked_worktree "b2")"
WT_B2="${PAIR_B2#*|}"
# Stage a non-tests file so the repo has a diff but no tests/ evidence.
printf 'src change\n' > "$WT_B2/src.js"
git -C "$WT_B2" add src.js 2>/dev/null || true
# Token is not evidence for write_tests backfill; use a placeholder token.
write_state "$SID_B2" "$(state_json "$SID_B2" pending pending)"
SENTINEL_B2="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=deadbeef>>\""
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
TOKEN_B3="$(compute_token "$WT_B3")"
write_state "$SID_B3" "$(state_json "$SID_B3" complete pending)"
SENTINEL_B3="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=$TOKEN_B3>>\""
run_mark "$WT_B3" "$(build_mark_json "$SENTINEL_B3" "$SID_B3" 0 "$WT_B3")"
RT_B3="$(read_state_step "$SID_B3" review_tests)"
WTS_B3="$(read_state_step "$SID_B3" write_tests)"
if [ "$RT_B3" = "complete" ] && [ "$WTS_B3" = "complete" ]; then
    pass "B3. write_tests already complete → stays complete (no regression)"
else
    fail "B3. expected both complete, got review_tests=$RT_B3 write_tests=$WTS_B3"
fi

# ============================================================================
# B4: WARNINGS path — no backfill (write_tests stays pending)
# ============================================================================
echo "=== B4: WARNINGS does not backfill write_tests ==="
SID_B4="b4-$$"
PAIR_B4="$(setup_linked_worktree "b4")"
WT_B4="${PAIR_B4#*|}"
stage_test_file "$WT_B4" "tests/example.sh" "echo test B4"
TOKEN_B4="$(compute_token "$WT_B4")"
write_state "$SID_B4" "$(state_json "$SID_B4" pending pending)"
SENTINEL_B4="echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS: token=$TOKEN_B4 warnings=2>>\""
run_mark "$WT_B4" "$(build_mark_json "$SENTINEL_B4" "$SID_B4" 0 "$WT_B4")"
RT_B4="$(read_state_step "$SID_B4" review_tests)"
WTS_B4="$(read_state_step "$SID_B4" write_tests)"
if [ "$RT_B4" = "complete" ] && [ "$WTS_B4" = "pending" ]; then
    pass "B4. WARNINGS → review_tests complete, write_tests stays pending (no backfill)"
else
    fail "B4. expected review_tests=complete write_tests=pending, got rt=$RT_B4 wt=$WTS_B4"
fi

# ============================================================================
# B5: linked worktree CWD — CLAUDE_PROJECT_DIR=main, stdin cwd=linked wt,
#     tests/ staged in linked wt → resolveRepoCwd guard + backfill → write_tests complete.
#     Core regression guard for #1521.
# ============================================================================
echo "=== B5: linked-worktree cwd divergence → backfill still fires ==="
SID_B5="b5-$$"
PAIR_B5="$(setup_linked_worktree "b5")"
MAIN_B5="${PAIR_B5%%|*}"
WT_B5="${PAIR_B5#*|}"
# Tests staged ONLY in the linked worktree; main worktree has no staged tests.
stage_test_file "$WT_B5" "tests/example.sh" "echo test B5"
TOKEN_B5="$(compute_token "$WT_B5")"
write_state "$SID_B5" "$(state_json "$SID_B5" pending pending)"
SENTINEL_B5="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=$TOKEN_B5>>\""
# CLAUDE_PROJECT_DIR points at MAIN (no staged tests there); stdin cwd points at
# the linked worktree (where tests ARE staged). Only the input.cwd guard makes
# evidence resolve against the linked worktree.
run_mark "$MAIN_B5" "$(build_mark_json "$SENTINEL_B5" "$SID_B5" 0 "$WT_B5")"
RT_B5="$(read_state_step "$SID_B5" review_tests)"
WTS_B5="$(read_state_step "$SID_B5" write_tests)"
if [ "$RT_B5" = "complete" ] && [ "$WTS_B5" = "complete" ]; then
    pass "B5. cwd divergence (main vs linked wt) → backfill resolves against linked wt"
else
    fail "B5. expected both complete, got review_tests=$RT_B5 write_tests=$WTS_B5"
fi

# ============================================================================
# B6: fail-open — corrupt state JSON → COMPLETE recording succeeds, exit 0
# ============================================================================
echo "=== B6: fail-open on corrupt state ==="
SID_B6="b6-$$"
PAIR_B6="$(setup_linked_worktree "b6")"
WT_B6="${PAIR_B6#*|}"
stage_test_file "$WT_B6" "tests/example.sh" "echo test B6"
TOKEN_B6="$(compute_token "$WT_B6")"
# Write deliberately corrupt (non-JSON) state.
printf '{ this is not valid json' > "$WORKFLOW_DIR/${SID_B6}.json"
SENTINEL_B6="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=$TOKEN_B6>>\""
run_mark "$WT_B6" "$(build_mark_json "$SENTINEL_B6" "$SID_B6" 0 "$WT_B6")"
if [ "$RC" -eq 0 ]; then
    pass "B6. corrupt state JSON → process exits 0 (fail-open, no exception)"
else
    fail "B6. expected exit 0 on corrupt state, got exit code: $RC"
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
