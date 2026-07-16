#!/bin/bash
# tests/feature-workflow-init-driver/driver-wip.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/wip-check.js
# Tags: workflow-init, driver, wip-check, scope:issue-specific
#
# WP1-WP7 — WIP aggregation branch tests (TDD red phase: driver not yet implemented).
#
# L3 gap (what this test does NOT catch):
# - Real wip-state.sh writes propagating to a live Projects v2 board (GraphQL).
# - A real `claude -p` session dispatching on the driver's ask_user directives.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# --- WP1: single issue wip=none → wip-state set invoked → done -----------------
# Regression — ALL_NONE unreachable bug: the retired
# skills/workflow-init/scripts/aggregate-wip-check.sh (old L92-102) evaluated
# ALL_SAME before ALL_NONE, so a single-issue session with wip=none printed
# "ALL_SAME none"; SKILL.md read that as "session already owns WIP" and never
# invoked wip-set — WIP was silently never claimed. The driver's wip-check phase
# must evaluate: error → any_other → all_none → all_same → mixed (plan Step 6).
setup_case wid-wp1
mock_issue 400 OPEN "type:task,intent:clarified"
# wip state intentionally unset → mock 'check' returns default 'none'
run_driver '#400'
assert_kv "WP1: single wip=none → ACTION=done" ACTION done
if wip_set_calls | grep -q '^set 400$'; then
    pass "WP1: wip-state 'set 400' invoked (ALL_NONE branch reached, bug regressed)"
else
    fail "WP1: wip-state set NOT invoked for #400 (old ALL_SAME-none eval-order bug); calls=[$(wip_set_calls | tr '\n' ';')]"
fi
teardown_case

# --- WP2: single issue wip=same → no set call → done ---------------------------
setup_case wid-wp2
mock_issue 401 OPEN "type:task"
set_wip 401 same
run_driver '#401'
assert_kv "WP2: single wip=same → ACTION=done" ACTION done
if [ -z "$(wip_set_calls)" ]; then
    pass "WP2: no wip-state set call for already-owned issue"
else
    fail "WP2: unexpected set calls: [$(wip_set_calls | tr '\n' ';')]"
fi
teardown_case

# --- WP3: two issues both wip=none → set called for both -----------------------
setup_case wid-wp3
mock_issue 402 OPEN "type:task"
mock_issue 403 OPEN "type:task"
run_driver '#402' '#403'
assert_kv "WP3: two wip=none issues → ACTION=done" ACTION done
if wip_set_calls | grep -q '^set 402$' && wip_set_calls | grep -q '^set 403$'; then
    pass "WP3: wip-state set invoked for both #402 and #403"
else
    fail "WP3: missing set call(s); calls=[$(wip_set_calls | tr '\n' ';')]"
fi
teardown_case

# --- WP4: mixed none+same → set called only for the none one -------------------
setup_case wid-wp4
mock_issue 404 OPEN "type:task"
mock_issue 405 OPEN "type:task"
set_wip 405 same
run_driver '#404' '#405'
assert_kv "WP4: mixed none+same → ACTION=done" ACTION done
if wip_set_calls | grep -q '^set 404$' && ! wip_set_calls | grep -q '^set 405$'; then
    pass "WP4: wip-state set invoked only for the wip=none issue (#404)"
else
    fail "WP4: wrong set-call set; calls=[$(wip_set_calls | tr '\n' ';')]"
fi
teardown_case

# --- WP5: any wip=other → ask_user wip_conflict ---------------------------------
setup_case wid-wp5
mock_issue 406 OPEN "type:task"
set_wip 406 other
run_driver '#406'
assert_kv "WP5: wip=other → ACTION=ask_user" ACTION ask_user
assert_kv "WP5: wip=other → ASK_ID=wip_conflict" ASK_ID wip_conflict
if [ -z "$(wip_set_calls)" ]; then
    pass "WP5: no set call before the user answers the conflict ask"
else
    fail "WP5: premature set calls before answer: [$(wip_set_calls | tr '\n' ';')]"
fi
teardown_case

# --- WP6: wip-state check error rc → ask_user wip_error --------------------------
setup_case wid-wp6
mock_issue 407 OPEN "type:task"
set_wip_check_rc 1
run_driver '#407'
assert_kv "WP6: wip-state check error → ACTION=ask_user" ACTION ask_user
assert_kv "WP6: wip-state check error → ASK_ID=wip_error" ASK_ID wip_error
teardown_case

# --- WP7: wip-state set rc=2 → ask_user wip_rc2 ----------------------------------
setup_case wid-wp7
mock_issue 408 OPEN "type:task"
# wip=none (default) so the set path is attempted; force set to fail with rc=2
set_wip_set_rc 2
run_driver '#408'
assert_kv "WP7: wip-state set rc=2 → ACTION=ask_user" ACTION ask_user
assert_kv "WP7: wip-state set rc=2 → ASK_ID=wip_rc2" ASK_ID wip_rc2
teardown_case

finish
