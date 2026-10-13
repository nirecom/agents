#!/usr/bin/env bash
# Tests: hooks/workflow-state/step-table.js, hooks/workflow-state/session-profile.js, hooks/lib/delivery-path.js, hooks/workflow-state/state-io/core.js
# Tags: scope:issue-specific, workflow-state, step-table, session-profile, delivery-path, issue-2527
# TL2: requires the modules in-process; the live delivery path is pinned per case through env + marker files.
# TL3 gap: a real Claude Code session writing the markers and env from hooks
# is not exercised; only the resolver's reading of them is.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

s27_setup
trap s27_teardown EXIT

TABLE=hooks/workflow-state/step-table.js
PROFILE=hooks/workflow-state/session-profile.js
DPATH=hooks/lib/delivery-path.js
ALL19="workflow_init,clarify_intent,research,outline,detail,branching_complete,write_tests,review_tests,write_code,run_tests,review_security,docs,review_docs,push_branch,user_verification,merge_to_main,cleanup,pre_final_report_gate,final_report"

# required_list <profile-json> — comma list of steps isStepRequired accepts.
required_list() {
  s27_node "const t = req(\"$TABLE\"); const p = $1;
out(\"REQ\", t.stepNames().filter((s) => t.isStepRequired(p, s) === true).join(\",\"));"
}

# profile_of <sid> <state-json> — PROFILE=<json> line (stderr kept in output).
profile_of() {
  s27_node "const m = req(\"$PROFILE\"); const r = m.resolveSessionProfile($2, \"$1\", { repoDir: \"$S27_REPO_M\" });
out(\"PROFILE\", { d: r.deliverableType, pm: r.pmType, path: r.deliveryPath, src: r.sources });"
}

case_begin "T1-valid-steps-derived-from-table" "hooks/workflow-state/step-table.js"
o="$(s27_node "const t = req(\"$TABLE\"); const c = req(\"hooks/workflow-state/state-io/core.js\");
out(\"NAMES\", t.stepNames().join(\",\")); out(\"VALID\", c.VALID_STEPS.join(\",\"));")"
check "T1a stepNames() is the 19-row order" "$(field "$o" NAMES)" "$ALL19"
check "T1b VALID_STEPS equals stepNames()" "$(field "$o" VALID)" "$ALL19"
case_end

case_begin "T2-required-wf-code-pull-request" "hooks/workflow-state/step-table.js"
o="$(required_list '{ deliverableType: "wf-code", pmType: "waterfall", deliveryPath: "pull_request" }')"
check "T2 wf-code x pull_request requires every step" "$(field "$o" REQ)" "$ALL19"
case_end

case_begin "T3-required-wf-code-direct" "hooks/workflow-state/step-table.js"
o="$(required_list '{ deliverableType: "wf-code", pmType: "waterfall", deliveryPath: "direct" }')"
check "T3 wf-code x direct skips push_branch and cleanup" "$(field "$o" REQ)" \
  "workflow_init,clarify_intent,research,outline,detail,branching_complete,write_tests,review_tests,write_code,run_tests,review_security,docs,review_docs,user_verification,merge_to_main,pre_final_report_gate,final_report"
case_end

case_begin "T4-required-wf-meta" "hooks/workflow-state/step-table.js"
WFMETA="workflow_init,clarify_intent,research,outline,pre_final_report_gate,final_report"
o="$(required_list '{ deliverableType: "wf-meta", pmType: "waterfall", deliveryPath: "pull_request" }')"
check "T4a wf-meta x pull_request keeps the 6 planning/close steps" "$(field "$o" REQ)" "$WFMETA"
o="$(required_list '{ deliverableType: "wf-meta", pmType: "waterfall", deliveryPath: "direct" }')"
check "T4b wf-meta x direct is the same 6 steps" "$(field "$o" REQ)" "$WFMETA"
case_end

case_begin "T5-commit-gate-attribute" "hooks/workflow-state/step-table.js"
o="$(s27_node "const t = req(\"$TABLE\");
out(\"GATES\", t.stepNames().map((s) => s + \":\" + t.commitGateOf(s)).join(\",\"));")"
check "T5 commitGateOf for all 19 rows" "$(field "$o" GATES)" \
  "workflow_init:required,clarify_intent:required,research:exempt,outline:required,detail:required,branching_complete:required,write_tests:required,review_tests:required,write_code:required,run_tests:required,review_security:required,docs:required,review_docs:required,push_branch:exempt,user_verification:deferred-in-worktree,merge_to_main:exempt,cleanup:deferred-in-worktree,pre_final_report_gate:exempt,final_report:exempt"
case_end

case_begin "T6-provisional-without-record" "hooks/workflow-state/session-profile.js"
o="$(profile_of s27-t6 '{ events: [] }')"
check "T6 no record -> wf-code/waterfall/pull_request, all provisional" "$(field "$o" PROFILE)" \
  '{"d":"wf-code","pm":"waterfall","path":"pull_request","src":{"deliverableType":"provisional","pmType":"provisional","deliveryPath":"provisional","autoMergePr":"provisional"}}'
case_end

case_begin "T7-workflow-off-marker-forces-pm-off" "hooks/workflow-state/session-profile.js"
: > "$WORKFLOW_STATE_DIR/s27-t7.workflow-off"
o="$(profile_of s27-t7 '{ events: [] }')"
check "T7 WORKFLOW_OFF -> pmType off (marker), live path direct" "$(field "$o" PROFILE)" \
  '{"d":"wf-code","pm":"off","path":"direct","src":{"deliverableType":"provisional","pmType":"marker","deliveryPath":"provisional","autoMergePr":"provisional"}}'
o="$(profile_of s27-t7 '{ project_management_type: "waterfall", events: [] }')"
check "T7b recorded waterfall is overridden by the marker" \
  "$(field "$o" PROFILE | sed -n 's/.*"pm":"\([a-z]*\)".*"pmType":"\([a-z]*\)".*/\1|\2/p')" "off|marker"
case_end

case_begin "T8-worktree-off-marker-direct" "hooks/workflow-state/session-profile.js"
: > "$WORKFLOW_STATE_DIR/s27-t8.worktree-off"
o="$(profile_of s27-t8 '{ events: [] }')"
check "T8 WORKTREE_OFF -> direct, pm stays waterfall" "$(field "$o" PROFILE)" \
  '{"d":"wf-code","pm":"waterfall","path":"direct","src":{"deliverableType":"provisional","pmType":"provisional","deliveryPath":"provisional","autoMergePr":"provisional"}}'
case_end

case_begin "T9-enforce-worktree-env" "hooks/workflow-state/session-profile.js"
o="$(ENFORCE_WORKTREE=off profile_of s27-t9 '{ events: [] }')"
check_contains "T9a ENFORCE_WORKTREE=off -> direct" "$(field "$o" PROFILE)" '"path":"direct"'
o="$(ENFORCE_WORKTREE=maybe profile_of s27-t9 '{ events: [] }')"
check_contains "T9b unknown ENFORCE_WORKTREE value fails safe to pull_request" "$(field "$o" PROFILE)" '"path":"pull_request"'
case_end

case_begin "T10-repo-excluded" "hooks/workflow-state/session-profile.js"
o="$(ENFORCE_WORKTREE_EXCLUDE="$S27_REPO_M" profile_of s27-t10 '{ events: [] }')"
check_contains "T10a repo in ENFORCE_WORKTREE_EXCLUDE -> direct" "$(field "$o" PROFILE)" '"path":"direct"'
o="$(ENFORCE_WORKTREE_EXCLUDE="$(np "$S27_TMP/elsewhere")" profile_of s27-t10 '{ events: [] }')"
check_contains "T10b another repo excluded -> pull_request" "$(field "$o" PROFILE)" '"path":"pull_request"'
case_end

case_begin "T11-recorded-path-beats-live" "hooks/workflow-state/session-profile.js"
o="$(ENFORCE_WORKTREE=off profile_of s27-t11 '{ delivery_path: "pull_request", events: [] }')"
check_contains "T11a recorded pull_request survives live off" "$(field "$o" PROFILE)" '"path":"pull_request"'
check_contains "T11b source is recorded" "$(field "$o" PROFILE)" '"deliveryPath":"recorded"'
o="$(profile_of s27-t11 '{ delivery_path: "direct", events: [] }')"
check_contains "T11c recorded direct survives live on" "$(field "$o" PROFILE)" '"path":"direct"'
case_end

case_begin "T12-recorded-deliverable-type" "hooks/workflow-state/session-profile.js"
o="$(profile_of s27-t12 '{ deliverable_type: "wf-meta", events: [] }')"
check_contains "T12a recorded wf-meta is used" "$(field "$o" PROFILE)" '"d":"wf-meta"'
check_contains "T12b source is recorded" "$(field "$o" PROFILE)" '"deliverableType":"recorded"'
case_end

case_begin "T13-unsupported-pm-type-falls-back" "hooks/workflow-state/session-profile.js"
for v in agile kanban-x; do
  o="$(profile_of s27-t13 "{ project_management_type: \"$v\", events: [] }")"
  check_contains "T13 $v -> waterfall" "$(field "$o" PROFILE)" '"pm":"waterfall"'
  check_contains "T13 $v -> stderr warning names the value" "$o" "$v"
done
case_end

case_begin "T14-live-delivery-path-direct" "hooks/lib/delivery-path.js"
live() { s27_node "const m = req(\"$DPATH\"); out(\"LIVE\", m.resolveLiveDeliveryPath(\"$1\", \"$S27_REPO_M\"));"; }
check "T14a default -> pull_request" "$(field "$(live s27-t14)" LIVE)" "pull_request"
check "T14b ENFORCE_WORKTREE=off -> direct" "$(field "$(ENFORCE_WORKTREE=off live s27-t14)" LIVE)" "direct"
: > "$WORKFLOW_STATE_DIR/s27-t14w.worktree-off"
check "T14c WORKTREE_OFF -> direct" "$(field "$(live s27-t14w)" LIVE)" "direct"
: > "$WORKFLOW_STATE_DIR/s27-t14f.workflow-off"
check "T14d WORKFLOW_OFF -> direct" "$(field "$(live s27-t14f)" LIVE)" "direct"
# Security: a traversal-shaped sid never matches a marker outside the state dir.
: > "$S27_TMP/escape.worktree-off"
check "T14e traversal sid ignores out-of-dir marker" "$(field "$(live ../escape)" LIVE)" "pull_request"
case_end

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
