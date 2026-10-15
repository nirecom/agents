#!/usr/bin/env bash
# Tests: hooks/workflow-mark/clarify-intent-complete-handler.js, hooks/workflow-mark/branching-handler.js, hooks/workflow-state/session-profile.js, hooks/workflow-state/state-io/session-fields.js
# Tags: scope:issue-specific, workflow-state, session-profile, delivery-path, pm-type, issue-2527, TL2, delivery-reconcile
# TL2: records PM type and delivery path through the real writers (workflow-mark.js fed the
# CLARIFY_INTENT_COMPLETE / BRANCHING_COMPLETE Bash payloads), then flips the live config and
# asserts the raw state file and resolveSessionProfile keep the recorded values.
# TL3 gap: a real Claude Code session emitting the sentinels is not exercised; only the
# PostToolUse hook process is. The fixture starts from a v4 state today's writers can read.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

s27_setup
trap s27_teardown EXIT
export WORKFLOW_STATE_DIR="$WORKFLOW_STATE_DIR" WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR"
export ENFORCE_WORKTREE=on ENFORCE_WORKTREE_EXCLUDE=""

MARK_JS="$S27_SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark.js"
INTENT_SENTINEL='echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"'
BRANCH_SENTINEL='echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: feature/2527-profile>>"'
PRE_INTENT="workflow_init=complete;clarify_intent=pending"

# mark <sid> <command> — workflow-mark.js fed a successful Bash payload from the fixture repo.
mark() {
  node -e 'process.stdout.write(JSON.stringify({ tool_name: "Bash", session_id: process.argv[1],
    tool_input: { command: process.argv[3], cwd: process.argv[2], description: "test" },
    tool_response: { exit_code: 0 } }))' "$1" "$S27_REPO_M" "$2" | run_with_timeout 60 node "$MARK_JS" 2>&1
}

# write_intent <sid> <pm-line> — the clarify-intent artifact; an empty <pm-line> omits the field.
write_intent() {
  printf '# Intent\n\n**Title:** profile persistence fixture\n%s\n**Closes:** #2527\n' "$2" > "$WORKFLOW_PLANS_DIR/$1-intent.md"
}

# approve_plan <sid> <step...> — #2277 approval records through the real writer.
# approve_intent <sid>: clarify_intent completes only with an approval of the intent file as
# written, so call it after the intent file and before each mark. BRANCHING_COMPLETE likewise
# records nothing until the detail plan is approved.
approve_plan() {
  node "$S27_SCRIPT_CHECKOUT_ROOT/tests/lib/plan-approval-fixture.js" approve "$@" >/dev/null 2>&1 \
    || fail "fixture" "plan-approval-fixture.js approve $* failed"
}
approve_intent() { approve_plan "$1" clarify_intent; }

# last_status <sid> <step> — last step_status of <step> in the raw stream.
last_status() {
  S27_SID="$1" S27_STEP="$2" s27_node 'const fs = require("fs");
let s; try { s = JSON.parse(fs.readFileSync(process.env.WORKFLOW_STATE_DIR + "/" + process.env.S27_SID + ".json", "utf8")); } catch (e) { out("ST", "<unreadable>"); process.exit(0); }
const r = (s.events || []).filter((x) => x.kind === "step_status" && x.step === process.env.S27_STEP);
out("ST", r.length ? r[r.length - 1].status : "<none>");'
}

# RAW=<pm>|<path>|<path origin> from the state file; PROF=<pm>|<pm src>|<path>|<path src>.
read -r -d '' REC_JS <<'JS' || true
const fs = require("fs");
const sid = process.env.S27_SID;
let s; try { s = JSON.parse(fs.readFileSync(process.env.WORKFLOW_STATE_DIR + "/" + sid + ".json", "utf8")); } catch (e) { out("RAW", "<unreadable>"); process.exit(0); }
const g = (k) => (Object.prototype.hasOwnProperty.call(s, k) ? String(s[k]) : "<absent>");
out("RAW", [g("project_management_type"), g("delivery_path"), g("delivery_path_origin")].join("|"));
const core = req("hooks/workflow-state/state-io/core.js");
const m = req("hooks/workflow-state/session-profile.js");
const st = core.readState(sid);
if (!st) { out("PROF", "<no state>"); process.exit(0); }
const r = m.resolveSessionProfile(st, sid, { repoDir: process.env.CLAUDE_PROJECT_DIR });
out("PROF", [r.pmType, r.sources && r.sources.pmType, r.deliveryPath, r.sources && r.sources.deliveryPath].join("|"));
JS
recorded() { S27_SID="$1" s27_node "$REC_JS"; }

case_begin "pull-request-profile-fixed-after-config-flip" "hooks/workflow-mark/branching-handler.js"
# #2527 3-13: a pull_request BRANCHING_COMPLETE must name a real linked worktree of the repo
# cwd (CLAUDE_PROJECT_DIR = S27_REPO_M), or the reconcile rejects it before recording.
git -C "$S27_REPO" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m seed
S27_WT="$S27_TMP/repo-wt"
git -C "$S27_REPO" worktree add -q -b feature/2527-profile "$S27_WT" >/dev/null 2>&1
PR_BRANCH_SENTINEL="echo \"<<WORKFLOW_BRANCHING_COMPLETE: branch: feature/2527-profile worktree: $(np "$S27_WT")>>\""
mk_state "{\"sid\":\"pp-pr\",\"steps\":\"$PRE_INTENT\"}"
write_intent pp-pr '**PM type:** waterfall'
approve_intent pp-pr
mark pp-pr "$INTENT_SENTINEL" >/dev/null
approve_plan pp-pr detail
mark pp-pr "$PR_BRANCH_SENTINEL" >/dev/null
check "sanity: clarify_intent recorded complete" "$(field "$(last_status pp-pr clarify_intent)" ST)" "complete"
check "sanity: branching_complete recorded complete" "$(field "$(last_status pp-pr branching_complete)" ST)" "complete"
check "recorded at the fixed points (live on)" "$(field "$(recorded pp-pr)" RAW)" "waterfall|pull_request|branching-handler"
export ENFORCE_WORKTREE=off ENFORCE_WORKTREE_EXCLUDE="$S27_REPO_M"
: > "$WORKFLOW_STATE_DIR/pp-pr.worktree-off"
write_intent pp-pr '**PM type:** agile'
approve_intent pp-pr
mark pp-pr "$INTENT_SENTINEL" >/dev/null
run_next_step pp-pr >/dev/null
o="$(recorded pp-pr)"
check "state file unchanged after live config flip + re-read" "$(field "$o" RAW)" "waterfall|pull_request|branching-handler"
check "resolved profile keeps the recorded values" "$(field "$o" PROF)" "waterfall|recorded|pull_request|recorded"
export ENFORCE_WORKTREE=on ENFORCE_WORKTREE_EXCLUDE=""
case_end

case_begin "direct-profile-fixed-after-config-flip" "hooks/workflow-mark/branching-handler.js"
export ENFORCE_WORKTREE=off
mk_state "{\"sid\":\"pp-d\",\"steps\":\"$PRE_INTENT\"}"
write_intent pp-d '**PM type:** waterfall'
approve_intent pp-d
mark pp-d "$INTENT_SENTINEL" >/dev/null
approve_plan pp-d detail
mark pp-d "$BRANCH_SENTINEL" >/dev/null
check "sanity: branching_complete recorded complete" "$(field "$(last_status pp-d branching_complete)" ST)" "complete"
check "recorded at the fixed points (live off)" "$(field "$(recorded pp-d)" RAW)" "waterfall|direct|branching-handler"
export ENFORCE_WORKTREE=on
run_next_step pp-d >/dev/null
o="$(recorded pp-d)"
check "state file unchanged after live flip to on" "$(field "$o" RAW)" "waterfall|direct|branching-handler"
check "resolved profile keeps direct (recorded)" "$(field "$o" PROF)" "waterfall|recorded|direct|recorded"
case_end

case_begin "intent-without-pm-type-records-waterfall" "hooks/workflow-mark/clarify-intent-complete-handler.js"
mk_state "{\"sid\":\"pp-legacy\",\"steps\":\"$PRE_INTENT\"}"
write_intent pp-legacy ''
approve_intent pp-legacy
mark pp-legacy "$INTENT_SENTINEL" >/dev/null
check "sanity: clarify_intent recorded complete" "$(field "$(last_status pp-legacy clarify_intent)" ST)" "complete"
o="$(recorded pp-legacy)"
check "legacy intent (no PM type field) records waterfall" "$(field "$o" RAW | cut -d'|' -f1)" "waterfall"
check "profile pm source is recorded" "$(field "$o" PROF | cut -d'|' -f1-2)" "waterfall|recorded"
case_end

case_begin "intent-with-unsupported-pm-type-records-nothing" "hooks/workflow-mark/clarify-intent-complete-handler.js"
mk_state "{\"sid\":\"pp-agile\",\"steps\":\"$PRE_INTENT\"}"
write_intent pp-agile '**PM type:** agile'
approve_intent pp-agile
mk_out="$(mark pp-agile "$INTENT_SENTINEL")"
check "sanity: clarify_intent recorded complete" "$(field "$(last_status pp-agile clarify_intent)" ST)" "complete"
check_contains "warning names the unsupported value" "$mk_out" "agile"
o="$(recorded pp-agile)"
check "agile is not recorded" "$(field "$o" RAW | cut -d'|' -f1)" "<absent>"
check "profile falls back to provisional waterfall" "$(field "$o" PROF | cut -d'|' -f1-2)" "waterfall|provisional"
case_end

# Rows: <name> | <intent body after the Title line, printf %b; <LONG> = 4000 x's> | <want RAW pm> | <warn yes|no>.
# Bodies that end before **Closes:** put the field at end of file. pm-empty-mid / pm-blank-mid
# guard the `[ \t]*` separator: an empty value stays on its own line (waterfall default) and
# never swallows the next line as the value.
# Mutation Probe (PM_TYPE_LINE_RE): greedy `(.*)` reds pm-trailing-space; dropping /i
# reds pm-label-mixed-case-agile; dropping the `^[ \t]*` anchor reds pm-list-prefixed; widening
# `[ \t]` back to `\s` reds pm-empty-mid / pm-blank-mid; dropping /m
# reds every warn=yes row (no match anywhere past line 1, so waterfall is recorded instead).
case_begin "pm-type-line-parser-table" "hooks/workflow-mark/clarify-intent-complete-handler.js"
PM_LONG="$(printf 'x%.0s' $(seq 1 4000))"
n=0
while IFS='|' read -r name body want warn; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"; warn="${warn//[[:space:]]/}"
  body="${body#"${body%%[![:space:]]*}"}"; body="${body%"${body##*[![:space:]]}"}"
  body="${body//<LONG>/$PM_LONG}"
  n=$((n + 1)); sid="pp-parse-$n"
  mk_state "{\"sid\":\"$sid\",\"steps\":\"$PRE_INTENT\"}"
  printf '# Intent\n\n**Title:** parser fixture\n%b' "$body" > "$WORKFLOW_PLANS_DIR/$sid-intent.md"
  approve_intent "$sid"
  mk_out="$(mark "$sid" "$INTENT_SENTINEL")"
  check "$name: clarify_intent complete" "$(field "$(last_status "$sid" clarify_intent)" ST)" "complete"
  check "$name: recorded pm" "$(field "$(recorded "$sid")" RAW | cut -d'|' -f1)" "$want"
  if [ "$warn" = "yes" ]; then
    check_contains "$name: unsupported warning" "$mk_out" "is not supported yet"
  else
    check_not_contains "$name: no warning" "$mk_out" "is not supported yet"
  fi
done <<'TABLE'
pm-waterfall          | **PM type:** waterfall\n**Closes:** #2527\n               | waterfall | no
pm-agile-unsupported  | **PM type:** agile\n**Closes:** #2527\n                   | <absent>  | yes
pm-value-uppercase    | **PM type:** WATERFALL\n**Closes:** #2527\n               | waterfall | no
pm-label-mixed-case   | **pm TYPE:** Waterfall\n**Closes:** #2527\n               | waterfall | no
pm-label-mixed-case-agile | **Pm Type:** agile\n**Closes:** #2527\n             | <absent>  | yes
pm-trailing-space     | **PM type:** waterfall\040\040\040\n**Closes:** #2527\n   | waterfall | no
pm-crlf               | **PM type:** waterfall\r\n**Closes:** #2527\r\n           | waterfall | no
pm-leading-indent     | \040\040**PM type:** waterfall\n**Closes:** #2527\n       | waterfall | no
pm-tab-separator      | **PM type:**\twaterfall\n**Closes:** #2527\n              | waterfall | no
pm-no-separator       | **PM type:**waterfall\n**Closes:** #2527\n                | waterfall | no
pm-empty-mid          | **PM type:**\n**Closes:** #2527\n                         | waterfall | no
pm-blank-mid          | **PM type:**\040\040\t\n**Closes:** #2527\n               | waterfall | no
pm-empty-eof          | **Closes:** #2527\n**PM type:**                           | waterfall | no
pm-blank-eof          | **Closes:** #2527\n**PM type:**\040\040\t                 | waterfall | no
pm-dup-waterfall-first| **PM type:** waterfall\n**PM type:** agile\n**Closes:** #2527\n | waterfall | no
pm-dup-agile-first    | **PM type:** agile\n**PM type:** waterfall\n**Closes:** #2527\n | <absent>  | yes
pm-invalid-kanban     | **PM type:** kanban\n**Closes:** #2527\n                  | <absent>  | yes
pm-value-with-suffix  | **PM type:** waterfall (default)\n**Closes:** #2527\n     | <absent>  | yes
pm-very-long          | **PM type:** waterfall<LONG>\n**Closes:** #2527\n         | <absent>  | yes
pm-missing-bold       | PM type: agile\n**Closes:** #2527\n                       | waterfall | no
pm-list-prefixed      | - **PM type:** agile\n**Closes:** #2527\n                 | waterfall | no
TABLE
check "parser table ran every row" "$n" "21"
case_end

# W=<return values>; RAW=<field>|<origin> from the state file after the calls in $2.
read -r -d '' SETTER_JS <<'JS' || true
const fs = require("fs");
const io = req("hooks/workflow-state/state-io.js");
const sid = process.env.S27_SID;
const calls = JSON.parse(process.env.S27_CALLS);
out("W", calls.map(([fn, ...a]) => String(io[fn](sid, ...a))).join(","));
const s = JSON.parse(fs.readFileSync(process.env.WORKFLOW_STATE_DIR + "/" + sid + ".json", "utf8"));
const g = (k) => (Object.prototype.hasOwnProperty.call(s, k) ? String(s[k]) : "<absent>");
out("DP", g("delivery_path") + "|" + g("delivery_path_origin"));
out("AMP", g("auto_merge_pr") + "|" + g("auto_merge_pr_origin") + "|" + g("auto_merge_pr_source"));
out("PMT", g("project_management_type"));
out("DT", g("deliverable_type"));
JS
setters() { S27_SID="$1" S27_CALLS="$2" s27_node "$SETTER_JS"; }

# Plan 4-2: setDeliveryProfile(sid, {deliveryPath, autoMergePr, source, origin}) writes both
# fields in one updateTopLevel, write-once per field; setDeliveryPath is gone (no alias).
P1='{"deliveryPath":"direct","autoMergePr":"off","source":"config","origin":"first-origin"}'
P2='{"deliveryPath":"pull_request","autoMergePr":"on","source":"default","origin":"second-origin"}'
case_begin "setter-write-once-delivery-profile" "hooks/workflow-state/state-io/session-fields.js"
mk_state "{\"sid\":\"wo-dp\",\"steps\":\"$PRE_INTENT\"}"
o="$(setters wo-dp "[[\"setDeliveryProfile\",$P1],[\"setDeliveryProfile\",$P2]]")"
check "first delivery_path and origin kept" "$(field "$o" DP)" "direct|first-origin"
check "first auto_merge_pr / origin / source kept" "$(field "$o" AMP)" "off|first-origin|config"
mk_state "{\"sid\":\"wo-dp-null\",\"steps\":\"$PRE_INTENT\",\"extra\":{\"delivery_path\":null,\"delivery_path_origin\":null,\"auto_merge_pr\":null}}"
o="$(setters wo-dp-null "[[\"setDeliveryProfile\",$P2]]")"
check "null delivery_path replaced" "$(field "$o" DP)" "pull_request|second-origin"
check "null auto_merge_pr replaced" "$(field "$o" AMP)" "on|second-origin|default"
# Per-field write-once: an old state holding only delivery_path gains auto_merge_pr alone.
mk_state "{\"sid\":\"wo-dp-half\",\"steps\":\"$PRE_INTENT\",\"extra\":{\"delivery_path\":\"direct\",\"delivery_path_origin\":\"old\"}}"
o="$(setters wo-dp-half "[[\"setDeliveryProfile\",$P2]]")"
check "recorded delivery_path untouched" "$(field "$o" DP)" "direct|old"
check "missing auto_merge_pr filled" "$(field "$o" AMP)" "on|second-origin|default"
o="$(S27_SID=wo-dp-half s27_node 'const io = req("hooks/workflow-state/state-io.js"); out("OLD", typeof io.setDeliveryPath);')"
check "setDeliveryPath alias removed" "$(field "$o" OLD)" "undefined"
case_end

case_begin "setter-write-once-pm-type" "hooks/workflow-state/state-io/session-fields.js"
mk_state "{\"sid\":\"wo-pm\",\"steps\":\"$PRE_INTENT\"}"
o="$(setters wo-pm '[["setProjectManagementType","waterfall"],["setProjectManagementType","agile"]]')"
check "first write true, second write false" "$(field "$o" W)" "true,false"
check "first value kept" "$(field "$o" PMT)" "waterfall"
mk_state "{\"sid\":\"wo-pm-null\",\"steps\":\"$PRE_INTENT\",\"extra\":{\"project_management_type\":null}}"
o="$(setters wo-pm-null '[["setProjectManagementType","waterfall"]]')"
check "explicit null field -> written, true" "$(field "$o" W)" "true"
check "null field replaced" "$(field "$o" PMT)" "waterfall"
case_end

case_begin "setter-deliverable-type-rewritable" "hooks/workflow-state/state-io/session-fields.js"
mk_state "{\"sid\":\"rw-dt\",\"steps\":\"$PRE_INTENT\"}"
o="$(setters rw-dt '[["setDeliverableType","wf-code"],["setDeliverableType","wf-meta"]]')"
check "both writes true" "$(field "$o" W)" "true,true"
check "last value wins" "$(field "$o" DT)" "wf-meta"
case_end

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
