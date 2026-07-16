#!/bin/bash
# tests/feature-workflow-init-driver/driver-checkpoint-resume.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/checkpoint.js, bin/workflow/lib/workflow-init/phases/fetch-issues.js, bin/workflow/lib/workflow-init/phases/wip-check.js, bin/workflow/lib/workflow-init/phases/closed-detection.js, bin/workflow/lib/workflow-init/phases/route-decision.js
# Tags: workflow-init, driver, checkpoint-resume, scope:issue-specific
#
# C1-C9 — checkpoint persistence and --resume/--answer transition tests
# (TDD red phase: driver not yet implemented).
#
# L3 gap (what this test does NOT catch):
# - A real `claude -p` session performing the AskUserQuestion → --resume --answer
#   round-trip through the SKILL.md driver loop.
# - Real gh calls on live GitHub (issue view caching across process restarts).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

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
    detect-issues|fetch-issues|wip-check|closed-detection|label-extract|route-decision|write-context)
        pass "C1: phase field '$PH' is a known phase name" ;;
    *) fail "C1: phase field '$PH' is not a known phase name" ;;
esac
assert_ckpt "C1: ask_id recorded as wip_conflict" "$CKPT" ask_id wip_conflict
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

finish
