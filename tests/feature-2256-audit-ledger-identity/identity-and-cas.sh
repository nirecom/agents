#!/usr/bin/env bash
# tests/feature-2256-audit-ledger-identity/identity-and-cas.sh
# Tests: hooks/lib/supervisor-state-writer/audit.js, bin/supervisor-write-audit-verdict
# Tags: supervisor, audit-run-identity, compare-and-set, TL2, scope:issue-specific
# #2256 S2-b/S2-g: armAuditRun numbers a run in one read-modify-write; finalizeAuditRun
# accepts only the identity it was armed with. Parent: tests/feature-2256-audit-ledger-identity.sh

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_NODE="$AGENTS_DIR"
fi
WRITER_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-writer.js"
AUDIT_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-writer/audit.js"
SCHEMA_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-schema.js"
VERDICT_CLI="$AGENTS_DIR/bin/supervisor-write-audit-verdict"

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

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t f2256id)"
trap 'rm -rf "$WORK"' EXIT
if command -v cygpath >/dev/null 2>&1; then WORK_NODE="$(cygpath -m "$WORK")"; else WORK_NODE="$WORK"; fi

# Fixture isolation (rules/test/fixture-isolation.md): plans dir and workflow dir are
# pinned as a pair, inherited session ids are dropped, and the CWD is neutral.
mkdir -p "$WORK/plans" "$WORK/wf" "$WORK/transcripts"
export WORKFLOW_PLANS_DIR="$WORK_NODE/plans"
export CLAUDE_WORKFLOW_DIR="$WORK_NODE/wf"
export CLAUDE_TRANSCRIPT_BASE_DIR="$WORK_NODE/transcripts"
export AGENTS_CONFIG_DIR="$AGENTS_NODE"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
cd "$WORK" || exit 1

RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
nodejs() { bash "$RWT" 20 node "$@" 2>&1; }

# Every case drives the production module through a generated driver script, so a
# missing export surfaces as a thrown error rather than a silent skip.
drive() {
    local name="$1" body="$2"
    local js="$WORK/drv-$name.js"
    {
        printf '%s\n' "const audit = require('$AUDIT_NODE');"
        printf '%s\n' "const writer = require('$WRITER_NODE');"
        printf '%s\n' "const schema = require('$SCHEMA_NODE');"
        printf '%s\n' "const fs = require('fs');"
        printf '%s\n' "const out = (v) => process.stdout.write(String(v));"
        printf '%s\n' "$body"
    } > "$js"
    nodejs "$js"
}

seed() {
    local sid="$1" phase="$2"
    local js="$WORK/seed.js"
    {
        printf '%s\n' "const writer = require('$WRITER_NODE');"
        printf '%s\n' "const schema = require('$SCHEMA_NODE');"
        printf '%s\n' "const fs = require('fs');"
        printf '%s\n' "const st = schema.createEmptyState('$sid');"
        printf '%s\n' "st.audit = st.audit || {};"
        printf '%s\n' "st.audit.audit_phase = '$phase' === 'null' ? null : '$phase';"
        printf '%s\n' "fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));"
    } > "$js"
    nodejs "$js" >/dev/null
}

# --- 1: armAuditRun numbers runs monotonically as run-NNNN ---
sid="id-arm-$$"
seed "$sid" null
out=$(drive arm1 "
const a = audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#7'] });
const b = audit.armAuditRun('$sid', { tr_ids: ['TR5'], cause: 'step-complete:user_verification', transitions: ['user_verification#9'] });
out((a.audit_run_id || a.run_id) + '|' + (b.audit_run_id || b.run_id));
")
assert_match "1: armAuditRun ids are run-<4 digits>" "$out" '^run-[0-9]{4}\|run-[0-9]{4}$'
first="${out%%|*}"; second="${out##*|}"
# #2256 S2-c idempotency: a second arm while phase=pending returns the SAME run
# (no duplicate minting). Monotonic numbering is verified in the post-finalize case below.
if [ -n "$first" ] && [ -n "$second" ] && [ "$first" = "$second" ]; then
    pass "2: armAuditRun is idempotent while phase=pending (returns same run-id)"
else
    fail "2: armAuditRun is idempotent while phase=pending (returns same run-id)" "got '$out'"
fi

# --- 3: run_seq and audit_run_id are written by the same read-modify-write ---
sid="id-seq-$$"
seed "$sid" null
out=$(drive seq "
const r = audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#1'] });
const st = writer.readState('$sid');
out(String(st.audit.run_seq) + '|' + String(st.audit.audit_run_id) + '|' + String(r.audit_run_id || r.run_id));
")
assert_match "3: run_seq and audit_run_id land in one write" "$out" '^1\|run-0001\|run-0001$'

# --- 4: armAuditRun is idempotent when phase=pending (retry_count unchanged) ---
# #2256 S2-c: the idempotent path returns the existing run without modifying state,
# so a retry_count set before the call must remain unchanged after it.
# The reset-to-0 happens on a FRESH arm (phase=null/done → pending), not on re-arm.
sid="id-retry-$$"
seed "$sid" pending
out=$(drive retry "
audit.writeAuditState('$sid', { audit_retry_count: 2 });
audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#3'] });
out(String(writer.readState('$sid').audit.audit_retry_count));
")
assert_eq "4: armAuditRun while phase=pending leaves audit_retry_count unchanged" "$out" "2"

# --- 5-7: finalizeAuditRun CAS accepts the armed identity ---
sid="id-cas-ok-$$"
seed "$sid" null
out=$(drive casok "
const r = audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#1'] });
const rid = r.audit_run_id || r.run_id;
const res = audit.finalizeAuditRun('$sid', { audit_run_id: rid, verdict: 'CONTINUE', verdict_summary: 'ok' });
const st = writer.readState('$sid');
const led = (st.audit.ledger || []).filter((e) => e.id === rid);
out(String(res.accepted) + '|' + String(st.audit.audit_verdict) + '|' + String(st.audit.last_terminal_run_id) + '|' + (led[0] ? led[0].outcome : 'none'));
")
assert_match "5: finalizeAuditRun accepts a matching identity" "$out" '^true\|'
assert_match "6: accepted finalize records the verdict and last_terminal_run_id" "$out" '\|CONTINUE\|run-0001\|'
assert_match "7: accepted finalize marks the ledger entry terminal" "$out" '\|terminal$'

# --- 8-11: finalizeAuditRun CAS rejects a stale identity ---
sid="id-cas-ng-$$"
seed "$sid" null
out=$(drive casng "
const r = audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#1'] });
const before = writer.readState('$sid').audit.audit_phase;
const res = audit.finalizeAuditRun('$sid', { audit_run_id: 'run-9999', verdict: 'BLOCK', verdict_summary: 'stale writer' });
const st = writer.readState('$sid');
const stale = (st.audit.ledger || []).filter((e) => e.outcome === 'discarded-stale');
const warn = ((st.layer1 || {}).findings || []).filter((f) => f.severity === 'warning');
out(String(res.accepted) + '|' + before + '|' + String(st.audit.audit_phase) + '|' + String(st.audit.audit_verdict) + '|' + stale.length + '|' + warn.length);
")
assert_match "8: finalizeAuditRun rejects a non-matching identity" "$out" '^false\|'
assert_match "9: rejected finalize leaves audit_phase untouched" "$out" '^false\|pending\|pending\|'
assert_match "10: rejected finalize writes no verdict" "$out" '\|pending\|(null|undefined)\|'
assert_match "11: rejected finalize appends discarded-stale + warning finding" "$out" '\|[1-9][0-9]*\|[1-9][0-9]*$'

# --- 12: finalizeAuditRun accepts while phase is in_progress ---
sid="id-cas-prog-$$"
seed "$sid" null
out=$(drive casprog "
const r = audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#1'] });
const rid = r.audit_run_id || r.run_id;
audit.writeAuditState('$sid', { audit_phase: 'in_progress' });
out(String(audit.finalizeAuditRun('$sid', { audit_run_id: rid, verdict: 'WARN', verdict_summary: 'w' }).accepted));
")
assert_eq "12: finalizeAuditRun accepts an in_progress run" "$out" "true"

# --- 13: finalizeAuditRun rejects once the slot is already cleared ---
sid="id-cas-clear-$$"
seed "$sid" null
out=$(drive casclear "
const r = audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#1'] });
const rid = r.audit_run_id || r.run_id;
audit.finalizeAuditRun('$sid', { audit_run_id: rid, verdict: 'CONTINUE', verdict_summary: 'first' });
out(String(audit.finalizeAuditRun('$sid', { audit_run_id: rid, verdict: 'BLOCK', verdict_summary: 'second' }).accepted));
")
assert_eq "13: finalizeAuditRun rejects a second finalize of the same run" "$out" "false"

# --- 14-15: the CLI surfaces the CAS rejection as exit 3 ---
sid="id-cli-$$"
seed "$sid" null
drive cliarm "audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#1'] }); out('');" >/dev/null
cli_out=$(bash "$RWT" 20 node "$VERDICT_CLI" --session-id "$sid" --audit-run-id run-0001 --verdict CONTINUE --verdict-summary ok 2>&1)
cli_rc=$?
assert_eq "14: supervisor-write-audit-verdict exits 0 on a matching identity" "$cli_rc" "0"
cli_out=$(bash "$RWT" 20 node "$VERDICT_CLI" --session-id "$sid" --audit-run-id run-9999 --verdict BLOCK --verdict-summary stale 2>&1)
cli_rc=$?
assert_eq "15: supervisor-write-audit-verdict exits 3 on a stale identity" "$cli_rc" "3"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
