#!/bin/bash
# tests/feature-workflow-init-driver/driver-wip-continuation.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/wip-check.js, bin/workflow/lib/workflow-init/phases/fetch-issues.js
# Tags: workflow-init, driver, wip-check, checkpoint-resume, continuation, scope:issue-specific

# WP10-WP15 — what happens AFTER the user answers `continue`, continuing the WP series of
# driver-wip.sh (WP1-WP9, which stops at the ask). Separated (CPR-SC): the state an
# override leaves behind (WP10-WP13) vs how an unexpected wip-state.sh result lands (WP14-15).

# TL3 gap: no real `claude -p` ask → --resume round-trip, and no real wip-state.sh against
# a live Projects v2 board (rc=1/rc=2 and an unrecognized `check` stdout are mocked here).
# Mitigated at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# --- WP10: wip_conflict + continue — the override is LOCAL, no set is issued -------
# The review premise was that `continue` claims ownership of every overridden issue via
# `wip-state.sh set`. It does not: applyAnswer writes wip_results[n]="same" for every
# issue, so wip-check's none-set is empty and its set loop is never entered.

# Pinned as the contract because the two readings are observationally opposite:
# "override and continue" here means proceed without disturbing the other session's
# record, not seize it. A change that started issuing `set` would silently overwrite
# another session's WIP ownership — exactly what #2087's phase reorder set out to stop.
setup_case wid-wp10
mock_issue 900 OPEN "type:task"
mock_issue 901 OPEN "type:task"
set_wip 900 other
run_driver '#900' '#901'
assert_kv "WP10: an issue owned elsewhere interrupts at wip_conflict" ASK_ID wip_conflict
WP10_CKPT="$(get_kv CHECKPOINT)" || true
run_driver --resume "$WP10_CKPT" --answer continue
assert_kv "WP10: continue completes the pipeline → ACTION=done" ACTION done
if [ -z "$(wip_set_calls)" ]; then
    pass "WP10: no wip-state 'set' issued — the other session's ownership record is untouched"
else
    fail "WP10: continue issued set call(s), seizing another session's WIP: [$(wip_set_calls | tr '\n' ';')]"
fi
WP10_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "WP10: EVERY issue is overridden to 'same', not just the conflicted one" "$WP10_CKPT2" \
    state.wip_results '{"900":"same","901":"same"}'
assert_ckpt "WP10: a local override never raises force_path_b (no set ran)" "$WP10_CKPT2" state.force_path_b false
teardown_case

# --- WP11a: wip_rc2 + continue, contention GONE — the set is retried and succeeds ----
# The documented "proceed" verdict. applyAnswer resets every non-'same' result to 'none',
# so wip-check re-enters its set loop; with the rc=2 condition cleared the claim lands
# and the session routes normally instead of re-asking.
setup_case wid-wp11a
mock_issue 910 OPEN "type:task"
set_wip_set_rc 2
run_driver '#910'
assert_kv "WP11a: rc=2 on the first claim interrupts at wip_rc2" ASK_ID wip_rc2
WP11A_CKPT="$(get_kv CHECKPOINT)" || true
set_wip_set_rc 0   # the competing session released the issue before the user answered
run_driver --resume "$WP11A_CKPT" --answer continue
assert_kv "WP11a: continue reaches the proceed verdict, not another ask" ACTION done
assert_kv "WP11a: the resumed session routes normally → PATH_DECISION=B" PATH_DECISION B
WP11A_SETS="$(wip_set_calls | grep -c '^set 910$' || true)"
if [ "$WP11A_SETS" -ge 2 ] 2>/dev/null; then
    pass "WP11a: the claim was actually retried after the answer ($WP11A_SETS set calls)"
else
    fail "WP11a: continue completed without re-issuing set — ownership never claimed (sets=$WP11A_SETS)"
fi
WP11A_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "WP11a: the retried claim is recorded as owned by this session" "$WP11A_CKPT2" \
    state.wip_results '{"910":"same"}'
teardown_case

# --- WP11b: wip_rc2 + continue, contention PERSISTS — re-asked, never silently proceeded
# CPR-ORTH reject arm of WP11a. rc=2 is a live fact about another session, so a second
# failing claim surfaces as the same ask again — the alternative (accept the answer and
# continue) would report ownership the session does not hold.
setup_case wid-wp11b
mock_issue 911 OPEN "type:task"
set_wip_set_rc 2
run_driver '#911'
assert_kv "WP11b: rc=2 interrupts at wip_rc2" ASK_ID wip_rc2
WP11B_CKPT="$(get_kv CHECKPOINT)" || true
run_driver --resume "$WP11B_CKPT" --answer continue
assert_kv "WP11b: a still-failing claim re-asks instead of proceeding" ACTION ask_user
assert_kv "WP11b: the re-raised ask is the same wip_rc2 gate" ASK_ID wip_rc2
assert_single_action_line "WP11b: the re-raised ask emits exactly one ACTION= line"
if printf '%s\n' "$DRIVER_OUT" | grep -q '^PATH_DECISION='; then
    fail "WP11b: the session was routed despite an unclaimed issue"
else
    pass "WP11b: no PATH_DECISION emitted while the claim is still unresolved"
fi
WP11B_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "WP11b: a failed claim is never recorded as owned" "$WP11B_CKPT2" \
    state.wip_results '{"911":"none"}'
teardown_case

# --- WP12: wip_error + continue — "treat as unowned" really does claim the issue -----
# Unlike WP10 that promise implies a claim: applyAnswer rewrites only the 'error' results
# to 'none', so wip-check's set loop runs. Asserting only ACTION=done would pass even if
# the set were dropped and the session ran with no WIP record at all.
setup_case wid-wp12
mock_issue 920 OPEN "type:task"
set_wip_check_rc 1
run_driver '#920'
assert_kv "WP12: a failing wip-state check interrupts at wip_error" ASK_ID wip_error
WP12_CKPT="$(get_kv CHECKPOINT)" || true
set_wip_check_rc 0   # the transient check failure clears; the claim itself is untouched
run_driver --resume "$WP12_CKPT" --answer continue
assert_kv "WP12: continue reaches the proceed verdict, not another ask" ACTION done
if wip_set_calls | grep -q '^set 920$'; then
    pass "WP12: the issue treated as unowned was actually claimed via wip-state set"
else
    fail "WP12: no set call for #920 — 'treat as unowned' left no WIP record: [$(wip_calls | tr '\n' ';')]"
fi
WP12_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "WP12: the claimed issue is recorded as owned by this session" "$WP12_CKPT2" \
    state.wip_results '{"920":"same"}'
assert_ckpt "WP12: an all-none claim raises force_path_b" "$WP12_CKPT2" state.force_path_b true
teardown_case

# --- WP13: fetch_failed_path_c + continue — the issue is DROPPED, not carried -------
# The third continue-shaped ask, and the one whose answer discards state rather than
# rewriting it: state.issues is emptied and the pipeline re-enters at write-context. A
# residual issue number would be re-fetched later and re-raise the ask just dismissed.
setup_case wid-wp13
mock_issue 930 OPEN "type:task"
mock_issue_rc 930 1
run_driver '#930'
assert_kv "WP13: an unfetchable issue interrupts at fetch_failed_path_c" ASK_ID fetch_failed_path_c
WP13_CKPT="$(get_kv CHECKPOINT)" || true
WP13_BEFORE="$(count_gh_calls 'issue view #?930')"
run_driver --resume "$WP13_CKPT" --answer continue
assert_kv "WP13: continue reaches the proceed verdict, not another ask" ACTION done
assert_kv "WP13: the issue-less session routes to Path C" PATH_DECISION C
WP13_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "WP13: the unfetchable issue is dropped from state.issues" "$WP13_CKPT2" state.issues "[]"
WP13_AFTER="$(count_gh_calls 'issue view #?930')"
if [ "$WP13_AFTER" = "$WP13_BEFORE" ]; then
    pass "WP13: the dismissed issue was not re-fetched ($WP13_BEFORE → $WP13_AFTER)"
else
    fail "WP13: the dismissed issue was fetched again ($WP13_BEFORE → $WP13_AFTER)"
fi
if [ -z "$(wip_calls)" ]; then
    pass "WP13: no wip-state.sh call for an issue that left the session"
else
    fail "WP13: wip-state.sh ran for a dropped issue: [$(wip_calls | tr '\n' ';')]"
fi
teardown_case

# --- WP14: `wip-state.sh set` rc=1 — an unexpected exit code, neither rc=0 nor rc=2 --
# wip-check discriminates only rc=2 (ask) and rc=0 (record 'same'); every other exit code
# falls through. The invariant asserted here holds either way: an issue whose claim did
# not succeed is never recorded as owned. That the session still completes on such a code
# is current behavior, deliberately not asserted as desirable.
setup_case wid-wp14
mock_issue 940 OPEN "type:task"
set_wip_set_rc 1
run_driver '#940'
if wip_set_calls | grep -q '^set 940$'; then
    pass "WP14: the claim was attempted (the rc=1 arm is genuinely exercised)"
else
    fail "WP14: no set call for #940 — the rc=1 arm was never reached: [$(wip_calls | tr '\n' ';')]"
fi
WP14_CKPT="$(get_kv CHECKPOINT)" || true
WP14_RESULTS="$(ckpt_get "$WP14_CKPT" state.wip_results)"
case "$WP14_RESULTS" in
    *'"same"'*) fail "WP14: a failed claim (rc=1) was recorded as owned by this session: $WP14_RESULTS" ;;
    *) pass "WP14: a failed claim (rc=1) is never recorded as 'same': $WP14_RESULTS" ;;
esac
teardown_case

# --- WP15: `wip-state.sh check` exits 0 with an UNRECOGNIZED value -------------------
# The vocabulary is none|same|other; anything else (a future verb, a stray banner line) is
# stored verbatim, matches none of wip-check's three filters, and is absorbed into the
# all-'same' arm — no claim, no conflict ask. Asserted here is the fix-neutral safety
# half: an unknown value must not be laundered into a 'same' ownership record.
setup_case wid-wp15
mock_issue 950 OPEN "type:task"
set_wip 950 bogus-value
run_driver '#950'
if wip_calls | grep -q '^check 950$'; then
    pass "WP15: the unrecognized value really came from a wip-state check call"
else
    fail "WP15: no check call for #950 — the unrecognized-value arm was never reached"
fi
WP15_CKPT="$(get_kv CHECKPOINT)" || true
WP15_RESULTS="$(ckpt_get "$WP15_CKPT" state.wip_results)"
case "$WP15_RESULTS" in
    *'"same"'*) fail "WP15: an unrecognized check value was laundered into a 'same' record: $WP15_RESULTS" ;;
    *) pass "WP15: an unrecognized check value is not recorded as owned: $WP15_RESULTS" ;;
esac
if [ -n "$(wip_set_calls)" ]; then
    fail "WP15: an unrecognized check value triggered a claim: [$(wip_set_calls | tr '\n' ';')]"
else
    pass "WP15: an unrecognized check value triggers no claim"
fi
teardown_case

finish
