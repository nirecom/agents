#!/bin/bash
# tests/feature-workflow-init-driver/driver-wip.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/wip-check.js
# Tags: workflow-init, driver, wip-check, scope:issue-specific
#
# WP1-WP7 — WIP aggregation branch tests; WP8-WP9 — #2087 phase-order effects
# (meta-issue label filter, closed-gate precedence).
#
# TL3 gap: no live Projects v2 board writes, no real `claude -p` ask_user
# round-trip. Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

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

# --- probe harness (mirrors driver-meta-classify.sh's probe()) -----------------
# wipCheck(state, agentsConfigDir, sessionId) spawns the mocked wip-state.sh, so
# $CFG/$SID ride the extra argv. See driver-meta-classify.sh for the base pattern.
WIP_MOD="$AGENTS_DIR/bin/workflow/lib/workflow-init/phases/wip-check.js"
probe() {  # <module-path> [extra argv...]; snippet on stdin → PROBE_OUT/PROBE_RC/PROBE_ERR
    local mod="$1"; shift
    cat > "$CASE_DIR/probe.js"
    PROBE_OUT="$(cd "$CASE_DIR" && node "$CASE_DIR/probe.js" "$mod" "$@" 2>"$CASE_DIR/probe.err")"
    PROBE_RC=$?
    PROBE_ERR=""
    [ -f "$CASE_DIR/probe.err" ] && PROBE_ERR="$(cat "$CASE_DIR/probe.err")"
}
assert_probe() {  # <label> <expected-exact-line>
    if printf '%s\n' "$PROBE_OUT" | grep -qxF -- "$2"; then
        pass "$1"
    else
        fail "$1: want line '$2'; got '$(printf '%s' "$PROBE_OUT" | tr '\n' ';')' (rc=$PROBE_RC err='$(printf '%s' "$PROBE_ERR" | head -c 200)')"
    fi
}

# --- WP8a: mixed input, meta filtered locally — #250 (meta) untouched, #251 set --
# detail.md Step 9/2: state.issues carries BOTH (post-meta-classify META shape,
# see M5) — wip-check filters #250 via state.label_sets, never touching it.
setup_case wid-wp8a
probe "$WIP_MOD" "$CFG" "$SID" <<'NODE'
const { wipCheck } = require(process.argv[2]);
const state = { issues: [250, 251], label_sets: { 250: ["meta"], 251: ["type:task"] }, wip_results: {} };
const r = wipCheck(state, process.argv[3], process.argv[4]) || {};
console.log("ask=" + JSON.stringify(!!r.ask));
console.log("force_path_b=" + JSON.stringify(!!state.force_path_b));
NODE
if wip_calls | grep -qE '^(check|set) 250$'; then
    fail "WP8a: wip-state.sh touched the meta-labelled issue #250: $(wip_calls | tr '\n' ';')"
else
    pass "WP8a: wip-state.sh never invoked for the meta-labelled issue #250"
fi
if wip_set_calls | grep -q '^set 251$'; then
    pass "WP8a: wip-state set invoked for the non-meta issue #251"
else
    fail "WP8a: missing set call for #251; calls=[$(wip_calls | tr '\n' ';')]"
fi
teardown_case

# --- WP8b: all-meta input — filtered local set is EMPTY → no-op, no force_path_b --
# Mirrors driver-routing.sh R14/R15: an all-meta state.issues (never stripped,
# see M5) must not reach wip-state.sh and must not raise force_path_b (M11/M20).
setup_case wid-wp8b
probe "$WIP_MOD" "$CFG" "$SID" <<'NODE'
const { wipCheck } = require(process.argv[2]);
const state = { issues: [250], label_sets: { 250: ["meta"] }, wip_results: {} };
const r = wipCheck(state, process.argv[3], process.argv[4]) || {};
console.log("ask=" + JSON.stringify(!!r.ask));
console.log("force_path_b=" + JSON.stringify(!!state.force_path_b));
NODE
if [ -n "$(wip_calls)" ]; then
    fail "WP8b: wip-state.sh touched an all-meta issue set: $(wip_calls | tr '\n' ';')"
else
    pass "WP8b: wip-state.sh never invoked for an all-meta issue set"
fi
assert_probe "WP8b: force_path_b stays false for an all-meta working set" "force_path_b=false"
teardown_case

# --- WP9: a pending CLOSED gate suppresses wip-check entirely (#2087) -------------
# closed-detection now precedes wip-check in PHASE_ORDER. An issue whose very
# membership in the session is still unresolved must not have its WIP inspected —
# and must certainly not have ownership claimed — while the user is still being
# asked whether to reopen or drop it. #460 is owned by ANOTHER session, so under
# the old order this run answered wip_conflict instead of the closed gate.
setup_case wid-wp9
mock_issue 460 CLOSED "type:task"
set_wip 460 other
run_driver '#460'
assert_kv "WP9: a closed issue asks the closed gate, not wip_conflict" ASK_ID closed_reopen_460
if [ -n "$(wip_calls)" ]; then
    fail "WP9: wip-state.sh ran while the closed gate was still pending: $(wip_calls | tr '\n' ';')"
else
    pass "WP9: wip-state.sh never invoked while the closed gate was pending"
fi
teardown_case

finish
