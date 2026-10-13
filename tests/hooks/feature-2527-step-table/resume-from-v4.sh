#!/usr/bin/env bash
# Tests: bin/workflow/next-step, hooks/workflow-state/state-io/migrations/v4-to-v5.js, bin/workflow/lib/next-step/delivery-path-note.js
# Tags: scope:issue-specific, next-step, migration, release-phase, resume, issue-2527
# TL2: spawns the next-step CLI over v4 fixture files with a fake gh (PATH) and a network-free fixture repo.
# TL3 gap: a real GitHub PR and a real interrupted Claude Code session are not
# exercised; gh answers come from fake-gh.js, origin refs are written locally.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
source "$__LIB_SCRIPT_CHECKOUT_ROOT/tests/lib/cli-stub.sh"

s27_setup
trap s27_teardown EXIT
export WORKFLOW_STATE_DIR="$WORKFLOW_STATE_DIR" WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR"

BR="feature/2527-fixture"
PRE="workflow_init=complete;clarify_intent=complete;research=complete;outline=complete;detail=complete"
POST_BC="write_tests=complete;review_tests=complete;write_code=complete;run_tests=complete;review_security=complete"
THRU_RD="$PRE;branching_complete=complete;$POST_BC;docs=complete;review_docs=complete"

# Fixture repo: one commit on $BR, a github origin URL, and locally written
# origin refs + upstream config so no command ever needs the network.
git -C "$S27_REPO" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$S27_REPO" checkout -q -b "$BR"
git -C "$S27_REPO" remote add origin https://github.com/acme/widgets.git
git -C "$S27_REPO" update-ref refs/remotes/origin/main HEAD
git -C "$S27_REPO" update-ref "refs/remotes/origin/$BR" HEAD
git -C "$S27_REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$S27_REPO" config "branch.$BR.remote" origin
git -C "$S27_REPO" config "branch.$BR.merge" "refs/heads/$BR"
HEAD_SHA="$(git -C "$S27_REPO" rev-parse HEAD)"

# Fake gh first on PATH; fake-gh.js answers only inside the gh-named binary.
cli_stub_make "$S27_TMP/fakebin" gh
export PATH="$CLI_STUB_DIR:$PATH"
export NODE_OPTIONS="--require \"$(np "$_s27_here/fake-gh.js")\""
export FAKE_GH_LOG="$(np "$S27_TMP/gh.log")"
export FAKE_GH_STATE=NONE

# fx <sid> <steps> [extra spec json fragment] — v4 fixture rooted at the repo. #2277: the
# complete plan steps carry an approval record, or next-step reads them as pending.
fx() {
  mk_state "{\"sid\":\"$1\",\"steps\":\"$2\",\"cwd\":\"$S27_REPO_M\",\"branch\":\"$BR\"${3:+,$3}}"
  node "$S27_SCRIPT_CHECKOUT_ROOT/tests/lib/plan-approval-fixture.js" inject-complete \
    "$WORKFLOW_STATE_DIR/$1.json" clarify_intent outline detail >/dev/null 2>&1 \
    || fail "fixture" "plan-approval-fixture.js inject-complete $1 failed"
}

# after <sid> — facts read back through readState after next-step ran.
read -r -d '' AFTER_JS <<'JS' || true
const c = req("hooks/workflow-state/state-io/core.js"); const s = c.readState(process.env.S27_SID);
if (!s) { out("RS", "null"); process.exit(0); }
const st = (k) => (s.current.steps[k] ? s.current.steps[k].status : "<none>");
out("DP", s.delivery_path || "<absent>"); out("DT", s.deliverable_type || "<absent>");
out("PB", st("push_branch")); out("DL", st("merge_to_main"));
JS
after() {
  S27_SID="$1" s27_node "$AFTER_JS"
}

case_begin "R-a-before-docs-pull-request" "bin/workflow/next-step"
fx ra "$PRE;branching_complete=complete;$POST_BC;docs=pending" '"entered":true'
o="$(run_next_step ra)"
check_skill "R-a NEXT_SKILL=update-docs" "$o" "update-docs"
check_not_contains "R-a no DELIVERY_PATH_MISMATCH when live agrees" "$o" "DELIVERY_PATH_MISMATCH="
a="$(after ra)"
check "R-a delivery_path=pull_request recorded" "$(field "$a" DP)" "pull_request"
check "R-a push_branch pending" "$(field "$a" PB)" "pending"
check "R-a merge_to_main pending" "$(field "$a" DL)" "pending"
case_end

case_begin "R-a2-recorded-path-vs-live-off" "bin/workflow/lib/next-step/delivery-path-note.js"
fx ra2 "$PRE;branching_complete=complete;$POST_BC;docs=pending" '"entered":true'
o="$(ENFORCE_WORKTREE=off run_next_step ra2)"
check_skill "R-a' NEXT_SKILL still update-docs (recorded path)" "$o" "update-docs"
check "R-a' DELIVERY_PATH_MISMATCH line" "$(field "$o" DELIVERY_PATH_MISMATCH)" \
  "recorded:pull_request live:direct hooks-enforce:live recover:WORKFLOW_RESET_FROM_branching_complete"
case_end

case_begin "R-b-pr-open-evidence" "bin/workflow/next-step"
fx rb "$THRU_RD;user_verification=pending" '"entered":true'
o="$(FAKE_GH_STATE=OPEN run_next_step rb)"
check_skill "R-b PR OPEN -> NEXT_SKILL=get-release-approval" "$o" "get-release-approval"
check "R-b push_branch settled by evidence" "$(field "$(after rb)" PB)" "complete"
fx rb2 "$THRU_RD;user_verification=pending" '"entered":true'
o="$(FAKE_GH_STATE=FAIL run_next_step rb2)"
check_skill "R-b gh failure -> NEXT_SKILL=commit-push" "$o" "commit-push"
check "R-b gh failure leaves push_branch pending" "$(field "$(after rb2)" PB)" "pending"
case_end

case_begin "R-c-off-approved-not-delivered" "bin/workflow/next-step"
fx rc "$THRU_RD;user_verification=complete;cleanup=pending"
: > "$S27_REPO/dirty.txt"
o="$(ENFORCE_WORKTREE=off run_next_step rc)"
rm -f "$S27_REPO/dirty.txt"
check_skill "R-c NEXT_SKILL=merge-to-main" "$o" "merge-to-main"
a="$(after rc)"
check "R-c delivery_path=direct recorded" "$(field "$a" DP)" "direct"
check "R-c push_branch backfilled" "$(field "$a" PB)" "complete"
case_end

case_begin "R-c2-off-after-bash-push" "bin/workflow/next-step"
fx rc2 "$THRU_RD;user_verification=complete;user_verification=pending" "\"lastPushed\":\"$HEAD_SHA\""
o="$(ENFORCE_WORKTREE=off run_next_step rc2)"
check_skill "R-c' NEXT_SKILL=session-close" "$o" "session-close"
check "R-c' merge_to_main backfilled" "$(field "$(after rc2)" DL)" "complete"
case_end

case_begin "R-d-after-cleanup" "bin/workflow/next-step"
fx rd "$THRU_RD;user_verification=complete;cleanup=complete" '"entered":true'
o="$(run_next_step rd)"
check_skill "R-d NEXT_SKILL=session-close" "$o" "session-close"
case_end

case_begin "R-e-wf-meta" "bin/workflow/next-step"
fx re "workflow_init=complete;clarify_intent=complete;research=complete;outline=complete" '"type":"wf-meta"'
o="$(run_next_step re)"
check_skill "R-e NEXT_SKILL=session-close" "$o" "session-close"
a="$(after re)"
check "R-e deliverable_type=wf-meta" "$(field "$a" DT)" "wf-meta"
check "R-e no delivery_path" "$(field "$a" DP)" "<absent>"
case_end

case_begin "R-f-merged-by-old-we8" "bin/workflow/next-step"
fx rf "$THRU_RD;user_verification=complete;user_verification=pending" '"entered":true,"uvReset":"post-merge"'
o="$(run_next_step rf)"
check_skill "R-f NEXT_SKILL=worktree-end" "$o" "worktree-end"
a="$(after rf)"
check "R-f push_branch backfilled" "$(field "$a" PB)" "complete"
check "R-f merge_to_main backfilled" "$(field "$a" DL)" "complete"
case_end

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
