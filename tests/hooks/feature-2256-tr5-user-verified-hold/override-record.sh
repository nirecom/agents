#!/usr/bin/env bash
# tests/hooks/feature-2256-tr5-user-verified-hold/override-record.sh
# Tests: hooks/lib/supervisor-block-override.js, hooks/workflow-mark/supervisor-block-override-handler.js, hooks/workflow-gate.js
# Tags: supervisor, tr5, block-override, cli, TL2, scope:issue-specific
# #2256 S5-d — recording a human BLOCK override, and everything that invalidates it.

# Parent: tests/hooks/feature-2256-tr5-user-verified-hold.sh

# #2709: the override is recorded through the ask-gated sentinel handler
# (override_via_handler in _common.sh); the CLI is gone. A refusal is no longer an exit
# code — it is "nothing recorded" plus the pushed message.

set -uo pipefail

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT
# shellcheck source=./_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

REASON_OK="verified manually with the reviewer; the BLOCK is a false positive here"
REASON_SHORT="too short"

# record <run-id> <reason> — prints "recorded" when block_overrides grew, else "refused".
record() {
    local before after
    before="$(state_field audit.block_overrides)"
    override_via_handler "$1" "$2" >/dev/null
    after="$(state_field audit.block_overrides)"
    if [ "$before" != "$after" ]; then printf 'recorded'; else printf 'refused'; fi
}
record_err() {
    override_via_handler "$1" "$2"
}
findings_json() {
    WR="$WRITER_NODE" SESS="$SID" node -e "
const w = require(process.env.WR);
let s; try { s = w.readState(process.env.SESS); } catch (e) { s = null; }
const f = (s && s.layer1 && s.layer1.findings) || [];
process.stdout.write(JSON.stringify(f));
" 2>&1
}

# --- 1-2: the handler is the write path; the un-gated CLI is gone ---
if [ -f "$OVERRIDE_HANDLER_NODE" ]; then pass "1: the override sentinel handler exists"; else
    fail "1: the override sentinel handler exists" "missing: $OVERRIDE_HANDLER_NODE"; fi
if [ -e "$__COMMON_SCRIPT_CHECKOUT_ROOT/bin/supervisor-record-block-override" ]; then
    fail "1b: bin/supervisor-record-block-override is removed" "still present"; else
    pass "1b: bin/supervisor-record-block-override is removed"; fi
seed_state "$(terminal_run BLOCK "$(fresh_key)")" >/dev/null
assert_eq "2: a valid override is accepted" "$(record run-0011 "$REASON_OK")" "recorded"

# --- 3-5: the accepted record carries run id, freshness key, reason and actor ---
assert_eq "3: the record names the overridden run" "$(state_field audit.block_overrides.0.run_id)" "run-0011"
assert_eq "4: the record pins the freshness key it was taken against" \
    "$(state_field audit.block_overrides.0.freshness_key)" "$(fresh_key)"
assert_eq "5: the record keeps the operator's reason verbatim" \
    "$(state_field audit.block_overrides.0.reason)" "$REASON_OK"
assert_ne "6: the record names an actor" "$(state_field audit.block_overrides.0.actor)" "none"
assert_ne "7: the record is timestamped" "$(state_field audit.block_overrides.0.recorded_at)" "none"

# --- 8: recording emits a warning finding so the override is never silent ---
assert_match "8: a warning finding records the override" "$(findings_json)" '"severity":"warning"'

# --- 9-10: with the override in place the hold is released ---
out="$(gate "$SENTINEL_UV")"
assert_eq "9: the recorded override releases the TR5 hold" "$(decision_of "$out")" "approve"
assert_eq "10: releasing the hold arms no audit run" "$(state_field audit.audit_phase)" "null"

# --- 11-13: a reason under 20 characters is refused ---
seed_state "$(terminal_run BLOCK "$(fresh_key)")" >/dev/null
assert_eq "11: a reason under 20 characters is refused" "$(record run-0011 "$REASON_SHORT")" "refused"
assert_eq "12: the refused override records nothing" "$(state_field audit.block_overrides)" "[]"
assert_match "13: the refusal explains the reason-length requirement" \
    "$(record_err run-0011 "$REASON_SHORT")" '20'

# --- 14-15: a run id that is not the last terminal run is refused ---
assert_eq "14: a mismatching run id is refused" "$(record run-0099 "$REASON_OK")" "refused"
assert_eq "15: the mismatching override records nothing" "$(state_field audit.block_overrides)" "[]"

# --- 16-17: the last terminal run must actually be a BLOCK ---
seed_state "$(terminal_run CONTINUE "$(fresh_key)")" >/dev/null
assert_eq "16: overriding a non-BLOCK verdict is refused" "$(record run-0011 "$REASON_OK")" "refused"
assert_eq "17: overriding a non-BLOCK verdict records nothing" "$(state_field audit.block_overrides)" "[]"

# --- 18-20: a code diff after the override invalidates it ---
seed_state "$(terminal_run BLOCK "$(fresh_key)")" >/dev/null
record run-0011 "$REASON_OK" >/dev/null
printf 'changed by the developer after the override\n' > "$REPO/seed.txt"
assert_ne "18: the code change moves the freshness key" \
    "$(fresh_key)" "$(state_field audit.block_overrides.0.freshness_key)"
out="$(gate "$SENTINEL_UV")"
assert_ne "19: a code diff invalidates the override" "$(decision_of "$out")" "approve"
assert_match "20: the invalidated override re-arms an audit run" \
    "$(state_field audit.audit_run_id)" '^run-[0-9]{4}$'
printf 'seed\n' > "$REPO/seed.txt"

# --- 21-23: C1 — a plan-artifact-only edit invalidates the override too ---
seed_state "$(terminal_run BLOCK "$(fresh_key)")" >/dev/null
record run-0011 "$REASON_OK" >/dev/null
assert_eq "21: the override holds while nothing has moved" \
    "$(decision_of "$(gate "$SENTINEL_UV")")" "approve"
write_plans i1 o1 "$DETAIL_BODY
- override-invalidator.txt
"
out="$(gate "$SENTINEL_UV")"
assert_ne "22: a detail.md-only edit invalidates the override (C1)" "$(decision_of "$out")" "approve"
assert_match "23: the plan edit re-arms an audit run" \
    "$(state_field audit.audit_run_id)" '^run-[0-9]{4}$'
write_plans

# --- 24-26: a valid TR5 override does NOT release a later TR6 BLOCK ---
# Guards checkUserVerifiedAudit's Stage 1 override branch (`!laterBlockExists` guard).
# Case 9 proved a TR5-scoped override releases the hold when the TR5 run is the
# only terminal entry. A later, independent TR6 BLOCK is a run the TR5 override
# never speaks to: releasing over it would bypass that BLOCK. Record the override
# through the real handler on the single-entry ledger, then seed a two-entry ledger
# that keeps that same override alongside a later TR6 BLOCK. Deleting
# `!laterBlockExists &&` at line 181 makes case 24 approve.
FK_OV="$(fresh_key)"
seed_state "$(terminal_run BLOCK "$FK_OV")" >/dev/null
record run-0011 "$REASON_OK" >/dev/null
OV="$(state_field audit.block_overrides)"
seed_state "$(two_terminal_runs BLOCK "$FK_OV" BLOCK "$OV")" >/dev/null
out="$(gate "$SENTINEL_UV")"
assert_ne "24: a TR5-scoped override does not release a later TR6 BLOCK" \
    "$(decision_of "$out")" "approve"
assert_match "25: the override is preserved in state (the guard, not a lost record, blocks)" \
    "$OV" '"run_id":"run-0011"'
assert_match "26: the deny cites the unresolved BLOCK, not a missing override" \
    "$(reason_of "$out")" 'BLOCK'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
