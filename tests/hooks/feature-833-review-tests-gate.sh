#!/bin/bash
# Tests: hooks/workflow-gate.js, hooks/workflow-mark.js, hooks/workflow-mark/review-tests-handler.js, hooks/workflow-gate/review-tests-evidence.js, hooks/workflow-state/state-io.js
# Tags: workflow, gate, hook, review-tests, sentinel, stale-token, stale-fingerprint, scope:issue-specific
# Gate/mark integration tests for the review_tests step (#833): gate blocks on pending,
# REVIEW_TESTS_COMPLETE/WARNINGS sentinels mark+record review_scope_manifest,
# stale-fingerprint detection re-blocks on scope change, WRITE_TESTS_NOT_NEEDED
# propagates skip, manual MARK_STEP is rejected, all-complete approves, wsid enforced.
# L3 gap: live /review-tests sentinel emission + terminal rendering need a real session.
# Pre-implementation expectation: all tests FAIL until write-code lands.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE_HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate.js"
MARK_HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark.js"
REVIEW_TESTS_HANDLER="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark/review-tests-handler.js"
REVIEW_TESTS_EVIDENCE="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate/review-tests-evidence.js"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

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
const d=path.join(os.tmpdir(),'rtg-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export WORKFLOW_STATE_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Plans-dir isolation (#1799): supervisor-emit must never write into the
# developer's real ~/.workflow-plans/. Pinned alongside WORKFLOW_STATE_DIR.
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR

NOW_ISO="$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")"

# workflow-gate gates only the repo its own checkout belongs to: the gate runners launch it from
# a copy of this checkout attached to the fixture repo.
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

# Compute the review-scope fingerprint for currently-staged files under repo.
compute_token() {
    local repo="$1"
    run_with_timeout 10 node -e "
        try {
            const m = require(process.argv[1]);
            const r = m.computeReviewScopeFingerprint(process.argv[2]);
            if (!r || !r.ok) { process.stdout.write('ERR'); }
            else if (!r.fingerprint) { process.stdout.write('EMPTY'); }
            else { process.stdout.write(String(r.fingerprint)); }
        } catch (e) {
            process.stdout.write('ERROR:' + e.message);
        }
    " -- "$REVIEW_TESTS_EVIDENCE" "$repo" 2>/dev/null
}

# Compute the review-scope manifest JSON for currently-staged files under repo.
# Failure prints JSON null so the embedding state file stays parseable — a
# non-JSON marker would make the gate report "no workflow state" instead.
compute_manifest() {
    local repo="$1"
    run_with_timeout 10 node -e "
        try {
            const m = require(process.argv[1]);
            const r = m.computeReviewScopeManifest(process.argv[2]);
            process.stdout.write(r && r.ok ? JSON.stringify({v:1, files:r.files}) : 'null');
        } catch (e) {
            process.stdout.write('null');
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

# #1733: state on disk is an append-only event stream (no top-level .steps);
# read through readState() so v1 fixtures migrate and the event log projects.
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

read_step_field() {
    # Read a sub-field of a step entry (e.g. token, warnings_summary, skip_reason).
    local sid="$1" step="$2" field="$3"
    local f="$WORKFLOW_DIR/${sid}.json"
    [ -f "$f" ] || { echo "MISSING"; return; }
    WORKFLOW_STATE_DIR="$WORKFLOW_DIR" run_with_timeout 5 node -e "
      try {
        const S = require(process.argv[2] + '/hooks/workflow-state/state-io.js');
        const s = S.readState(process.argv[1]);
        const st = s && s.steps && s.steps['$step'];
        const v = st && st['$field'];
        console.log(v == null ? 'MISSING' : (typeof v === 'object' ? JSON.stringify(v) : String(v)));
      } catch(e){ console.log('MISSING'); }
    " "$sid" "$SCRIPT_CHECKOUT_ROOT_N" 2>/dev/null || echo "MISSING"
}

# Build a state JSON with named-step overrides.
# Args: sid branch <step1> <status1> <step2> <status2> ...
# Optional inline meta: pass `review_scope_manifest <json>` to set manifest on the
# review_tests entry; pass `write_tests_skip_reason <str>` for skip_reason.
state_json_custom() {
    local sid="$1" branch="$2"; shift 2
    local branch_json
    if [ "$branch" = "null" ]; then branch_json="null"; else branch_json="\"$branch\""; fi
    local workflow_init="complete" clarify_intent="complete" research="complete"
    local outline="complete" detail="complete"
    local branching_complete="complete" write_tests="complete" review_tests="pending"
    local review_security="complete" run_tests="complete" docs="complete"
    local user_verification="complete" cleanup="complete"
    local pre_final_report_gate="complete"
    local review_scope_manifest=""
    local review_tests_warnings_summary=""
    local write_tests_skip_reason=""
    while [ $# -ge 2 ]; do
        case "$1" in
            workflow_init) workflow_init="$2";;
            clarify_intent) clarify_intent="$2";;
            research) research="$2";;
            outline) outline="$2";;
            detail) detail="$2";;
            branching_complete) branching_complete="$2";;
            write_tests) write_tests="$2";;
            review_tests) review_tests="$2";;
            review_security) review_security="$2";;
            run_tests) run_tests="$2";;
            docs) docs="$2";;
            user_verification) user_verification="$2";;
            cleanup) cleanup="$2";;
            pre_final_report_gate) pre_final_report_gate="$2";;
            review_scope_manifest) review_scope_manifest="$2";;
            review_tests_warnings_summary) review_tests_warnings_summary="$2";;
            write_tests_skip_reason) write_tests_skip_reason="$2";;
        esac
        shift 2
    done
    # Build review_tests entry inline so the optional fields appear only when set.
    local rt_extra=""
    if [ -n "$review_scope_manifest" ]; then
        rt_extra=", \"review_scope_manifest\": $review_scope_manifest"
    fi
    if [ -n "$review_tests_warnings_summary" ]; then
        rt_extra="${rt_extra}, \"warnings_summary\": \"$review_tests_warnings_summary\""
    fi
    local wt_extra=""
    if [ -n "$write_tests_skip_reason" ]; then
        wt_extra=", \"skip_reason\": \"$write_tests_skip_reason\""
    fi
    cat <<EOF
{
  "version": 1, "session_id": "$sid", "git_branch": $branch_json,
  "created_at": "$NOW_ISO",
  "steps": {
    "workflow_init":         {"status": "$workflow_init", "updated_at": "$NOW_ISO"},
    "clarify_intent":        {"status": "$clarify_intent", "updated_at": "$NOW_ISO"},
    "research":              {"status": "$research", "updated_at": "$NOW_ISO"},
    "outline":               {"status": "$outline", "updated_at": "$NOW_ISO"},
    "detail":                {"status": "$detail", "updated_at": "$NOW_ISO"},
    "branching_complete":    {"status": "$branching_complete", "updated_at": "$NOW_ISO"},
    "write_tests":           {"status": "$write_tests", "updated_at": "$NOW_ISO"$wt_extra},
    "review_tests":          {"status": "$review_tests", "updated_at": "$NOW_ISO"$rt_extra},
    "review_security":       {"status": "$review_security", "updated_at": "$NOW_ISO"},
    "run_tests":             {"status": "$run_tests", "updated_at": "$NOW_ISO"},
    "docs":                  {"status": "$docs", "updated_at": "$NOW_ISO"},
    "user_verification":     {"status": "$user_verification", "updated_at": "$NOW_ISO"},
    "cleanup":               {"status": "$cleanup", "updated_at": "$NOW_ISO"},
    "pre_final_report_gate": {"status": "$pre_final_report_gate", "updated_at": "$NOW_ISO"}
  }
}
EOF
}

# Build gate JSON payload (PreToolUse Bash).
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
    " -- "$cmd" "$sid" "$cwd"
}

# Build mark hook JSON (PostToolUse Bash).
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

run_gate() {
    local cwd="$1" json="$2"
    local common_dir main_dir=""
    session_repo_fixture_attach "$GATE_CHECKOUT" "$cwd" 2>/dev/null
    common_dir="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)" || common_dir=""
    if [ -n "$common_dir" ]; then
        main_dir="$(node -e "const p=require('path');process.stdout.write(p.dirname(p.resolve(process.argv[1],process.argv[2])))" -- "$cwd" "$common_dir" 2>/dev/null)" || main_dir=""
    fi
    local env_args=("CLAUDE_PROJECT_DIR=$cwd" "WORKFLOW_STATE_DIR=$WORKFLOW_DIR")
    [ -n "$main_dir" ] && env_args+=("AGENTS_MAIN_ROOT=$main_dir")
    echo "$json" | run_with_timeout 30 env "${env_args[@]}" node "$GATE_HOOK" 2>/dev/null
}

run_mark() {
    local cwd="$1" json="$2"
    echo "$json" | run_with_timeout 30 env CLAUDE_PROJECT_DIR="$cwd" \
        WORKFLOW_STATE_DIR="$WORKFLOW_DIR" node "$MARK_HOOK" 2>/dev/null
}

is_block() { echo "$1" | grep -q '"block"' || echo "$1" | grep -q '"deny"'; }
is_approve() { echo "$1" | grep -q '"approve"' || echo "$1" | grep -q '"allow"'; }

# --- Pre-implementation file gate ---
# We DON'T abort the suite if these are missing — we want individual cases to
# emit FAIL so /run-tests shows the expected red bar pre-write-code.
SOURCES_PRESENT=1
[ -f "$REVIEW_TESTS_HANDLER" ] || SOURCES_PRESENT=0
[ -f "$REVIEW_TESTS_EVIDENCE" ] || SOURCES_PRESENT=0
if [ "$SOURCES_PRESENT" -eq 0 ]; then
    echo "INFO: source files not yet present — tests will FAIL by design (TDD red phase)"
fi

# ============================================================================
# Section A: Gate blocks when review_tests is pending
# ============================================================================
echo "=== Section A: Gate block on pending review_tests ==="

REPO_A="$(setup_main_checkout "secA-repo")"

# A1: All steps complete except review_tests=pending → block commit
SID_A1="a1-$$"
PAIR_A1="$(setup_linked_worktree "secA-wt1")"
WT_A1="${PAIR_A1#*|}"
stage_test_file "$WT_A1" "tests/example.sh" "echo test A1"
write_state "$SID_A1" "$(state_json_custom "$SID_A1" "feature/secA-wt1" review_tests pending)"
RES_A1="$(run_gate "$WT_A1" "$(build_gate_json 'git commit -m wip' "$SID_A1" "$WT_A1")")"
if is_block "$RES_A1" && echo "$RES_A1" | grep -qi "review_tests\|review-tests"; then
    pass "A1. review_tests=pending blocks commit with review_tests hint"
else
    fail "A1. expected block w/ review_tests hint, got: $RES_A1"
fi

# A2: review_tests=complete, all others complete → approve
SID_A2="a2-$$"
PAIR_A2="$(setup_linked_worktree "secA-wt2")"
WT_A2="${PAIR_A2#*|}"
stage_test_file "$WT_A2" "tests/example.sh" "echo test A2"
MANIFEST_A2="$(compute_manifest "$WT_A2")"
write_state "$SID_A2" "$(state_json_custom "$SID_A2" "feature/secA-wt2" \
    review_tests complete \
    review_scope_manifest "$MANIFEST_A2")"
RES_A2="$(run_gate "$WT_A2" "$(build_gate_json 'git commit -m wip' "$SID_A2" "$WT_A2")")"
if is_approve "$RES_A2"; then
    pass "A2. all-complete (incl. review_tests w/ matching manifest) → approve"
else
    fail "A2. expected approve, got: $RES_A2"
fi

# ============================================================================
# Section B: REVIEW_TESTS_COMPLETE sentinel marks the step + records review_scope_manifest
# ============================================================================
echo ""
echo "=== Section B: REVIEW_TESTS_COMPLETE sentinel handling ==="

# B3: REVIEW_TESTS_COMPLETE with fingerprint records review_tests=complete + review_scope_manifest
SID_B3="b3-$$"
PAIR_B3="$(setup_linked_worktree "secB-wt3")"
WT_B3="${PAIR_B3#*|}"
stage_test_file "$WT_B3" "tests/example.sh" "echo test B3"
TOKEN_B3="$(compute_token "$WT_B3")"
write_state "$SID_B3" "$(state_json_custom "$SID_B3" "feature/secB-wt3" review_tests pending)"
SENTINEL_B3="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=$TOKEN_B3>>\""
run_mark "$WT_B3" "$(build_mark_json "$SENTINEL_B3" "$SID_B3" 0 "$WT_B3")" >/dev/null
STATUS_B3="$(read_state_step "$SID_B3" review_tests)"
RECORDED_MANIFEST_B3="$(read_step_field "$SID_B3" review_tests review_scope_manifest)"
if [ "$STATUS_B3" = "complete" ] && [ "$RECORDED_MANIFEST_B3" != "MISSING" ]; then
    pass "B3. REVIEW_TESTS_COMPLETE marks review_tests=complete + records review_scope_manifest"
else
    fail "B3. expected status=complete manifest!=MISSING, got status=$STATUS_B3 manifest=$RECORDED_MANIFEST_B3"
fi

# B4: REVIEW_TESTS_WARNINGS sentinel marks complete and records warnings_summary
SID_B4="b4-$$"
PAIR_B4="$(setup_linked_worktree "secB-wt4")"
WT_B4="${PAIR_B4#*|}"
stage_test_file "$WT_B4" "tests/example.sh" "echo test B4"
TOKEN_B4="$(compute_token "$WT_B4")"
write_state "$SID_B4" "$(state_json_custom "$SID_B4" "feature/secB-wt4" review_tests pending)"
SENTINEL_B4="echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS: fingerprint=$TOKEN_B4 warnings=3>>\""
run_mark "$WT_B4" "$(build_mark_json "$SENTINEL_B4" "$SID_B4" 0 "$WT_B4")" >/dev/null
STATUS_B4="$(read_state_step "$SID_B4" review_tests)"
WARNINGS_B4="$(read_step_field "$SID_B4" review_tests warnings_summary)"
if [ "$STATUS_B4" = "complete" ] && [ "$WARNINGS_B4" != "MISSING" ]; then
    pass "B4. REVIEW_TESTS_WARNINGS marks complete + records warnings_summary"
else
    fail "B4. expected status=complete warnings_summary set, got status=$STATUS_B4 ws=$WARNINGS_B4"
fi

# ============================================================================
# Section C: Stale-fingerprint detection (anti-bypass)
# ============================================================================
echo ""
echo "=== Section C: Stale-fingerprint detection ==="

# C5: After REVIEW_TESTS_COMPLETE, staging an additional file must
# invalidate the stored manifest fingerprint → next commit gate BLOCKS.
SID_C5="c5-$$"
PAIR_C5="$(setup_linked_worktree "secC-wt5")"
WT_C5="${PAIR_C5#*|}"
stage_test_file "$WT_C5" "tests/example.sh" "echo initial C5"
MANIFEST_C5_BEFORE="$(compute_manifest "$WT_C5")"
write_state "$SID_C5" "$(state_json_custom "$SID_C5" "feature/secC-wt5" \
    review_tests complete \
    review_scope_manifest "$MANIFEST_C5_BEFORE")"
# Now mutate the staged set — fingerprint should change.
stage_test_file "$WT_C5" "tests/example2.sh" "echo added C5"
if [ -z "$MANIFEST_C5_BEFORE" ] || [ "$MANIFEST_C5_BEFORE" = "null" ]; then
    fail "C5 precondition: manifest computation failed before scope change"
fi
RES_C5="$(run_gate "$WT_C5" "$(build_gate_json 'git commit -m wip' "$SID_C5" "$WT_C5")")"
if is_block "$RES_C5" && echo "$RES_C5" | grep -qi "review_tests\|stale\|re-run\|review-tests"; then
    pass "C5. stale fingerprint (scope changed after sentinel) → block commit"
else
    fail "C5. expected block on stale fingerprint, got: $RES_C5"
fi

# C8: REVIEW_TESTS_WARNINGS with matching manifest → gate still blocks (warnings not resolved)
SID_C8="c8-$$"
PAIR_C8="$(setup_linked_worktree "secC-wt8")"
WT_C8="${PAIR_C8#*|}"
stage_test_file "$WT_C8" "tests/example.sh" "echo test C8"
TOKEN_C8="$(compute_token "$WT_C8")"
MANIFEST_C8="$(compute_manifest "$WT_C8")"
write_state "$SID_C8" "$(state_json_custom "$SID_C8" "feature/secC-wt8" \
    review_tests complete \
    review_scope_manifest "$MANIFEST_C8" \
    review_tests_warnings_summary "fingerprint=$TOKEN_C8 warnings=2")"
RES_C8="$(run_gate "$WT_C8" "$(build_gate_json 'git commit -m wip' "$SID_C8" "$WT_C8")")"
if is_block "$RES_C8" && echo "$RES_C8" | grep -qi "review_tests\|warning\|review-tests"; then
    pass "C8. warnings_summary set (manifest matches) → gate still blocks until warnings resolved"
else
    fail "C8. expected block on warnings_summary, got: $RES_C8"
fi

# C9: warnings_summary blocks even when only non-excluded files are staged (HIGH-4 regression).
# Old null-token path skipped warnings check; new code checks warnings before staleness.
SID_C9="c9-$$"
PAIR_C9="$(setup_linked_worktree "secC-wt9")"
WT_C9="${PAIR_C9#*|}"
# Stage only a src file — tests/ not staged.
printf 'src change\n' > "$WT_C9/src.js"
git -C "$WT_C9" add src.js 2>/dev/null || true
MANIFEST_C9="$(compute_manifest "$WT_C9")"
write_state "$SID_C9" "$(state_json_custom "$SID_C9" "feature/secC-wt9" \
    review_tests complete \
    review_scope_manifest "$MANIFEST_C9" \
    review_tests_warnings_summary "missing edge case coverage")"
RES_C9="$(run_gate "$WT_C9" "$(build_gate_json 'git commit -m wip' "$SID_C9" "$WT_C9")")"
if is_block "$RES_C9" && echo "$RES_C9" | grep -qi "review_tests\|warning\|review-tests"; then
    pass "C9. warnings_summary blocks even when only non-test files are staged (HIGH-4 regression)"
else
    fail "C9. expected block when warnings_summary set + no staged tests, got: $RES_C9"
fi

# ============================================================================
# Section D: WRITE_TESTS_NOT_NEEDED propagates skip
# ============================================================================
echo ""
echo "=== Section D: skip propagation ==="

# D6: After WRITE_TESTS_NOT_NEEDED, review_tests is auto-skipped (no separate
#     REVIEW_TESTS_NOT_NEEDED sentinel exists — write_tests is the gate).
SID_D6="d6-$$"
PAIR_D6="$(setup_linked_worktree "secD-wt6")"
WT_D6="${PAIR_D6#*|}"
# Start state: write_tests + review_tests both pending.
write_state "$SID_D6" "$(state_json_custom "$SID_D6" "feature/secD-wt6" \
    write_tests pending review_tests pending)"
SENTINEL_D6='echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: pure docs change, no behavior delta>>"'
run_mark "$WT_D6" "$(build_mark_json "$SENTINEL_D6" "$SID_D6" 0 "$WT_D6")" >/dev/null
STATUS_WT_D6="$(read_state_step "$SID_D6" write_tests)"
STATUS_RT_D6="$(read_state_step "$SID_D6" review_tests)"
if [ "$STATUS_WT_D6" = "skipped" ] && [ "$STATUS_RT_D6" = "skipped" ]; then
    pass "D6. WRITE_TESTS_NOT_NEEDED propagates skip to review_tests"
else
    fail "D6. expected both skipped, got write_tests=$STATUS_WT_D6 review_tests=$STATUS_RT_D6"
fi

# ============================================================================
# Section E: Manual MARK_STEP review_tests is rejected (sourced)
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/feature-833-review-tests-gate/section-e.sh"

# ============================================================================
# Section F: wsid match enforcement (sourced)
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/feature-833-review-tests-gate/section-f.sh"

# ============================================================================
# Section G: checkReviewTests unit + markReviewTestsComplete error guard (sourced)
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/feature-833-review-tests-gate/section-g.sh"

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
