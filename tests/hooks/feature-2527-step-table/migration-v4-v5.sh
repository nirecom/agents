#!/usr/bin/env bash
# Tests: hooks/workflow-state/state-io/migrations/v4-to-v5.js, hooks/workflow-state/state-io/migrations.js, hooks/workflow-state/state-io/core.js
# Tags: scope:issue-specific, workflow-state, migration, schema-v5, issue-2527
# TL2: drives migrateV4ToV5 / normalizeStateVersion / readState in-process over fixture files.
# TL3 gap: a live session migrating mid-flight (old hooks still running) is not
# exercised; only the pure transform and the read/persist entry points are.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

s27_setup
trap s27_teardown EXIT

MIG=hooks/workflow-state/state-io/migrations.js
CORE=hooks/workflow-state/state-io/core.js
PRE="workflow_init=complete;clarify_intent=complete;research=complete;outline=complete;detail=complete"
POST_BC="write_tests=complete;review_tests=complete;write_code=complete;run_tests=complete;review_security=complete;docs=complete;review_docs=complete"
THRU_RD="$PRE;branching_complete=complete;$POST_BC"

# mig <sid> — migrate the raw fixture file and print one key=value per fact.
read -r -d '' MIG_JS <<'JS' || true
const m = req(process.env.S27_MIG); const fs = require("fs");
if (typeof m.migrateV4ToV5 !== "function") { console.log("MISSING:migrateV4ToV5"); process.exit(0); }
const { projectState, assertStreamIntegrity } = req("hooks/workflow-state/state-io/projection.js");
const raw = JSON.parse(fs.readFileSync(process.env.WORKFLOW_STATE_DIR + "/" + process.env.S27_SID + ".json", "utf8"));
const before = JSON.stringify(raw);
const s = m.migrateV4ToV5(raw);
const steps = projectState(s).steps || {};
const st = (k) => (steps[k] ? steps[k].status : "<none>");
const has = (k) => Object.prototype.hasOwnProperty.call(s, k);
out("VER", String(s.version));
out("DT", has("deliverable_type") ? s.deliverable_type : "<absent>");
out("WT", has("workflow_type") ? "present" : "<absent>");
out("PMT", has("project_management_type") ? "present" : "<absent>");
out("DP", has("delivery_path") ? s.delivery_path : "<absent>");
out("DPO", has("delivery_path_origin") ? s.delivery_path_origin : "<absent>");
out("PB", st("push_branch")); out("DL", st("merge_to_main")); out("UV", st("user_verification"));
out("UVR", (steps.user_verification && steps.user_verification.reset_reason) || "<none>");
out("BF", s.events.filter((e) => e.provenance === "backfilled").map((e) => [e.kind, e.step, e.status || e.value, e.origin, e.at_estimated === true].join(":")).join(","));
out("SEQ", s.events.every((e, i) => e.seq === i + 1) ? "contiguous" : "broken");
let integ = "ok"; try { assertStreamIntegrity(s.events); } catch (e) { integ = "ERR:" + e.message; }
out("INTEG", integ);
out("MUT", JSON.stringify(raw) === before ? "unchanged" : "mutated");
out("JSON", JSON.stringify(s));
JS
mig() {
  S27_SID="$1" S27_MIG="$MIG" s27_node "$MIG_JS"
}

case_begin "M1-rename-workflow-type" "hooks/workflow-state/state-io/migrations/v4-to-v5.js"
mk_state '{"sid":"m1a","steps":"workflow_init=complete"}'
o="$(mig m1a)"
check "M1a version raised to 5" "$(field "$o" VER)" "5"
check "M1b wf-code moved to deliverable_type" "$(field "$o" DT)" "wf-code"
check "M1c old workflow_type key dropped" "$(field "$o" WT)" "<absent>"
check "M1d project_management_type not written" "$(field "$o" PMT)" "<absent>"
mk_state '{"sid":"m1b","type":"wf-meta","steps":"workflow_init=complete;clarify_intent=complete"}'
check "M1e wf-meta moved to deliverable_type" "$(field "$(mig m1b)" DT)" "wf-meta"
case_end

case_begin "M2-delivery-path-recorded" "hooks/workflow-state/state-io/migrations/v4-to-v5.js"
mk_state "{\"sid\":\"m2a\",\"steps\":\"$PRE;branching_complete=complete;docs=pending\",\"entered\":true,\"cwd\":\"$S27_REPO_M\"}"
o="$(mig m2a)"
check "M2a branching settled + worktree entered -> pull_request" "$(field "$o" DP)" "pull_request"
check "M2b origin recorded" "$(field "$o" DPO)" "migration-v4-to-v5"
mk_state "{\"sid\":\"m2b\",\"steps\":\"$PRE;branching_complete=complete\"}"
check "M2c branching settled, no entered event -> direct" "$(field "$(mig m2b)" DP)" "direct"
mk_state "{\"sid\":\"m2c\",\"steps\":\"$PRE;branching_complete=skipped\"}"
check "M2d branching skipped counts as settled -> direct" "$(field "$(mig m2c)" DP)" "direct"
case_end

case_begin "M3-delivery-path-not-recorded" "hooks/workflow-state/state-io/migrations/v4-to-v5.js"
mk_state "{\"sid\":\"m3a\",\"steps\":\"$PRE;branching_complete=pending\"}"
o="$(mig m3a)"
check "M3a branching pending -> no delivery_path" "$(field "$o" DP)" "<absent>"
check "M3b ... and no delivery_path_origin" "$(field "$o" DPO)" "<absent>"
mk_state "{\"sid\":\"m3b\",\"steps\":\"$PRE;branching_complete=complete;branching_complete=pending\",\"entered\":true}"
check "M3c last branching status pending (reset) -> none" "$(field "$(mig m3b)" DP)" "<absent>"
mk_state '{"sid":"m3c","type":"wf-meta","steps":"workflow_init=complete;outline=complete;branching_complete=skipped"}'
check "M3d wf-meta -> none even when branching settled" "$(field "$(mig m3c)" DP)" "<absent>"
case_end

case_begin "M4-pure-transform" "hooks/workflow-state/state-io/migrations/v4-to-v5.js"
mk_state "{\"sid\":\"m4\",\"steps\":\"$THRU_RD;user_verification=complete\",\"entered\":true}"
on="$(mig m4)"
off="$(ENFORCE_WORKTREE=off mig m4)"
: > "$WORKFLOW_STATE_DIR/m4.worktree-off"
wto="$(mig m4)"
j_on="$(field "$on" JSON)"
case "$j_on" in
  "<no "*)
    fail "M4a ENFORCE_WORKTREE=off does not change the result" "baseline missing: $j_on"
    fail "M4b WORKTREE_OFF marker does not change the result" "baseline missing: $j_on"
    ;;
  *)
    check "M4a ENFORCE_WORKTREE=off does not change the result" "$(field "$off" JSON)" "$j_on"
    check "M4b WORKTREE_OFF marker does not change the result" "$(field "$wto" JSON)" "$j_on"
    ;;
esac
check "M4c input object not mutated" "$(field "$on" MUT)" "unchanged"
check "M4d seq contiguous after backfill" "$(field "$on" SEQ)" "contiguous"
check "M4e stream integrity holds" "$(field "$on" INTEG)" "ok"
check_contains "M4f sanity: backfill happened in this fixture" "$(field "$on" BF)" "step_status:push_branch:complete"
case_end

case_begin "M5-push-branch-backfill-triggers" "hooks/workflow-state/state-io/migrations/v4-to-v5.js"
n=0
for tail in "user_verification=complete" "user_verification=skipped" "user_verification=complete;cleanup=complete" \
            "pre_final_report_gate=complete" "final_report=complete"; do
  n=$((n + 1))
  mk_state "{\"sid\":\"m5-$n\",\"steps\":\"$THRU_RD;$tail\",\"entered\":true}"
  check "M5.$n push_branch complete when [$tail]" "$(field "$(mig "m5-$n")" PB)" "complete"
done
mk_state "{\"sid\":\"m5-pm\",\"steps\":\"$THRU_RD;user_verification=complete;user_verification=pending\",\"uvReset\":\"post-merge\",\"entered\":true}"
check "M5.pm push_branch complete on UV pending + post-merge" "$(field "$(mig m5-pm)" PB)" "complete"
mk_state "{\"sid\":\"m5-sha\",\"steps\":\"$THRU_RD\",\"lastPushed\":\"abc1234\"}"
check "M5.sha push_branch complete when last_pushed_sha set" "$(field "$(mig m5-sha)" PB)" "complete"
case_end

case_begin "M6-push-branch-backfill-negatives" "hooks/workflow-state/state-io/migrations/v4-to-v5.js"
mk_state "{\"sid\":\"m6a\",\"steps\":\"$THRU_RD\",\"entered\":true}"
o="$(mig m6a)"
check "M6a nothing settled after review_docs -> push_branch pending" "$(field "$o" PB)" "pending"
check "M6b ... merge_to_main pending" "$(field "$o" DL)" "pending"
check "M6c ... no backfilled events" "$(field "$o" BF)" ""
mk_state "{\"sid\":\"m6b\",\"steps\":\"$THRU_RD;user_verification=pending\",\"uvReset\":\"manual-reset\",\"entered\":true}"
check "M6d UV pending with a non-delivery reason -> pending" "$(field "$(mig m6b)" PB)" "pending"
case_end

case_begin "M7-merge-to-main-backfill-triggers" "hooks/workflow-state/state-io/migrations/v4-to-v5.js"
mk_state "{\"sid\":\"m7a\",\"steps\":\"$THRU_RD;user_verification=complete;cleanup=complete\",\"entered\":true}"
check "M7a cleanup settled -> merge_to_main complete" "$(field "$(mig m7a)" DL)" "complete"
mk_state "{\"sid\":\"m7b\",\"steps\":\"$THRU_RD;user_verification=complete;pre_final_report_gate=complete\",\"entered\":true}"
check "M7b pre_final_report_gate settled -> merge_to_main complete" "$(field "$(mig m7b)" DL)" "complete"
mk_state "{\"sid\":\"m7c\",\"steps\":\"$THRU_RD;user_verification=complete;user_verification=pending\",\"uvReset\":\"post-merge\",\"entered\":true}"
o="$(mig m7c)"
check "M7c UV post-merge -> merge_to_main complete" "$(field "$o" DL)" "complete"
check "M7d UV stays pending (boundary, not rewritten)" "$(field "$o" UV)" "pending"
mk_state "{\"sid\":\"m7e\",\"steps\":\"$THRU_RD;user_verification=complete;user_verification=pending\",\"lastPushed\":\"abc1234\"}"
o="$(mig m7e)"
check "M7e UV pending + last_pushed_sha (old off push) -> merge_to_main complete" "$(field "$o" DL)" "complete"
check "M7f ... post-push reset_reason backfilled on UV" "$(field "$o" UVR)" "post-push"
check_contains "M7g ... as a backfilled step_annotation" "$(field "$o" BF)" "step_annotation:user_verification:post-push:migration-v4-to-v5"
case_end

case_begin "M8-merge-to-main-backfill-negatives" "hooks/workflow-state/state-io/migrations/v4-to-v5.js"
mk_state "{\"sid\":\"m8a\",\"steps\":\"$THRU_RD;user_verification=complete\",\"entered\":true}"
o="$(mig m8a)"
check "M8a UV complete only -> push_branch complete" "$(field "$o" PB)" "complete"
check "M8b UV complete only -> merge_to_main pending" "$(field "$o" DL)" "pending"
mk_state "{\"sid\":\"m8c\",\"steps\":\"$THRU_RD;user_verification=complete\",\"lastPushed\":\"abc1234\"}"
o="$(mig m8c)"
check "M8c UV complete + sha -> merge_to_main still pending" "$(field "$o" DL)" "pending"
check "M8d ... no post-push annotation" "$(field "$o" UVR)" "<none>"
mk_state "{\"sid\":\"m8e\",\"steps\":\"$THRU_RD;user_verification=complete;user_verification=pending\"}"
o="$(mig m8e)"
check "M8e UV pending, no reason, no sha -> merge_to_main pending" "$(field "$o" DL)" "pending"
check "M8f ... push_branch pending" "$(field "$o" PB)" "pending"
case_end

case_begin "M9-backfill-event-shape" "hooks/workflow-state/state-io/migrations/v4-to-v5.js"
mk_state "{\"sid\":\"m9\",\"steps\":\"$THRU_RD;user_verification=complete;cleanup=complete\",\"entered\":true}"
o="$(mig m9)"
check "M9 backfilled step_status events carry origin + at_estimated" "$(field "$o" BF)" \
  "step_status:push_branch:complete:migration-v4-to-v5:true,step_status:merge_to_main:complete:migration-v4-to-v5:true"
case_end

case_begin "M10-version-chain-and-guard" "hooks/workflow-state/state-io/core.js"
chain() {
  s27_node "const c = req(\"$CORE\"); const fs = require(\"fs\");
const raw = JSON.parse(fs.readFileSync(process.env.WORKFLOW_STATE_DIR + \"/$1.json\", \"utf8\"));
let r; try { r = c.normalizeStateVersion(raw); out(\"NV\", String(r.version)); out(\"NDT\", r.deliverable_type || \"<absent>\"); } catch (e) { out(\"NV\", e.name); }
const st = c.readState(\"$1\"); out(\"RS\", st === null ? \"null\" : \"v\" + st.version);"
}
mk_state "{\"sid\":\"m10a\",\"version\":3,\"steps\":\"$PRE\"}"
o="$(chain m10a)"
check "M10a v3 file chains to v5" "$(field "$o" NV)" "5"
check "M10b ... with deliverable_type" "$(field "$o" NDT)" "wf-code"
mk_state "{\"sid\":\"m10c\",\"version\":5,\"type\":null,\"steps\":\"$PRE\",\"extra\":{\"deliverable_type\":\"wf-meta\"}}"
o="$(chain m10c)"
check "M10c v5 file is read as-is" "$(field "$o" NDT)" "wf-meta"
check "M10d readState accepts v5" "$(field "$o" RS)" "v5"
mk_state "{\"sid\":\"m10e\",\"version\":6,\"type\":null,\"steps\":\"$PRE\"}"
o="$(chain m10e)"
check "M10e v6 -> FutureSchemaVersionError" "$(field "$o" NV)" "FutureSchemaVersionError"
check "M10f readState fails open with null on v6" "$(field "$o" RS)" "null"
case_end

case_begin "M11-current-version-and-persist" "hooks/workflow-state/state-io/core.js"
mk_state "{\"sid\":\"m11\",\"steps\":\"$THRU_RD;user_verification=complete\",\"entered\":true}"
o="$(s27_node "const c = req(\"$CORE\"); const fs = require(\"fs\"); const m = req(\"$MIG\");
out(\"CUR\", String(c.CURRENT_STATE_VERSION)); out(\"MAX\", String(c.MAX_KNOWN_STATE_VERSION));
out(\"P1\", String(c.persistMigratedState(\"m11\"))); out(\"P2\", String(c.persistMigratedState(\"m11\")));
const d = JSON.parse(fs.readFileSync(process.env.WORKFLOW_STATE_DIR + \"/m11.json\", \"utf8\"));
out(\"DV\", String(d.version)); out(\"DDT\", d.deliverable_type || \"<absent>\"); out(\"DWT\", \"workflow_type\" in d ? \"present\" : \"<absent>\");
const i = c.createInitialState(\"m11x\", { cwd: null, git_branch: null });
out(\"IDT\", i.deliverable_type || \"<absent>\"); out(\"IWT\", \"workflow_type\" in i ? \"present\" : \"<absent>\");
out(\"EXP\", typeof m.migrateV4ToV5);")"
check "M11a CURRENT_STATE_VERSION is 5" "$(field "$o" CUR)" "5"
check "M11b MAX_KNOWN_STATE_VERSION is 5" "$(field "$o" MAX)" "5"
check "M11c persistMigratedState rewrites a v4 file" "$(field "$o" P1)" "true"
check "M11d second persist is a no-op" "$(field "$o" P2)" "false"
check "M11e on-disk version is 5" "$(field "$o" DV)" "5"
check "M11f on-disk deliverable_type" "$(field "$o" DDT)" "wf-code"
check "M11g on-disk workflow_type gone" "$(field "$o" DWT)" "<absent>"
check "M11h createInitialState writes deliverable_type" "$(field "$o" IDT)" "wf-code"
check "M11i createInitialState drops workflow_type" "$(field "$o" IWT)" "<absent>"
check "M11j migrations.js re-exports migrateV4ToV5" "$(field "$o" EXP)" "function"
case_end

# A worktree entered via `cd` leaves no worktree/entered event; the v4 session_worktree proves it.
case_begin "M12-delivery-path-from-session-worktree" "hooks/workflow-state/state-io/migrations/v4-to-v5.js"
mk_state "{\"sid\":\"m12a\",\"steps\":\"$PRE;branching_complete=complete\",\"extra\":{\"session_worktree\":\"/some/path\"}}"
o="$(mig m12a)"
check "M12a no entered event + session_worktree set -> pull_request" "$(field "$o" DP)" "pull_request"
check "M12b ... origin recorded" "$(field "$o" DPO)" "migration-v4-to-v5"
mk_state "{\"sid\":\"m12c\",\"steps\":\"$PRE;branching_complete=complete\",\"extra\":{\"session_worktree\":\"\"}}"
check "M12c empty session_worktree, no event -> direct" "$(field "$(mig m12c)" DP)" "direct"
mk_state "{\"sid\":\"m12d\",\"steps\":\"$PRE;branching_complete=complete\",\"extra\":{\"session_worktree\":null}}"
check "M12d null session_worktree, no event -> direct" "$(field "$(mig m12d)" DP)" "direct"
mk_state "{\"sid\":\"m12e\",\"steps\":\"$PRE;branching_complete=complete\",\"entered\":true,\"cwd\":\"$S27_REPO_M\",\"extra\":{\"session_worktree\":\"\"}}"
check "M12e entered event wins over empty session_worktree -> pull_request" "$(field "$(mig m12e)" DP)" "pull_request"
mk_state "{\"sid\":\"m12f\",\"steps\":\"$PRE;branching_complete=pending\",\"extra\":{\"session_worktree\":\"/some/path\"}}"
check "M12f session_worktree set but branching unsettled -> none" "$(field "$(mig m12f)" DP)" "<absent>"
mk_state '{"sid":"m12g","type":"wf-meta","steps":"workflow_init=complete;branching_complete=skipped","extra":{"session_worktree":"/some/path"}}'
check "M12g wf-meta with session_worktree -> none" "$(field "$(mig m12g)" DP)" "<absent>"
case_end

# Only a wf-code session has release steps: the same settled tail backfills nothing elsewhere.
RELEASED="user_verification=complete;cleanup=complete;pre_final_report_gate=complete;final_report=complete"
BF_BOTH="step_status:push_branch:complete:migration-v4-to-v5:true,step_status:merge_to_main:complete:migration-v4-to-v5:true"
case_begin "M13-no-backfill-outside-wf-code" "hooks/workflow-state/state-io/migrations/v4-to-v5.js"
mk_state "{\"sid\":\"m13a\",\"type\":\"wf-meta\",\"steps\":\"$THRU_RD;$RELEASED\",\"entered\":true,\"lastPushed\":\"abc1234\"}"
o="$(mig m13a)"
check "M13a sanity: migrated as wf-meta" "$(field "$o" DT)" "wf-meta"
check "M13b wf-meta, later steps settled + sha -> no backfilled events" "$(field "$o" BF)" ""
check_not_contains "M13c ... no push_branch event in the stream" "$(field "$o" JSON)" '"step":"push_branch"'
check_not_contains "M13d ... no merge_to_main event in the stream" "$(field "$o" JSON)" '"step":"merge_to_main"'
check "M13e ... stream integrity holds" "$(field "$o" INTEG)" "ok"
mk_state "{\"sid\":\"m13f\",\"type\":\"wf-meta\",\"steps\":\"$THRU_RD;user_verification=complete;user_verification=pending\",\"uvReset\":\"post-merge\",\"lastPushed\":\"abc1234\"}"
o="$(mig m13f)"
check "M13f wf-meta, UV pending post-merge + sha -> no backfilled events" "$(field "$o" BF)" ""
check "M13g ... no post-push annotation" "$(field "$o" UVR)" "post-merge"
mk_state "{\"sid\":\"m13h\",\"type\":\"wf-docs\",\"steps\":\"$THRU_RD;$RELEASED\",\"entered\":true}"
o="$(mig m13h)"
check "M13h any other non-wf-code type -> no backfilled events" "$(field "$o" BF)" ""
check "M13i ... and no delivery_path" "$(field "$o" DP)" "<absent>"
case_end

case_begin "M14-wf-code-and-untyped-backfill" "hooks/workflow-state/state-io/migrations/v4-to-v5.js"
mk_state "{\"sid\":\"m14a\",\"steps\":\"$THRU_RD;$RELEASED\",\"entered\":true,\"lastPushed\":\"abc1234\"}"
o="$(mig m14a)"
check "M14a sanity: migrated as wf-code" "$(field "$o" DT)" "wf-code"
check "M14b wf-code with the same tail -> both steps backfilled" "$(field "$o" BF)" "$BF_BOTH"
mk_state "{\"sid\":\"m14c\",\"type\":null,\"steps\":\"$THRU_RD;$RELEASED\",\"entered\":true,\"lastPushed\":\"abc1234\"}"
o="$(mig m14c)"
check "M14c sanity: the v4 file carries no type" "$(field "$o" DT)" "<absent>"
check "M14d untyped v4 state is wf-code -> both steps backfilled" "$(field "$o" BF)" "$BF_BOTH"
check "M14e ... and the delivery path is recorded" "$(field "$o" DP)" "pull_request"
check "M14f ... stream integrity holds" "$(field "$o" INTEG)" "ok"
case_end

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
