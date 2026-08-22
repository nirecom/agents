#!/bin/bash
# tests/feature-workflow-init-driver/driver-checkpoint-resume.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/checkpoint.js, bin/workflow/lib/workflow-init/phases/fetch-issues.js, bin/workflow/lib/workflow-init/phases/wip-check.js, bin/workflow/lib/workflow-init/phases/closed-detection.js, bin/workflow/lib/workflow-init/phases/label-extract.js, bin/workflow/lib/workflow-init/phases/meta-classify.js, bin/workflow/lib/workflow-init/phases/route-decision.js
# Tags: workflow-init, driver, checkpoint-resume, meta-classify, scope:issue-specific
#
# C1-C14 — checkpoint persistence and --resume/--answer transition tests.
# C15-C16 continue the series in the sibling driver-answer-validation.sh.

# TL3 gap: no real `claude -p` AskUserQuestion → --resume --answer round-trip
# through the SKILL.md driver loop, and no live gh calls (issue view caching
# across process restarts). Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# --- C1: ask_user interruption persists checkpoint JSON --------------------------
setup_case wid-c1
mock_issue 600 OPEN "type:task"
set_wip 600 other
run_driver '#600'
assert_kv "C1: wip=other interrupts with ask_user" ACTION ask_user
CKPT="$(get_kv CHECKPOINT)" || true
if [ -n "$CKPT" ] && [ -f "$CKPT" ]; then
    pass "C1: checkpoint file persisted at ask_user interruption"
else
    fail "C1: checkpoint missing (got '$CKPT')"
fi
V="$(ckpt_get "$CKPT" version)"
case "$V" in
    ''|'<missing>'|'<unreadable>'|*[!0-9]*) fail "C1: version field not numeric: '$V'" ;;
    *) pass "C1: checkpoint carries numeric version ($V)" ;;
esac
assert_ckpt "C1: checkpoint session_id matches CLAUDE_SESSION_ID" "$CKPT" session_id wid-c1
PH="$(ckpt_get "$CKPT" phase)"
case "$PH" in
    detect-issues|fetch-issues|label-extract|meta-classify|wip-check|closed-detection|route-decision|write-context)
        pass "C1: phase field '$PH' is a known phase name" ;;
    *) fail "C1: phase field '$PH' is not a known phase name" ;;
esac
assert_ckpt "C1: ask_id recorded as wip_conflict" "$CKPT" ask_id wip_conflict
# #2087: label-extract now precedes wip-check, so a checkpoint written at
# wip_conflict already carries the labels. Under the old order this was {}.
C1_LS="$(ckpt_get "$CKPT" state.label_sets)"
case "$C1_LS" in
    *'"600"'*) pass "C1: checkpoint state.label_sets carries #600 (label-extract ran before wip-check)" ;;
    *) fail "C1: state.label_sets lacks an entry for #600: '$C1_LS'" ;;
esac
teardown_case

# --- C2: resume(continue) after wip_conflict — no gh issue view re-invocation -----
setup_case wid-c2
mock_issue 601 OPEN "type:task"
set_wip 601 other
run_driver '#601'
assert_kv "C2: initial run interrupts at wip_conflict" ASK_ID wip_conflict
CKPT="$(get_kv CHECKPOINT)" || true
C2_BEFORE="$(count_gh_calls 'issue view')"
if [ "$C2_BEFORE" -ge 1 ] 2>/dev/null; then
    pass "C2: initial run fetched via gh issue view ($C2_BEFORE call(s))"
else
    fail "C2: expected >=1 gh issue view call in initial run, got '$C2_BEFORE'"
fi
run_driver --resume "$CKPT" --answer continue
assert_kv "C2: resume(continue) completes pipeline → ACTION=done" ACTION done
C2_AFTER="$(count_gh_calls 'issue view')"
if [ "$C2_AFTER" = "$C2_BEFORE" ]; then
    pass "C2: resume did NOT re-invoke gh issue view (cache honored: $C2_BEFORE → $C2_AFTER)"
else
    fail "C2: gh issue view re-invoked on resume ($C2_BEFORE → $C2_AFTER)"
fi
teardown_case

# --- C3: resume(abort) → blocked with REASON=user_aborted --------------------------
setup_case wid-c3
mock_issue 602 OPEN "type:task"
set_wip 602 other
run_driver '#602'
CKPT="$(get_kv CHECKPOINT)" || true
run_driver --resume "$CKPT" --answer abort
assert_kv "C3: abort answer → ACTION=blocked" ACTION blocked
assert_kv "C3: abort answer → REASON=user_aborted" REASON user_aborted
teardown_case

# --- C4a: closed_reopen answer 'remove' with 2 issues → N removed ------------------
setup_case wid-c4a
mock_issue 610 CLOSED "type:task"
mock_issue 611 OPEN "type:task"
set_wip 610 same
set_wip 611 same
run_driver '#610' '#611'
assert_kv "C4a: CLOSED member interrupts with ask_user" ACTION ask_user
assert_kv "C4a: ask id names the closed issue" ASK_ID closed_reopen_610
CKPT="$(get_kv CHECKPOINT)" || true
run_driver --resume "$CKPT" --answer remove
assert_kv "C4a: remove with 2 issues → pipeline completes (done)" ACTION done
CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "C4a: #610 removed from checkpoint state.issues" "$CKPT2" state.issues "[611]"
teardown_case

# --- C4b: closed_reopen answer 'remove' with 1 issue → blocked ---------------------
setup_case wid-c4b
mock_issue 612 CLOSED "type:task"
set_wip 612 same
run_driver '#612'
assert_kv "C4b: single CLOSED issue interrupts" ASK_ID closed_reopen_612
CKPT="$(get_kv CHECKPOINT)" || true
run_driver --resume "$CKPT" --answer remove
assert_kv "C4b: remove with 1 issue → ACTION=blocked (zero issues left)" ACTION blocked
assert_nonempty_kv "C4b: blocked response carries REASON=" REASON
teardown_case

# --- C5: closed_reopen answer 'reopen' → continues past closed-detection -----------
setup_case wid-c5
mock_issue 613 CLOSED "type:task"
set_wip 613 same
run_driver '#613'
assert_kv "C5: CLOSED issue interrupts" ASK_ID closed_reopen_613
CKPT="$(get_kv CHECKPOINT)" || true
run_driver --resume "$CKPT" --answer reopen
assert_kv "C5: reopen answer continues past closed-detection → done" ACTION done
teardown_case

# --- C6: meta_select answer '#M' → issues=[M], M re-fetched -------------------------
setup_case wid-c6
mock_issue 620 OPEN "meta"
mock_issue 621 OPEN "type:task"
set_wip 620 same
set_wip 621 same
mock_sub_issues 620 '[{"number":621,"title":"Child of 620","state":"open"}]'
run_driver '#620'
assert_kv "C6: meta with open child → meta_select ask" ASK_ID meta_select
CKPT="$(get_kv CHECKPOINT)" || true
C6_BEFORE="$(count_gh_calls 'issue view #?621')"
run_driver --resume "$CKPT" --answer '#621'
assert_kv "C6: '#621' answer → pipeline completes (done)" ACTION done
C6_AFTER="$(count_gh_calls 'issue view #?621')"
if [ "$C6_AFTER" = "$((C6_BEFORE + 1))" ] 2>/dev/null; then
    pass "C6: selected sub-issue re-fetched exactly once ($C6_BEFORE → $C6_AFTER)"
else
    fail "C6: expected issue view count for #621 to increment by 1 ($C6_BEFORE → $C6_AFTER)"
fi
CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "C6: state.issues replaced with the selected sub-issue" "$CKPT2" state.issues "[621]"
teardown_case

# --- C7: checkpoint version mismatch → ignored, restart from first phase ------------
setup_case wid-c7
mock_issue 630 OPEN "type:task"
set_wip 630 other
run_driver '#630'
assert_kv "C7: initial run interrupts at wip_conflict" ACTION ask_user
CKPT="$(get_kv CHECKPOINT)" || true
set_wip 630 none   # let the restarted pipeline run clean to done
if ! node -e 'const fs=require("fs");const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,"utf8"));j.version=999999;fs.writeFileSync(p,JSON.stringify(j));' "$CKPT" 2>/dev/null; then
    fail "C7: could not tamper checkpoint version (missing/unreadable: '$CKPT')"
fi
C7_BEFORE="$(count_gh_calls 'issue view #?630')"
run_driver --resume "$CKPT" --answer continue '#630'
C7_AFTER="$(count_gh_calls 'issue view #?630')"
if [ -n "$C7_BEFORE" ] && [ "$C7_AFTER" -gt "$C7_BEFORE" ] 2>/dev/null; then
    pass "C7: version mismatch → checkpoint ignored, issue re-fetched ($C7_BEFORE → $C7_AFTER)"
else
    fail "C7: expected re-fetch after version-mismatch restart ($C7_BEFORE → $C7_AFTER)"
fi
assert_kv "C7: restarted pipeline completes → ACTION=done" ACTION done
teardown_case

# --- C8: --resume with missing/malformed checkpoint → diagnostic, no bare stack trace
check_c8() {  # <label> — evaluates $DRIVER_OUT/$DRIVER_ERR/$DRIVER_RC
    local label="$1" blocked=0 diag=0 stack=0 all
    all="$DRIVER_OUT
$DRIVER_ERR"
    if [ "$(get_kv ACTION)" = "blocked" ] && [ -n "$(get_kv REASON)" ]; then blocked=1; fi
    printf '%s\n' "$all" | grep -qiE 'checkpoint|resume|not found|no such|missing|invalid|malformed|ENOENT|parse' && diag=1
    printf '%s\n' "$all" | grep -qE '^[[:space:]]+at ' && stack=1
    if [ "$blocked" -eq 1 ]; then
        pass "$label (ACTION=blocked with REASON)"
    elif [ "$DRIVER_RC" -ne 0 ] && [ "$diag" -eq 1 ] && [ "$stack" -eq 0 ]; then
        pass "$label (non-zero exit with diagnostic, no unhandled stack trace)"
    else
        fail "$label: rc=$DRIVER_RC blocked=$blocked diag=$diag stacktrace=$stack head='$(printf '%s' "$all" | head -c 120)'"
    fi
}
setup_case wid-c8a
run_driver --resume "$PLANS/does-not-exist-checkpoint.json" --answer continue
check_c8 "C8a: missing checkpoint file rejected with diagnostic"
teardown_case
setup_case wid-c8b
printf 'not-json{{{' > "$PLANS/wid-c8b-wi-checkpoint.json"
run_driver --resume "$PLANS/wid-c8b-wi-checkpoint.json" --answer continue
check_c8 "C8b: malformed checkpoint JSON rejected with diagnostic"
teardown_case

# --- C9: invalid --answer token → rejected, checkpoint unchanged ---------------------
setup_case wid-c9
mock_issue 640 OPEN "type:task"
set_wip 640 other
run_driver '#640'
assert_kv "C9: initial run interrupts at wip_conflict" ACTION ask_user
CKPT="$(get_kv CHECKPOINT)" || true
if [ -n "$CKPT" ] && [ -f "$CKPT" ]; then cp "$CKPT" "$CASE_DIR/ckpt.snapshot"; fi
run_driver --resume "$CKPT" --answer 'bogus-token'
ACT="$(get_kv ACTION)" || true
C9_OK=0
if [ "$ACT" != "done" ] && [ "$ACT" != "invoke" ]; then
    if [ "$ACT" = "blocked" ] && [ -n "$(get_kv REASON)" ]; then C9_OK=1
    elif [ "$ACT" = "ask_user" ]; then C9_OK=1   # pending ask re-emitted
    elif [ "$DRIVER_RC" -ne 0 ] && printf '%s\n%s' "$DRIVER_OUT" "$DRIVER_ERR" | grep -qiE 'invalid|unknown|unexpected|answer'; then C9_OK=1
    fi
fi
if [ "$C9_OK" -eq 1 ]; then
    pass "C9: invalid answer token rejected with diagnostic (action='$ACT', rc=$DRIVER_RC)"
else
    fail "C9: invalid answer token not rejected (action='$ACT', rc=$DRIVER_RC)"
fi
if [ -n "$CKPT" ] && [ -f "$CKPT" ] && [ -f "$CASE_DIR/ckpt.snapshot" ] && cmp -s "$CKPT" "$CASE_DIR/ckpt.snapshot"; then
    pass "C9: checkpoint state unchanged after invalid answer"
else
    fail "C9: checkpoint changed or missing after invalid answer"
fi
teardown_case

# --- C10: meta_select resume re-classifies the SELECTED sub-issue -------------------
# #651 is itself a meta issue with no open children. The fetch-issues resume entry
# point must pass back through meta-classify, so the answer resolves to META — not
# to whatever route-decision would make of an unclassified issue.
setup_case wid-c10
mock_issue 650 OPEN "meta"
mock_issue 651 OPEN "meta"
set_wip 651 same
mock_sub_issues 650 '[{"number":651,"title":"Child of 650","state":"open"}]'
mock_sub_issues 651 '[]'
run_driver '#650'
assert_kv "C10: meta parent with an open child → meta_select ask" ASK_ID meta_select
CKPT="$(get_kv CHECKPOINT)" || true
run_driver --resume "$CKPT" --answer '#651'
assert_kv "C10: '#651' answer → pipeline completes (done)" ACTION done
assert_kv "C10: selected sub-issue re-classified → PATH_DECISION=META" PATH_DECISION META
teardown_case

# --- C11: classify-then-wip-check ordering also holds on the resume path -------------
setup_case wid-c11
mock_issue 660 OPEN "meta"
mock_issue 661 OPEN "type:task"
set_wip 661 other
mock_sub_issues 660 '[{"number":661,"title":"Child of 660","state":"open"}]'
run_driver '#660'
assert_kv "C11: meta parent with an open child → meta_select ask" ASK_ID meta_select
CKPT="$(get_kv CHECKPOINT)" || true
run_driver --resume "$CKPT" --answer '#661'
assert_kv "C11: selected non-meta sub-issue owned elsewhere → ACTION=ask_user" ACTION ask_user
assert_kv "C11: the ask is wip_conflict for the SELECTED issue" ASK_ID wip_conflict
if wip_calls | grep -qE '^check 661$'; then
    pass "C11: wip-state.sh checked the selected sub-issue #661"
else
    fail "C11: no 'check 661' recorded: $(wip_calls | tr '\n' ';')"
fi
if wip_calls | grep -qE '(^| )660( |$)'; then
    fail "C11: wip-state.sh touched the meta parent #660: $(wip_calls | tr '\n' ';')"
else
    pass "C11: wip-state.sh never invoked for the meta parent #660"
fi
teardown_case

# --- C12: a pre-#2087 (version=1) checkpoint is discarded, not replayed --------------
# Hand-written rather than tampered (C7's approach) because the SHAPE is the point:
# a v1 checkpoint stopped at wip_conflict BEFORE label-extract ran, so label_sets is
# empty. Replaying it under the new PHASE_ORDER would route #670 as a plain task.
# The CHECKPOINT_VERSION bump forces a full restart from detect-issues instead.
setup_case wid-c12
mock_issue 670 OPEN "meta"
mock_issue 671 OPEN "type:task"
mock_sub_issues 670 '[{"number":671,"title":"Child of 670","state":"open"}]'
OLD_CKPT="$PLANS/wid-c12-wi-checkpoint.json"
node -e '
const fs = require("fs");
const path = require("path");
const p = process.argv[1];
fs.mkdirSync(path.dirname(p), { recursive: true });
fs.writeFileSync(p, JSON.stringify({
  version: 1,
  session_id: "wid-c12",
  phase: "wip-check",
  ask_id: "wip_conflict",
  state: {
    issues: [670],
    repo_map: {},
    sid_pass: null,
    issue_json_cache: {},
    wip_results: { "670": "other" },
    label_sets: {},
    force_path_b: false,
    path_decision: null,
    adopt_candidate: null,
    adopt_decision: null
  }
}));
' "$OLD_CKPT"
C12_BEFORE="$(count_gh_calls 'issue view #?670')"
run_driver --resume "$OLD_CKPT" --answer continue '#670'
C12_AFTER="$(count_gh_calls 'issue view #?670')"
if [ -n "$C12_BEFORE" ] && [ "$C12_AFTER" -gt "$C12_BEFORE" ] 2>/dev/null; then
    pass "C12: pre-migration (version=1) checkpoint discarded, #670 re-fetched ($C12_BEFORE → $C12_AFTER)"
else
    fail "C12: expected re-fetch after pre-migration checkpoint restart ($C12_BEFORE → $C12_AFTER)"
fi
assert_kv "C12: restart re-classifies #670 as meta with an open sub-issue → meta_select" ASK_ID meta_select
teardown_case

# --- C13: meta_select answer OUTSIDE the offered set → rejected, nothing selected ----
# CPR-ORTH counterpart of C6/C10/C11, which only cover the accept path (the answered
# number IS offered). The rejected number here is a CLOSED sub-issue of the same
# parent: real, adjacent, excluded from openSubs — and independently fetchable, so an
# unpatched applyAnswer() would accept it and complete the pipeline on #682.
setup_case wid-c13
mock_issue 680 OPEN "meta"
mock_issue 681 OPEN "type:task"
mock_issue 682 OPEN "type:task"
set_wip 681 same
set_wip 682 same
mock_sub_issues 680 '[{"number":681,"title":"Open child","state":"open"},{"number":682,"title":"Closed child","state":"closed"}]'
run_driver '#680'
assert_kv "C13: meta parent with an open child → meta_select ask" ASK_ID meta_select
CKPT="$(get_kv CHECKPOINT)" || true
# Entries are {number, ownerRepo}: a number alone does not identify an issue across
# repositories (driver-meta-repo-identity.sh M26). Both children live in the origin
# repo here, so the fallback identity is what is recorded.
assert_ckpt "C13: only the OPEN sub-issue is recorded as offered" "$CKPT" state.meta_select_offered \
    "[{\"number\":681,\"ownerRepo\":\"$CASE_ORIGIN_OWNER_REPO\"}]"
if [ -n "$CKPT" ] && [ -f "$CKPT" ]; then cp "$CKPT" "$CASE_DIR/ckpt.snapshot"; fi
C13_BEFORE="$(count_gh_calls 'issue view #?682')"
run_driver --resume "$CKPT" --answer '#682'
assert_kv "C13: non-offered number → ACTION=blocked" ACTION blocked
assert_kv "C13: rejection carries REASON=invalid-answer" REASON invalid-answer
assert_single_action_line "C13: rejection emits exactly one ACTION= line"
if printf '%s\n%s' "$DRIVER_OUT" "$DRIVER_ERR" | grep -q 'offered sub-issues: 681'; then
    pass "C13: diagnostic names the offered set (681)"
else
    fail "C13: diagnostic omits the offered set: err='$(printf '%s' "$DRIVER_ERR" | head -c 160)'"
fi
C13_AFTER="$(count_gh_calls 'issue view #?682')"
if [ "$C13_AFTER" = "$C13_BEFORE" ]; then
    pass "C13: rejected #682 never fetched ($C13_BEFORE → $C13_AFTER)"
else
    fail "C13: rejected #682 was fetched anyway ($C13_BEFORE → $C13_AFTER)"
fi
# Security idempotency: replaying the same rejected answer must not erode the guard.
run_driver --resume "$CKPT" --answer '#682'
assert_kv "C13: replayed rejection still ACTION=blocked" ACTION blocked
if [ -f "$CKPT" ] && [ -f "$CASE_DIR/ckpt.snapshot" ] && cmp -s "$CKPT" "$CASE_DIR/ckpt.snapshot"; then
    pass "C13: checkpoint (issues + offered set) unchanged after both rejections"
else
    fail "C13: checkpoint mutated by a rejected meta_select answer"
fi
teardown_case

# --- C14a: stale checkpoint + NO positional token → issues recovered from the ckpt ---
# The documented resume invocation (skills/workflow-init/SKILL.md WI-2) passes no '#N'
# token, unlike C7/C12. `tokens.length > 0 ? tokens : staleIssues` must then take the
# issue numbers from the stale checkpoint's own state, or the restart runs detect-issues
# on nothing and Path C silently swallows the session.
setup_case wid-c14a
mock_issue 690 OPEN "type:task"
mock_issue 691 OPEN "type:task"
set_wip 690 other
run_driver '#690' '#691'
assert_kv "C14a: initial run interrupts at wip_conflict" ASK_ID wip_conflict
CKPT="$(get_kv CHECKPOINT)" || true
set_wip 690 none   # let the restarted pipeline run clean to done
if ! node -e 'const fs=require("fs");const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,"utf8"));j.version=999999;fs.writeFileSync(p,JSON.stringify(j));' "$CKPT" 2>/dev/null; then
    fail "C14a: could not tamper checkpoint version (missing/unreadable: '$CKPT')"
fi
C14A_B690="$(count_gh_calls 'issue view #?690')"
C14A_B691="$(count_gh_calls 'issue view #?691')"
run_driver --resume "$CKPT" --answer continue
assert_kv "C14a: token-less restart completes → ACTION=done" ACTION done
assert_kv "C14a: recovered issues route to Path B (not the empty-set Path C)" PATH_DECISION B
CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "C14a: both stale issue numbers recovered into state.issues" "$CKPT2" state.issues "[690,691]"
C14A_A690="$(count_gh_calls 'issue view #?690')"
C14A_A691="$(count_gh_calls 'issue view #?691')"
if [ "$C14A_A690" -gt "$C14A_B690" ] 2>/dev/null && [ "$C14A_A691" -gt "$C14A_B691" ] 2>/dev/null; then
    pass "C14a: both recovered issues re-fetched (690: $C14A_B690 → $C14A_A690, 691: $C14A_B691 → $C14A_A691)"
else
    fail "C14a: expected re-fetch of both recovered issues (690: $C14A_B690 → $C14A_A690, 691: $C14A_B691 → $C14A_A691)"
fi
teardown_case

# --- C14b: recovered issue numbers are integer-filtered, not trusted verbatim ---------
# Reject direction of the same recovery branch: a corrupted/tampered stale checkpoint
# carries non-integer and non-positive entries. Only Number.isInteger(n) && n > 0
# survives — "693" is a decoy that IS fetchable, so dropping the filter would fetch it.
setup_case wid-c14b
mock_issue 692 OPEN "type:task"
mock_issue 693 OPEN "type:task"
STALE_CKPT="$PLANS/wid-c14b-wi-checkpoint.json"
node -e '
const fs = require("fs");
const path = require("path");
const p = process.argv[1];
fs.mkdirSync(path.dirname(p), { recursive: true });
fs.writeFileSync(p, JSON.stringify({
  version: 1,
  session_id: "wid-c14b",
  phase: "wip-check",
  ask_id: "wip_conflict",
  state: {
    issues: [692, "693", -1, 0, 9.5],
    repo_map: {},
    sid_pass: null,
    issue_json_cache: {},
    wip_results: { "692": "other" },
    label_sets: {},
    force_path_b: false,
    path_decision: null,
    adopt_candidate: null,
    adopt_decision: null,
    meta_select_offered: []
  }
}));
' "$STALE_CKPT"
C14B_B693="$(count_gh_calls 'issue view #?693')"
run_driver --resume "$STALE_CKPT" --answer continue
assert_kv "C14b: token-less restart on a poisoned stale checkpoint completes → done" ACTION done
CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "C14b: only the positive-integer entry recovered" "$CKPT2" state.issues "[692]"
C14B_A693="$(count_gh_calls 'issue view #?693')"
if [ "$C14B_A693" = "$C14B_B693" ]; then
    pass "C14b: string entry \"693\" never became a fetched issue ($C14B_B693 → $C14B_A693)"
else
    fail "C14b: string entry \"693\" was recovered and fetched ($C14B_B693 → $C14B_A693)"
fi
teardown_case
finish
