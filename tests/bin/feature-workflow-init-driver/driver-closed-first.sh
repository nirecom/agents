#!/bin/bash
# tests/feature-workflow-init-driver/driver-closed-first.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/closed-detection.js, bin/workflow/lib/workflow-init/phases/meta-classify.js, bin/workflow/lib/workflow-init/phases/wip-check.js
# Tags: workflow-init, driver, routing, closed-detection, phase-order, scope:issue-specific

# R16-R19 — the PHASE_ORDER reorder (#2087) seen from the CLOSED gate: it fires
# before classification and before wip-check, and the phases it preempts still run
# once it is answered. Continues the R series of driver-routing.sh (R1-R15).

# TL3 gap: no real `claude -p` ask_user round-trip; answers are replayed through
# --resume/--answer. Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# --- R16: a CLOSED meta parent is gated before it is classified ---------------------
# Whether a closed issue is even part of this session is unsettled, so listing its
# sub-issues is work done on the user's behalf that they may be about to discard —
# and a meta_select ask would offer children of an issue the user is about to drop.
setup_case wid-r16
mock_issue 500 CLOSED "meta"
mock_issue 501 OPEN "type:task"
set_wip 501 same
mock_sub_issues 500 '[{"number":501,"title":"Child of 500","state":"open"}]'
run_driver '#500'
assert_kv "R16: a closed meta parent asks the closed gate first" ASK_ID closed_reopen_500
if grep -q "sub_issues" "$GH_LOG"; then
    fail "R16: sub-issues were listed for a closed, ungated parent: $(tr '\n' ';' < "$GH_LOG")"
else
    pass "R16: no sub-issue API call while the closed gate was pending"
fi
teardown_case

# --- R17: answering `reopen` lets wip-check run on the now-open issue ---------------
# The accept side of R16's suppression: the closed gate must PREEMPT the later
# phases, not cancel them. #510 is owned by another session, so wip-check's verdict
# is observable — a driver that resumed past wip-check would answer done.
setup_case wid-r17
mock_issue 510 CLOSED "type:task"
set_wip 510 other
run_driver '#510'
assert_kv "R17: closed + conflicted WIP still asks the closed gate first" ASK_ID closed_reopen_510
R17_CKPT="$(get_kv CHECKPOINT)" || true
run_driver --resume "$R17_CKPT" --answer reopen
assert_kv "R17: after reopen the pipeline continues to ask again" ACTION ask_user
assert_kv "R17: the preempted wip-check now runs and reports the conflict" ASK_ID wip_conflict
teardown_case

# --- R18: answering `remove` lets label-extract and meta-classify run ---------------
# The other answer of the same ask, over the phases R16 suppressed. Dropping #520
# leaves the meta parent #521 alone in the session, so classification must run on
# the re-entry and raise meta_select for its open child.
setup_case wid-r18
mock_issue 520 CLOSED "type:task"
mock_issue 521 OPEN "meta"
mock_issue 522 OPEN "type:task"
set_wip 522 same
mock_sub_issues 521 '[{"number":522,"title":"Child of 521","state":"open"}]'
run_driver '#520' '#521'
assert_kv "R18: the closed member gates the whole session" ASK_ID closed_reopen_520
R18_CKPT="$(get_kv CHECKPOINT)" || true
run_driver --resume "$R18_CKPT" --answer remove
assert_kv "R18: after remove, meta-classify runs on the remainder" ASK_ID meta_select
R18_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "R18: the removed issue is gone from the session" "$R18_CKPT2" state.issues "[521]"
assert_ckpt "R18: label-extract ran on the remainder" "$R18_CKPT2" state.label_sets.521 '["meta"]'
teardown_case

# --- R19: `remove` that empties the session blocks instead of routing ---------------
# Edge case of the same answer: closed-detection re-entry has nothing left to gate,
# so the driver must stop rather than fall through to a Path decision on zero issues.
setup_case wid-r19
mock_issue 530 CLOSED "type:task"
run_driver '#530'
assert_kv "R19: the only issue being closed raises the gate" ASK_ID closed_reopen_530
R19_CKPT="$(get_kv CHECKPOINT)" || true
run_driver --resume "$R19_CKPT" --answer remove
assert_kv "R19: removing the last issue blocks the session" ACTION blocked
assert_kv "R19: blocked with reason no_issues_remaining" REASON no_issues_remaining
teardown_case

finish
