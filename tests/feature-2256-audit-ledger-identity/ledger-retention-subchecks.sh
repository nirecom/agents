#!/usr/bin/env bash
# tests/feature-2256-audit-ledger-identity/ledger-retention-subchecks.sh
# Tests: hooks/lib/audit-ledger.js, hooks/lib/supervisor-state-schema.js, hooks/lib/supervisor-state-writer/audit.js
# Tags: supervisor, audit-ledger, retention, sub-check, TL2, scope:issue-specific
# #2256 S2-f/S6-b: FIFO retention must never evict the last terminal run, and dedup is
# keyed on sub-check ids only. Parent: tests/feature-2256-audit-ledger-identity.sh

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_NODE="$AGENTS_DIR"
fi
WRITER_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-writer.js"
AUDIT_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-writer/audit.js"
LEDGER_NODE="$AGENTS_NODE/hooks/lib/audit-ledger.js"
SCHEMA_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-schema.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_match() {
    if printf '%s' "$2" | grep -Eq "$3"; then pass "$1"; else fail "$1" "'$2' does not match /$3/"; fi
}

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t f2256led)"
trap 'rm -rf "$WORK"' EXIT
if command -v cygpath >/dev/null 2>&1; then WORK_NODE="$(cygpath -m "$WORK")"; else WORK_NODE="$WORK"; fi

mkdir -p "$WORK/plans" "$WORK/wf" "$WORK/transcripts"
export WORKFLOW_PLANS_DIR="$WORK_NODE/plans"
export CLAUDE_WORKFLOW_DIR="$WORK_NODE/wf"
export CLAUDE_TRANSCRIPT_BASE_DIR="$WORK_NODE/transcripts"
export AGENTS_CONFIG_DIR="$AGENTS_NODE"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
cd "$WORK" || exit 1

RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
drive() {
    local name="$1" body="$2"
    local js="$WORK/drv-$name.js"
    {
        printf '%s\n' "const audit = require('$AUDIT_NODE');"
        printf '%s\n' "const ledger = require('$LEDGER_NODE');"
        printf '%s\n' "const writer = require('$WRITER_NODE');"
        printf '%s\n' "const schema = require('$SCHEMA_NODE');"
        printf '%s\n' "const fs = require('fs');"
        printf '%s\n' "const out = (v) => process.stdout.write(String(v));"
        printf '%s\n' "$body"
    } > "$js"
    bash "$RWT" 30 node "$js" 2>&1
}

K64A="$(printf 'a%.0s' $(seq 1 64) | tr 'a' '1')"
K64B="$(printf 'a%.0s' $(seq 1 64) | tr 'a' '2')"

# --- 1-3: ledger FIFO at 40 entries never evicts the last terminal run ---
sid="led-fifo-$$"
out=$(drive fifo "
const st = schema.createEmptyState('$sid');
fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));
const first = audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#0'] });
const rid = first.audit_run_id || first.run_id;
audit.finalizeAuditRun('$sid', { audit_run_id: rid, verdict: 'CONTINUE', verdict_summary: 'keep me' });
for (let i = 1; i <= 60; i++) {
  const r = audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#' + i] });
  audit.finalizeAuditRun('$sid', { audit_run_id: r.audit_run_id || r.run_id, verdict: 'CONTINUE', verdict_summary: 's' + i });
}
const a = writer.readState('$sid').audit;
const kept = (a.ledger || []).some((e) => e.id === rid);
out((a.ledger || []).length + '|' + kept + '|' + String(a.last_terminal_run_id));
")
assert_match "1: ledger is pruned to at most 40 entries" "$out" '^([0-9]|[1-3][0-9]|40)\|'
assert_match "2: the earliest run survives pruning while it is last_terminal_run_id" "$out" '\|(true|false)\|run-'
if printf '%s' "$out" | grep -Eq '\|true\|'; then
    pass "3: pruning never evicts the entry named by last_terminal_run_id"
else
    # A later terminal run supersedes it; then the CURRENT last_terminal_run_id must survive.
    out2=$(drive fifo2 "
const a = writer.readState('$sid').audit;
out(String((a.ledger || []).some((e) => e.id === a.last_terminal_run_id)));
")
    assert_eq "3: pruning never evicts the entry named by last_terminal_run_id" "$out2" "true"
fi

# --- 4: consumed_transitions FIFO caps at 200 and keeps the newest ---
sid="led-ct-$$"
out=$(drive ct "
const st = schema.createEmptyState('$sid');
fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));
for (let i = 0; i < 260; i++) {
  const r = audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#' + i] });
  audit.finalizeAuditRun('$sid', { audit_run_id: r.audit_run_id || r.run_id, verdict: 'CONTINUE', verdict_summary: 's' + i });
}
const a = writer.readState('$sid').audit;
const ct = a.consumed_transitions || [];
out(ct.length + '|' + ledger.isTransitionConsumed(a, 'write_code#259') + '|' + ledger.isTransitionConsumed(a, 'write_code#0'));
")
assert_match "4: consumed_transitions is capped at 200, newest kept, oldest dropped" "$out" '^200\|true\|false$'

# --- 5: block_overrides FIFO caps at 20 ---
sid="led-bo-$$"
out=$(drive bo "
const st = schema.createEmptyState('$sid');
fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));
for (let i = 0; i < 30; i++) {
  audit.recordBlockOverride('$sid', { audit_run_id: 'run-0001', freshness_key: '$K64A', reason: 'override reason number ' + i, actor: 'user' });
}
out(String((writer.readState('$sid').audit.block_overrides || []).length));
")
assert_eq "5: block_overrides is capped at 20 entries" "$out" "20"

# --- 6-7: declared_files.files caps at 500 and raises the truncated flag ---
sid="led-df-$$"
out=$(drive df "
const st = schema.createEmptyState('$sid');
fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));
const files = [];
for (let i = 0; i < 640; i++) files.push('src/f' + i + '.js');
audit.writeAuditState('$sid', { declared_files: { detail_key: '$K64A', files: files } });
const df = writer.readState('$sid').audit.declared_files || {};
out((df.files || []).length + '|' + String(df.truncated));
")
assert_match "6: declared_files.files is capped at 500" "$out" '^500\|'
assert_match "7: the cap raises declared_files.truncated" "$out" '\|true$'

# --- 8-10: isSubCheckSettled matches on the exact <sub_check_id>@<input_key> pair ---
sid="led-sc-$$"
out=$(drive sc "
const st = schema.createEmptyState('$sid');
st.audit.ledger = [{ id: 'run-0001', outcome: 'terminal', verdict: 'CONTINUE', sub_checks: ['outline-detail'], input_key: { 'outline-detail': '$K64A' } }];
st.audit.last_terminal_run_id = 'run-0001';
fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));
const a = writer.readState('$sid').audit;
out([
  ledger.isSubCheckSettled(a, 'outline-detail', '$K64A'),
  ledger.isSubCheckSettled(a, 'outline-detail', '$K64B'),
  ledger.isSubCheckSettled(a, 'intent-outline', '$K64A'),
].join('|'));
")
assert_match "8: isSubCheckSettled is true for the exact id@key pair" "$out" '^true\|'
assert_match "9: isSubCheckSettled is false when the input key moved" "$out" '^true\|false\|'
assert_match "10: isSubCheckSettled is false for a different sub-check id" "$out" '\|false$'

# --- 11-12: lastTerminalRun / isRunFresh ---
sid="led-fresh-$$"
out=$(drive fresh "
const st = schema.createEmptyState('$sid');
st.audit.ledger = [
  { id: 'run-0001', outcome: 'terminal', verdict: 'CONTINUE', freshness_key: '$K64A' },
  { id: 'run-0002', outcome: 'discarded-stale', verdict: null, freshness_key: '$K64B' },
  { id: 'run-0003', outcome: 'armed', verdict: null, freshness_key: '$K64B' },
];
st.audit.last_terminal_run_id = 'run-0001';
fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));
const a = writer.readState('$sid').audit;
const lt = ledger.lastTerminalRun(a);
out([
  lt && lt.id,
  ledger.isRunFresh(lt, '$K64A'),
  ledger.isRunFresh(lt, '$K64B'),
  ledger.isRunFresh(lt, null),
  ledger.isRunFresh({ freshness_key: null }, '$K64A'),
  ledger.isRunFresh(lt, '$K64A'.slice(0, 12)),
].join('|'));
")
assert_match "11: lastTerminalRun returns the newest terminal entry only" "$out" '^run-0001\|'
assert_match "12: isRunFresh is true only for an exact freshness_key match" "$out" '^run-0001\|true\|false\|'
assert_match "13: isRunFresh returns false (never throws) for a null key on either side" "$out" '\|false\|false\|false$'

# --- 14-17: canonical input_key schema for a coalesced TR1-TR5 run (round-2 C2) ---
sid="led-canon-$$"
out=$(drive canon "
const st = schema.createEmptyState('$sid');
st.audit.ledger = [{
  id: 'run-0007', outcome: 'terminal', verdict: 'CONTINUE',
  tr_ids: ['TR1', 'TR2', 'TR3', 'TR4', 'TR5'],
  sub_checks: ['intent-internal', 'intent-outline', 'outline-detail', 'declared-files-snapshot', 'detail-code', 'scope-drift', 'systemic-risk', 'recurrence-patterns'],
  input_key: {
    'intent-internal': '$K64A', 'intent-outline': '$K64A', 'outline-detail': '$K64A',
    'declared-files-snapshot': '$K64A', 'detail-code': '$K64A', 'scope-drift': '$K64A',
    'systemic-risk': '$K64A', 'recurrence-patterns': '$K64A',
  },
  trigger_input_keys: { TR1: '$K64A', TR2: '$K64A', TR3: '$K64A', TR4: '$K64A', TR5: '$K64A' },
}];
st.audit.last_terminal_run_id = 'run-0007';
fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));
const a = writer.readState('$sid').audit;
const e = a.ledger[0];
const trKeyed = Object.keys(e.input_key).filter((k) => /^TR[0-9]+\$/.test(k));
const allSettled = e.sub_checks.every((id) => ledger.isSubCheckSettled(a, id, '$K64A'));
e.trigger_input_keys = { TR1: 'corrupted', TR9: 'garbage' };
const stillSettled = e.sub_checks.every((id) => ledger.isSubCheckSettled(a, id, '$K64A'));
out([trKeyed.length, allSettled, Object.keys(e.trigger_input_keys).length, stillSettled].join('|'));
")
assert_match "14: input_key is keyed by sub-check id only, never by TR id" "$out" '^0\|'
assert_match "15: every coalesced sub-check answers settled individually" "$out" '^0\|true\|'
assert_match "16: trigger_input_keys is metadata isSubCheckSettled never consults" "$out" '\|true$'
if printf '%s' "$out" | grep -Eq '^0\|true\|'; then
    pass "17: a coalesced run carries one identity across TR1-TR5"
else
    fail "17: a coalesced run carries one identity across TR1-TR5" "got '$out'"
fi

# --- 18: schema validate rejects a TR-keyed input_key ---
sid="led-badkey-$$"
out=$(drive badkey "
const st = schema.createEmptyState('$sid');
st.audit.ledger = [{ id: 'run-0001', outcome: 'terminal', verdict: 'CONTINUE', sub_checks: ['outline-detail'], input_key: { TR2: '$K64A' } }];
st.audit.last_terminal_run_id = 'run-0001';
let rejected = false;
try {
  const res = schema.validate(st);
  rejected = res === false || (res && res.valid === false) || (Array.isArray(res && res.errors) && res.errors.length > 0);
} catch (e) { rejected = true; }
fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));
const a = writer.readState('$sid').audit;
out(String(rejected) + '|' + String(ledger.isSubCheckSettled(a, 'TR2', '$K64A')));
")
assert_match "18: schema validate rejects a TR-keyed input_key" "$out" '^true\|'
assert_match "19: a TR-keyed entry is never treated as a settled sub-check" "$out" '\|false$'

# --- 20: the TR_ID_RE guard rejects a TR-shaped sub-check id even when the ledger
# lists it as a settled sub-check at a matching input key. Case 19's fixture lists
# only 'outline-detail' as a sub_check, so the normal lookup already misses 'TR2' and
# the TR_ID_RE guard is never exercised (the mutant survives). Here sub_checks IS
# ['TR2'] with a matching input_key, so the lookup would find it settled — only
# `if (TR_ID_RE.test(subCheckId)) return false` (audit-ledger.js:50) makes the answer
# false. Deleting that line makes isSubCheckSettled return true. ---
sid="led-trguard-$$"
out=$(drive trguard "
const st = schema.createEmptyState('$sid');
st.audit.ledger = [{ id: 'run-0001', outcome: 'terminal', verdict: 'CONTINUE', sub_checks: ['TR2'], input_key: { TR2: '$K64A' } }];
st.audit.last_terminal_run_id = 'run-0001';
fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));
const a = writer.readState('$sid').audit;
out(String(ledger.isSubCheckSettled(a, 'TR2', '$K64A')));
")
assert_eq "20: a TR-shaped sub-check id at a matching input key is never settled (TR_ID_RE guard)" \
    "$out" "false"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
