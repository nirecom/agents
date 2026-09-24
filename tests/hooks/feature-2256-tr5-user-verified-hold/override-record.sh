#!/usr/bin/env bash
# tests/feature-2256-tr5-user-verified-hold/override-record.sh
# Tests: bin/supervisor-record-block-override, hooks/workflow-gate.js
# Tags: supervisor, tr5, block-override, cli, TL2, scope:issue-specific
# #2256 S5-d — recording a human BLOCK override, and everything that invalidates it.

# Parent: tests/feature-2256-tr5-user-verified-hold.sh

# The CLI shape pinned here mirrors its only sibling, bin/supervisor-write-audit-verdict:
# positional arguments first, then an optional --session-id <sid>. If the implementation
# lands on a different flag spelling, change this helper — not the assertions around it.

set -uo pipefail
# shellcheck source=./_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

REASON_OK="verified manually with the reviewer; the BLOCK is a false positive here"
REASON_SHORT="too short"

# record <run-id> <reason> — prints the exit code; stderr is folded into stdout on demand.
record() {
    bash "$RWT" 60 node "$OVERRIDE_BIN" "$1" "$2" --session-id "$SID" >/dev/null 2>&1
    printf '%s' "$?"
}
record_err() {
    bash "$RWT" 60 node "$OVERRIDE_BIN" "$1" "$2" --session-id "$SID" 2>&1
}
findings_json() {
    WR="$WRITER_NODE" SESS="$SID" node -e "
const w = require(process.env.WR);
let s; try { s = w.readState(process.env.SESS); } catch (e) { s = null; }
const f = (s && s.layer1 && s.layer1.findings) || [];
process.stdout.write(JSON.stringify(f));
" 2>&1
}

# --- 1-2: the CLI must exist at all ---
if [ -f "$OVERRIDE_BIN" ]; then pass "1: bin/supervisor-record-block-override exists"; else
    fail "1: bin/supervisor-record-block-override exists" "missing: $OVERRIDE_BIN"; fi
seed_state "$(terminal_run BLOCK "$(fresh_key)")" >/dev/null
assert_eq "2: a valid override is accepted" "$(record run-0011 "$REASON_OK")" "0"

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

# --- 11-13: a reason under 20 characters is refused with exit 2 ---
seed_state "$(terminal_run BLOCK "$(fresh_key)")" >/dev/null
assert_eq "11: a reason under 20 characters exits 2" "$(record run-0011 "$REASON_SHORT")" "2"
assert_eq "12: the refused override records nothing" "$(state_field audit.block_overrides)" "[]"
assert_match "13: the refusal explains the reason-length requirement" \
    "$(record_err run-0011 "$REASON_SHORT")" '20'

# --- 14-15: a run id that is not the last terminal run is refused with exit 2 ---
assert_eq "14: a mismatching run id exits 2" "$(record run-0099 "$REASON_OK")" "2"
assert_eq "15: the mismatching override records nothing" "$(state_field audit.block_overrides)" "[]"

# --- 16-17: the last terminal run must actually be a BLOCK ---
seed_state "$(terminal_run CONTINUE "$(fresh_key)")" >/dev/null
assert_eq "16: overriding a non-BLOCK verdict exits 2" "$(record run-0011 "$REASON_OK")" "2"
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
# Guards user-verified-audit.js:181 (`!laterBlockExists` in the override branch).
# Case 9 proved a TR5-scoped override releases the hold when the TR5 run is the
# only terminal entry. A later, independent TR6 BLOCK is a run the TR5 override
# never speaks to: releasing over it would bypass that BLOCK. Record the override
# through the real CLI on the single-entry ledger, then seed a two-entry ledger
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
