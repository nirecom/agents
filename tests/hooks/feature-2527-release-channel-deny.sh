#!/usr/bin/env bash
# feature-2527-release-channel-deny.sh — #2527 4-3: AUTO_MERGE_PR=off + pull_request refuses Claude's own merge.
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/release-channel-judge.js, hooks/workflow-gate/release-pr-url.js
# Tags: scope:issue-specific, workflow, merge-gate, auto-merge-pr, release-channel, TL2
# TL2: workflow-gate.js spawned with Bash payloads over v5 fixture states (user_verification
# complete unless stated), a fake gh first on PATH, and the session markers / supervisor state
# the refusal must ignore (plan 4-3, judgment I-1 / J-1):
#   refuse = merge-to-protected hit AND AUTO_MERGE_PR off (pinned value first; a fallback pin is
#   on; no pin -> live read; unreadable -> on + notice) AND delivery path pull_request (recorded
#   value first; no record -> ENFORCE_WORKTREE). Markers, TR5 and user_verification never matter.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../tests/lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/feature-2527-auto-merge-pr-fix/_lib.sh"

# TL3 gap (not caught here): Claude Code really routing the merge Bash call through the
# registered PreToolUse hook, and the human merging on the forge. Closest-to-action
# mitigation: forge branch protection. category: hook-registration.
AMP_TMP="$(make_tmp)"
readonly AMP_TMP
trap amp_teardown EXIT
harness_isolate "$AMP_TMP"
amp_setup

UVC="user_verification=complete"
GH_MERGE="gh pr merge 42 --squash --delete-branch"
GQL_GH="gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"PR_1\"}){clientMutationId}}'"
GLAB_MERGE="glab mr merge 1 --yes"
REST_PUT="gh api -X PUT repos/o/r/pulls/1/merge"
PUSH_MAIN="git push origin main"

# st <sid> <extra-spec-fields> [steps] — a fixture state up to user_verification.
st() { mk_state "{\"sid\":\"$1\",\"upto\":\"user_verification\",\"steps\":\"${3:-$UVC}\"${2:+,$2}}"; }

# expect_refused <label> <sid> <command> [gate-fn] — block naming AUTO_MERGE_PR=off.
expect_refused() {
  local o
  o="$("${4:-gate_bash}" "$2" "$AMP_REPO_M" "$3")"
  check "$1: decision is block" "$(hook_decision "$o")" "block"
  check_contains "$1: reason names AUTO_MERGE_PR=off" "$(hook_json_key "$o" reason)" "AUTO_MERGE_PR=off"
}
# expect_approved <label> <sid> <command> [gate-fn] — approve with no refusal text.
expect_approved() {
  local o
  o="$("${4:-gate_bash}" "$2" "$AMP_REPO_M" "$3")"
  check "$1: decision is approve" "$(hook_decision "$o")" "approve"
  check_not_contains "$1: no refusal text" "$o" "AUTO_MERGE_PR=off"
}
marker() { : > "$WORKFLOW_STATE_DIR/$1.$2"; }

case_begin "refused: off pinned + pull_request, every merge-to-protected form" "hooks/workflow-gate/release-channel-judge.js"
amp_env
st rd-pr '"path":"pull_request","amp":"off"'
expect_refused "gh pr merge" rd-pr "$GH_MERGE"
expect_refused "GraphQL mergePullRequest" rd-pr "$GQL_GH"
expect_refused "glab mr merge" rd-pr "$GLAB_MERGE"
expect_refused "REST PUT pulls/1/merge" rd-pr "$REST_PUT"
expect_refused "git push origin main" rd-pr "$PUSH_MAIN"
case_end

case_begin "refused: the pinned off value wins over a later .env on" "hooks/workflow-gate/release-channel-judge.js"
amp_env "AUTO_MERGE_PR=on"
st rd-pin '"path":"pull_request","amp":"off"'
expect_refused "pinned off + .env on" rd-pin "$GH_MERGE"
amp_env
case_end

case_begin "refused: the workflow-off and worktree-off markers do not lift the refusal" "hooks/workflow-gate.js"
# Sanity: the workflow-off marker is honoured by today's gate (uv pending + on -> approve).
st rd-wfsan '"path":"pull_request","amp":"on"' "user_verification=pending"
marker rd-wfsan workflow-off
check "sanity: workflow-off marker bypasses the uv merge gate" "$(hook_decision "$(gate_bash rd-wfsan "$AMP_REPO_M" "$GH_MERGE")")" "approve"
st rd-wfoff '"path":"pull_request","amp":"off"'
marker rd-wfoff workflow-off
expect_refused "workflow-off marker" rd-wfoff "$GH_MERGE"
st rd-wtoff '"path":"pull_request","amp":"off"'
marker rd-wtoff worktree-off
expect_refused "worktree-off marker" rd-wtoff "$GH_MERGE"
expect_refused "worktree-off marker push" rd-wtoff "$PUSH_MAIN"
case_end

case_begin "refused: a fresh TR5 CONTINUE does not lift the refusal" "hooks/workflow-gate.js"
read -r -d '' TR5_SEED_JS <<'JS' || true
const fp = req("hooks/lib/diff-fingerprint.js");
const writer = req("hooks/lib/supervisor-state-writer.js");
const schema = req("hooks/lib/supervisor-state-schema.js");
const sid = process.argv[1];
const r = fp.computeFreshnessKey(process.argv[2], process.env.WORKFLOW_PLANS_DIR, sid);
const fk = String((r && r.freshness_key) || "null");
const st = schema.createEmptyState(sid);
st.audit.ledger = [{ id: "run-0011", outcome: "terminal", cause: "step-complete:user_verification",
  tr_ids: ["TR5"], verdict: "CONTINUE", freshness_key: fk, sub_checks: ["recurrence-patterns"],
  input_key: { "recurrence-patterns": fk } }];
st.audit.last_terminal_run_id = "run-0011";
st.audit.audit_verdict_summary = "CONTINUE";
require("fs").writeFileSync(writer.getStatePath(sid, { forWrite: true }), JSON.stringify(st));
out("FK", fk);
JS
tr5_seed() {
  mkdir -p "$WORKFLOW_PLANS_DIR"
  printf '# intent\ni1\n' > "$WORKFLOW_PLANS_DIR/$1-intent.md"
  printf '# outline\no1\n' > "$WORKFLOW_PLANS_DIR/$1-outline.md"
  printf '# detail\nd1\n\n## Files to modify\n\n- README.md\n' > "$WORKFLOW_PLANS_DIR/$1-detail.md"
  amp_node "$TR5_SEED_JS" "$1" "$AMP_REPO_M"
}
# Sanity: with on pinned and uv pending, the fresh TR5 run alone approves the merge.
st rd-tr5san '"path":"pull_request","amp":"on"' "user_verification=pending"
check_not_contains "sanity: TR5 seed has a freshness key" "$(tr5_seed rd-tr5san)" "FK=null"
check "sanity: fresh TR5 CONTINUE approves (on)" "$(hook_decision "$(gate_bash rd-tr5san "$AMP_REPO_M" "$GH_MERGE")")" "approve"
st rd-tr5 '"path":"pull_request","amp":"off"' "user_verification=pending"
check_not_contains "TR5 seed has a freshness key" "$(tr5_seed rd-tr5)" "FK=null"
expect_refused "fresh TR5 CONTINUE" rd-tr5 "$GH_MERGE"
case_end

case_begin "refused: no recorded path + ENFORCE_WORKTREE=on + .env off" "hooks/workflow-gate/release-channel-judge.js"
amp_env "AUTO_MERGE_PR=off"
st rd-norec ''
expect_refused "no record gh pr merge" rd-norec "$GH_MERGE"
expect_refused "no record git push origin main" rd-norec "$PUSH_MAIN"
st rd-norec-wt ''
marker rd-norec-wt worktree-off
expect_refused "no record + worktree-off gh pr merge" rd-norec-wt "$GH_MERGE"
expect_refused "no record + worktree-off push" rd-norec-wt "$PUSH_MAIN"
amp_env
case_end

case_begin "refusal text: AUTO_MERGE_PR=off, the PR URL (or gh pr view --web), no merge" "hooks/workflow-gate/release-pr-url.js"
st rd-text '"path":"pull_request","amp":"off"'
: > "$AMP_GH_LOG"
o="$(gate_bash rd-text "$AMP_REPO_M" "$GH_MERGE")"
reason="$(hook_json_key "$o" reason)"
check_contains "text names AUTO_MERGE_PR=off" "$reason" "AUTO_MERGE_PR=off"
case "$reason" in
  *"$AMP_PR_URL"*|*"gh pr view --web"*) pass "text carries the PR URL or gh pr view --web" ;;
  *) fail "text carries the PR URL or gh pr view --web" "got: $(printf '%s' "$reason" | head -c 300)" ;;
esac
check_contains "text says the human merges on the web" "$reason" "on the web"
check_contains "text says do not merge" "$reason" "do not merge"
case_end

# I-2 (rejected): refuse on AUTO_MERGE_PR=off alone, whatever the delivery path. Under I-2
# exactly two rows below flip to a refusal: off + direct `gh pr merge`, and no record +
# ENFORCE_WORKTREE=off + .env off `gh pr merge`.
case_begin "not refused: off + direct (merge and push)" "hooks/workflow-gate/release-channel-judge.js"
st nr-direct '"path":"direct","amp":"off"'
: > "$AMP_GH_LOG"
expect_approved "off + direct gh pr merge (flips under I-2)" nr-direct "$GH_MERGE"
expect_approved "off + direct git push origin main" nr-direct "$PUSH_MAIN"
check_not_contains "no URL lookup when not refused" "$(cat "$AMP_GH_LOG")" "pr view"
case_end

case_begin "not refused: no recorded path + ENFORCE_WORKTREE=off + .env off" "hooks/workflow-gate/release-channel-judge.js"
amp_env "AUTO_MERGE_PR=off"
st nr-norec-off ''
o="$(ENFORCE_WORKTREE=off gate_bash nr-norec-off "$AMP_REPO_M" "$GH_MERGE")"
check "no record + EW off gh pr merge (flips under I-2): approve" "$(hook_decision "$o")" "approve"
check_not_contains "no record + EW off: no refusal text" "$o" "AUTO_MERGE_PR=off"
amp_env
case_end

case_begin "not refused: on, pinned and live" "hooks/workflow-gate/release-channel-judge.js"
amp_env "AUTO_MERGE_PR=off"
st nr-on-pin '"path":"pull_request","amp":"on"'
expect_approved "on pinned + .env off" nr-on-pin "$GH_MERGE"
amp_env "AUTO_MERGE_PR=on"
st nr-on-env '"path":"pull_request"'
expect_approved "no pin + .env on" nr-on-env "$GH_MERGE"
expect_approved "no pin + .env on push" nr-on-env "$PUSH_MAIN"
amp_env
case_end

case_begin "not refused: a fallback-on pin stays on with .env off" "hooks/workflow-gate/release-channel-judge.js"
amp_env "AUTO_MERGE_PR=off"
st nr-fb '"path":"pull_request","amp":"on","ampSource":"fallback"'
expect_approved "fallback on pinned + .env off" nr-fb "$GH_MERGE"
amp_env
case_end

case_begin "not refused: unreadable AUTO_MERGE_PR is on, with a notice" "hooks/workflow-gate.js"
amp_env "AUTO_MERGE_PR=off"
st nr-unread '"path":"pull_request"'
o="$(gate_bash_unreadable nr-unread "$AMP_REPO_M" "$GH_MERGE")"
check "unreadable: decision is approve" "$(hook_decision "$o")" "approve"
check_contains "unreadable: output carries a systemMessage" "$o" '"systemMessage"'
check_contains "unreadable: the notice names AUTO_MERGE_PR" "$(hook_json_key "$o" systemMessage)" "AUTO_MERGE_PR"
amp_env
case_end

case_begin "not refused: a non-merge command under off + pull_request" "hooks/workflow-gate.js"
st nr-status '"path":"pull_request","amp":"off"'
expect_approved "git status" nr-status "git status"
case_end

# Plan 4-3a: the /merge|push|graphql|mergeRequestAccept/i prefilter only decides whether the
# judge runs; a prefilter hit that isMergeToProtectedCommand does not flag is never refused, and
# the PR URL is looked up only on a refusal.
case_begin "not refused: prefilter-hitting non-merge commands under off + pull_request" "hooks/workflow-gate/release-channel-judge.js"
st nr-prefilter '"path":"pull_request","amp":"off"'
: > "$AMP_GH_LOG"
expect_approved "git push -u origin feature branch" nr-prefilter "git push -u origin feature/2527-amp"
expect_approved "gh pr view --json mergeStateStatus" nr-prefilter "gh pr view 42 --json mergeStateStatus"
expect_approved "wait-web-merge.sh poller launch" nr-prefilter "bash $AMP_ROOT_M/skills/get-release-approval/scripts/wait-web-merge.sh --session x --repo y"
expect_approved "GraphQL read query naming mergeable" nr-prefilter "gh api graphql -f query='query{repository(owner:\"o\",name:\"r\"){pullRequest(number:42){mergeable mergeStateStatus}}}'"
check_not_contains "no PR URL lookup (gh pr view) for a non-refused prefilter hit" "$(cat "$AMP_GH_LOG")" "pr view"
case_end

# Plan 4-3b: the judge has no bootstrap exception — push_branch.decision=bootstrap changes the
# release channel (4-2) but not the refusal of git-push-protected under off + pull_request.
case_begin "refused: push_branch.decision=bootstrap does not lift the push refusal" "hooks/workflow-gate/release-channel-judge.js"
st rd-bootstrap '"path":"pull_request","amp":"off","annotate":"push_branch.decision=bootstrap"'
expect_refused "bootstrap + git push origin main" rd-bootstrap "$PUSH_MAIN"
case_end

# Plan 4-3a: a judge exception never blocks — the gate goes on (uv complete -> approve) and
# attaches a notice as systemMessage. Two injection points: judgeRelease itself, and the
# resolveRepoDir the judge path calls after a prefilter hit.
cat > "$AMP_TMP/throw-judge.js" <<'JS'
"use strict";
try {
  const m = require(process.env.AMP_ROOT_M + "/hooks/workflow-gate/release-channel-judge.js");
  m.judgeRelease = function () { throw new Error("injected judgeRelease failure"); };
} catch (_) { /* judge module not present yet: nothing to inject */ }
JS
cat > "$AMP_TMP/throw-repodir.js" <<'JS'
"use strict";
const m = require(process.env.AMP_ROOT_M + "/hooks/workflow-gate/repo-resolution.js");
m.resolveRepoDir = function () { throw new Error("injected resolveRepoDir failure"); };
JS
gate_bash_throw_judge() { hook_json "$@" | NODE_OPTIONS="--require \"$(np "$AMP_TMP/throw-judge.js")\"" run_with_timeout 60 node "$GATE_JS" 2>&1; }
gate_bash_throw_repodir() { hook_json "$@" | NODE_OPTIONS="--require \"$(np "$AMP_TMP/throw-repodir.js")\"" run_with_timeout 60 node "$GATE_JS" 2>&1; }

case_begin "judge exception: approve with a notice, never a block" "hooks/workflow-gate.js"
for inj in judge repodir; do
  st "nr-throw-$inj" '"path":"pull_request","amp":"off"'
  o="$("gate_bash_throw_$inj" "nr-throw-$inj" "$AMP_REPO_M" "$GH_MERGE")"
  check "$inj throws: decision is approve" "$(hook_decision "$o")" "approve"
  check_contains "$inj throws: output carries a systemMessage notice" "$o" '"systemMessage"'
done
case_end

case_begin "static: the refusal precedes the workflow-off approve; judge is marker/TR5/uv free" "hooks/workflow-gate.js"
read -r -d '' ORDER_JS <<'JS' || true
const src = require("fs").readFileSync(A + "/hooks/workflow-gate.js", "utf8");
const j = src.indexOf("judgeRelease");
const w = src.indexOf("isWorkflowOff(");
out("ORDER", j < 0 ? "no-judgeRelease" : (w < 0 ? "no-isWorkflowOff" : (j < w ? "before" : "after")));
JS
check "judgeRelease appears before isWorkflowOff(" "$(field "$(amp_node "$ORDER_JS")" ORDER)" "before"
JUDGE="$AMP_ROOT_M/hooks/workflow-gate/release-channel-judge.js"
if [ -f "$JUDGE" ]; then
  pass "release-channel-judge.js exists"
  judge_src="$(cat "$JUDGE")"
  check_not_contains "judge does not require session-markers" "$judge_src" "session-markers"
  check_not_contains "judge does not require supervisor-check" "$judge_src" "supervisor-check"
  check_not_contains "judge does not require user-verified-audit" "$judge_src" "user-verified-audit"
else
  fail "release-channel-judge.js exists" "missing: $JUDGE"
  fail "judge does not require session-markers" "judge module missing"
  fail "judge does not require supervisor-check" "judge module missing"
  fail "judge does not require user-verified-audit" "judge module missing"
fi
check "release-pr-url.js exists" "$([ -f "$AMP_ROOT_M/hooks/workflow-gate/release-pr-url.js" ] && echo yes || echo no)" "yes"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
