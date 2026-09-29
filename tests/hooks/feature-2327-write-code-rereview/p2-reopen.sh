#!/usr/bin/env bash
# Tests: hooks/workflow-state/review-tests-reopen.js
# Tags: tl2, workflow, write-code, review-tests, rereview, reopen, scope:issue-specific, pwsh-not-required
#
# review-tests-reopen.js: formatReviewTestsReopenNotice, the gate filter,
# fail-closed branches, no-tests, and session-worktree resolution when repoDir
# is absent. Fixtures come from the parent file (rr_repo / rr_state / rr_view).

REOPEN_MOD="$AGENTS_DIR_N/hooks/workflow-state/review-tests-reopen.js"
export REOPEN_MOD

echo "=== P2: review-tests-reopen module ==="

# rr_call <sid> <repoDir-or-empty> <gate> [cwd]: prints {kind,detail} of the result.
rr_call() {
  run_with_timeout node -e '
const [mod, sid, repo, gate, cwd] = process.argv.slice(1);
if (cwd) process.chdir(cwd);
delete process.env.CLAUDE_PROJECT_DIR;
try {
  const m = require(mod);
  if (typeof m.reopenReviewTestsAfterWriteCode !== "function") { process.stdout.write("NOT_IMPLEMENTED"); process.exit(0); }
  const res = m.reopenReviewTestsAfterWriteCode(sid, repo || null, gate);
  process.stdout.write(JSON.stringify({kind: res && res.kind, detail: res && res.detail}));
} catch (e) { process.stdout.write("ERROR:" + e.message); }
' "$REOPEN_MOD" "$1" "$2" "$3" "${4:-}" 2>/dev/null
}

# R1: module exports both entry points
R1_OUT="$(run_with_timeout node -e '
try {
  const m = require(process.argv[1]);
  process.stdout.write([typeof m.formatReviewTestsReopenNotice, typeof m.reopenReviewTestsAfterWriteCode].join(","));
} catch (e) { process.stdout.write("MODULE_MISSING:" + e.code); }
' "$REOPEN_MOD" 2>/dev/null)"
check "R1: formatReviewTestsReopenNotice and reopenReviewTestsAfterWriteCode exported" "function,function" "$R1_OUT"

# R2: notice text per kind — reopened names the reason, failed names the detail, else null
R2_OUT="$(run_with_timeout node -e '
try {
  const f = require(process.argv[1]).formatReviewTestsReopenNotice;
  const a = f({kind:"review-tests-reopened", detail:"write-code-stale"});
  const b = f({kind:"review-tests-reopen-failed", detail:"lock-timeout"});
  const c = f({});
  process.stdout.write(JSON.stringify({
    reopened: typeof a === "string" && a.includes("review_tests") && a.includes("write-code-stale"),
    failed: typeof b === "string" && b.includes("lock-timeout"),
    none: c === null
  }));
} catch (e) { process.stdout.write("ERROR:" + e.message); }
' "$REOPEN_MOD" 2>/dev/null)"
check "R2: notice names reason / failure detail; other kinds return null" '{"reopened":true,"failed":true,"none":true}' "$R2_OUT"

# Shared stale repo: tests/x.sh recorded, hooks/impl.js added after the review.
R_REPO="$TMPDIR_BASE/r-repo"
rr_repo "$R_REPO"
rr_stage "$R_REPO" tests/x.sh "echo x"
R_OID="$(rr_oid "$R_REPO" tests/x.sh)"
rr_stage "$R_REPO" hooks/impl.js "impl"
R_REPO_N="$(np "$R_REPO")"
R_RT_RECORDED="{\"status\":\"complete\",\"review_scope_manifest\":{\"v\":1,\"files\":{\"tests/x.sh\":\"$R_OID\"}}}"

# R3: repoDir absent and no session worktree recorded → write-code-unavailable
rr_state r3rere "$R_RT_RECORDED"
R3_OUT="$(rr_call r3rere "" advance "$(np "$TMPDIR_BASE")")"
check "R3a: unresolvable worktree → reopened as write-code-unavailable" '{"kind":"review-tests-reopened","detail":"write-code-unavailable"}' "$R3_OUT"
R3_VIEW="$(rr_view r3rere)"
check_contains "R3b: review_tests pending" '"rt_status":"pending"' "$R3_VIEW"
check_contains "R3c: write_code_scope_manifest records unavailable" '"wc_manifest":{"v":1,"unavailable":true}' "$R3_VIEW"

# R4: old token only, no review_scope_manifest → write-code-missing
rr_state r4rere '{"status":"complete","token":"oldtoken"}'
R4_OUT="$(rr_call r4rere "$R_REPO_N" advance)"
check "R4: old token only → reopened as write-code-missing" '{"kind":"review-tests-reopened","detail":"write-code-missing"}' "$R4_OUT"

# R5: repoDir absent → resolved from state.session_worktree, never process cwd.
# MAIN's index matches the record (fresh); LINKED adds hooks/new.js (stale).
R5_MAIN="$TMPDIR_BASE/r5-main"
R5_LINKED="$TMPDIR_BASE/r5-linked"
rr_repo "$R5_MAIN"
rr_linked "$R5_MAIN" "$R5_LINKED" feat2327r5
rr_stage "$R5_MAIN" tests/x.sh "echo x"
rr_stage "$R5_LINKED" tests/x.sh "echo x"
rr_stage "$R5_LINKED" hooks/new.js "impl"
R5_OID="$(rr_oid "$R5_MAIN" tests/x.sh)"
rr_state r5rere "{\"status\":\"complete\",\"review_scope_manifest\":{\"v\":1,\"files\":{\"tests/x.sh\":\"$R5_OID\"}}}" "" "$(np "$R5_LINKED")"
R5_OUT="$(rr_call r5rere "" mark "$(np "$R5_MAIN")")"
check "R5: repoDir absent → session worktree (stale), not cwd (fresh)" '{"kind":"review-tests-reopened","detail":"write-code-stale"}' "$R5_OUT"

# R6: gate outside sentinel/advance/mark → {} and state untouched
rr_state r6rere "$R_RT_RECORDED"
R6_OUT="$(rr_call r6rere "$R_REPO_N" reset)"
check "R6a: non-completion gate returns {}" '{}' "$R6_OUT"
check_contains "R6b: non-completion gate leaves review_tests complete" '"rt_status":"complete"' "$(rr_view r6rere)"

# R7: 0 staged tests → no-tests is fresh → no reopen
R7_REPO="$TMPDIR_BASE/r7-repo"
rr_repo "$R7_REPO"
rr_stage "$R7_REPO" hooks/impl.js "impl"
rr_state r7rere "$R_RT_RECORDED"
R7_OUT="$(rr_call r7rere "$(np "$R7_REPO")" advance)"
check "R7a: 0 staged tests → no reopen" '{}' "$R7_OUT"
check_contains "R7b: 0 staged tests → review_tests stays complete" '"rt_status":"complete","rt_reopen":null' "$(rr_view r7rere)"

# R8: reopen write fails → review-tests-reopen-failed carrying the error
rr_state r8rere "$R_RT_RECORDED"
R8_OUT="$(run_with_timeout node -e '
const [io, mod, sid, repo] = process.argv.slice(1);
try {
  require(io).recordWriteCodeCompletionScope = () => { throw new Error("simulated-write-failure"); };
  const res = require(mod).reopenReviewTestsAfterWriteCode(sid, repo, "advance");
  process.stdout.write(JSON.stringify({kind: res && res.kind, detail: res && res.detail}));
} catch (e) { process.stdout.write("THROWN:" + e.message); }
' "$AGENTS_DIR_N/hooks/workflow-state/state-io/review-tests.js" "$REOPEN_MOD" r8rere "$R_REPO_N" 2>/dev/null)"
check "R8: write failure → review-tests-reopen-failed diagnostic" '{"kind":"review-tests-reopen-failed","detail":"simulated-write-failure"}' "$R8_OUT"

echo ""
