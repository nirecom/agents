#!/bin/bash
# tests/feature-workflow-init-driver/driver-routing.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/detect-issues.js, bin/workflow/lib/workflow-init/phases/fetch-issues.js, bin/workflow/lib/workflow-init/phases/wip-check.js, bin/workflow/lib/workflow-init/phases/closed-detection.js, bin/workflow/lib/workflow-init/phases/label-extract.js, bin/workflow/lib/workflow-init/phases/route-decision.js, bin/workflow/lib/workflow-init/phases/write-context.js
# Tags: workflow-init, driver, routing, directive-contract, scope:issue-specific
#
# R1-R11 — routing branch tests (TDD red phase: driver not yet implemented).
#
# L3 gap (what this test does NOT catch):
# - A real `claude -p` session driving the workflow-init SKILL.md driver loop
#   (ACTION= dispatch, AskUserQuestion rendering, --resume re-invocation).
# - Real gh calls (issue view / sub_issues endpoint / Projects v2) on live GitHub.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# --- R1: zero issue tokens → full pipeline → done / Path C + context.md -------
# Asserts no early-jump semantics: write-context (WI-9) must run for Path C too.
setup_case wid-r1
run_driver
assert_kv "R1: zero issues → ACTION=done" ACTION done
assert_kv "R1: zero issues → PATH_DECISION=C" PATH_DECISION C
if [ -f "$PLANS/wid-r1-context.md" ]; then
    pass "R1: context.md written under WORKFLOW_PLANS_DIR (write-context phase ran)"
else
    fail "R1: context.md missing at $PLANS/wid-r1-context.md (WI-3 early-jump regression?)"
fi
teardown_case

# --- R2: NON_GITHUB=1 → immediate done / Path C, no gh calls ------------------
setup_case wid-r2
export NON_GITHUB=1
run_driver
assert_kv "R2: NON_GITHUB=1 → ACTION=done" ACTION done
assert_kv "R2: NON_GITHUB=1 → PATH_DECISION=C" PATH_DECISION C
if [ ! -s "$GH_LOG" ]; then
    pass "R2: zero gh invocations under NON_GITHUB=1 (immediate return)"
else
    fail "R2: expected zero gh calls, got: $(tr '\n' ';' < "$GH_LOG")"
fi
teardown_case

# --- R3: one issue WITH intent:clarified → Path A ------------------------------
setup_case wid-r3
mock_issue 123 OPEN "type:task,intent:clarified"
set_wip 123 same
run_driver '#123'
assert_kv "R3: intent:clarified issue → ACTION=done" ACTION done
assert_kv "R3: intent:clarified issue → PATH_DECISION=A" PATH_DECISION A
teardown_case

# --- R4: one issue WITHOUT intent:clarified → Path B ---------------------------
setup_case wid-r4
mock_issue 124 OPEN "type:task"
set_wip 124 same
run_driver '#124'
assert_kv "R4: unclarified issue → ACTION=done" ACTION done
assert_kv "R4: unclarified issue → PATH_DECISION=B" PATH_DECISION B
teardown_case

# --- R5: all meta-labeled + no open sub-issues → Path META ---------------------
setup_case wid-r5
mock_issue 200 OPEN "meta"
set_wip 200 same
mock_sub_issues 200 '[]'
run_driver '#200'
assert_kv "R5: meta with no open children → ACTION=done" ACTION done
assert_kv "R5: meta with no open children → PATH_DECISION=META" PATH_DECISION META
teardown_case

# --- R6: meta + open sub-issues → ask_user meta_select --------------------------
setup_case wid-r6
mock_issue 201 OPEN "meta"
set_wip 201 same
mock_sub_issues 201 '[{"number":42,"title":"Open child","state":"open"}]'
run_driver '#201'
assert_kv "R6: meta with open children → ACTION=ask_user" ACTION ask_user
assert_kv "R6: meta with open children → ASK_ID=meta_select" ASK_ID meta_select
teardown_case

# --- R7: mixed meta/non-meta → meta stripped, remainder routed (B) --------------
setup_case wid-r7
mock_issue 210 OPEN "meta"
mock_issue 211 OPEN "type:task"
set_wip 210 same
set_wip 211 same
run_driver '#210' '#211'
assert_kv "R7: mixed meta/non-meta → ACTION=done" ACTION done
assert_kv "R7: mixed meta/non-meta → PATH_DECISION=B (non-meta remainder)" PATH_DECISION B
CKPT_R7="$(get_kv CHECKPOINT)" || true
assert_ckpt "R7: meta issue stripped from checkpoint state.issues" "$CKPT_R7" state.issues "[211]"
teardown_case

# --- R8: two issues → both retained in insertion order in checkpoint ------------
setup_case wid-r8
mock_issue 7 OPEN "type:task,intent:clarified"
mock_issue 9 OPEN "type:task,intent:clarified"
set_wip 7 same
set_wip 9 same
run_driver '#7' '#9'
assert_kv "R8: two issues → ACTION=done" ACTION done
CKPT_R8="$(get_kv CHECKPOINT)" || true
assert_ckpt "R8: checkpoint state.issues retains both in insertion order" "$CKPT_R8" state.issues "[7,9]"
teardown_case

# --- R9: gh issue view failure → ask_user fetch_failed_path_c -------------------
setup_case wid-r9
mock_issue_rc 300 1
run_driver '#300'
assert_kv "R9: fetch failure → ACTION=ask_user" ACTION ask_user
assert_kv "R9: fetch failure → ASK_ID=fetch_failed_path_c" ASK_ID fetch_failed_path_c
teardown_case

# --- R10: issue state CLOSED → ask_user closed_reopen_<N> ------------------------
setup_case wid-r10
mock_issue 301 CLOSED "type:task"
set_wip 301 same
run_driver '#301'
assert_kv "R10: CLOSED issue → ACTION=ask_user" ACTION ask_user
assert_kv "R10: CLOSED issue → ASK_ID=closed_reopen_301" ASK_ID closed_reopen_301
teardown_case

# --- R11: ALL_NONE + missing intent:clarified → force_path_b + Path B ------------
setup_case wid-r11
mock_issue 302 OPEN "type:task"
# wip state intentionally unset → mock 'check' returns default 'none' (ALL_NONE)
run_driver '#302'
assert_kv "R11: ALL_NONE unclarified → ACTION=done" ACTION done
assert_kv "R11: ALL_NONE unclarified → PATH_DECISION=B" PATH_DECISION B
CKPT_R11="$(get_kv CHECKPOINT)" || true
assert_ckpt "R11: checkpoint records force_path_b=true" "$CKPT_R11" state.force_path_b "true"
teardown_case

finish
