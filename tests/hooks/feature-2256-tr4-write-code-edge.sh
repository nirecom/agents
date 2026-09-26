#!/usr/bin/env bash
# tests/hooks/feature-2256-tr4-write-code-edge.sh
# Tests: hooks/supervisor-guard/collect-audit-triggers.js, hooks/lib/audit-triggers.js, hooks/lib/branch-diff.js, hooks/lib/supervisor-state-writer/audit.js
# Tags: supervisor, audit-trigger, TR4, write-code, edge-trigger, scope-drift, TL2, scope:issue-specific, pwsh-not-required

# TL3 gap (what this test does NOT catch):
# - a real Stop hook reading a real workflow state stream written by workflow-mark
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

# #2256 S3/S4: TR4 is an EDGE trigger on the write_code step-completion transition, never
# a level trigger on the working-tree diff.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_NODE="$AGENTS_DIR"
fi
COLLECT_NODE="$AGENTS_NODE/hooks/supervisor-guard/collect-audit-triggers.js"
PROJ_NODE="$AGENTS_NODE/hooks/workflow-state/state-io/projection.js"
WRITER_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-writer.js"
AUDIT_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-writer/audit.js"
SCHEMA_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-schema.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then pass "$1"; else fail "$1" "both sides are '$2'"; fi; }
assert_match() { if printf '%s' "$2" | grep -Eq "$3"; then pass "$1"; else fail "$1" "'$2' does not match /$3/"; fi; }

for tool in node git; do
    command -v "$tool" >/dev/null 2>&1 || fail "prereq-$tool" "$tool is required and must never be skipped"
done

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t f2256tr4)"
trap 'rm -rf "$WORK"' EXIT
if command -v cygpath >/dev/null 2>&1; then WORK_NODE="$(cygpath -m "$WORK")"; else WORK_NODE="$WORK"; fi

mkdir -p "$WORK/plans" "$WORK/wf" "$WORK/transcripts"
export WORKFLOW_PLANS_DIR="$WORK_NODE/plans"
export CLAUDE_WORKFLOW_DIR="$WORK_NODE/wf"
export CLAUDE_TRANSCRIPT_BASE_DIR="$WORK_NODE/transcripts"
export AGENTS_CONFIG_DIR="$AGENTS_NODE"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
cd "$WORK" || exit 1

mk_repo() {
    local dir="$WORK/$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config core.autocrlf false
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" config user.email t@example.invalid
    git -C "$dir" config user.name tester
    printf 'seed\n' > "$dir/seed.txt"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m seed
    git -C "$dir" checkout -q -b work
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$dir"; else printf '%s' "$dir"; fi
}

# candidates <steps-json> [audit-json] — run the collector over a projected workflow state.
candidates() {
    local steps="$1" audit="${2:-{\}}"
    local js="$WORK/cand.js"
    {
        printf '%s\n' "const collect = require('$COLLECT_NODE');"
        printf '%s\n' "const proj = { steps: $steps };"
        printf '%s\n' "const state = { audit: $audit, alert: {}, layer1: { findings: [] } };"
        printf '%s\n' "const r = collect.collectAuditCandidates(proj, state);"
        printf '%s\n' "process.stdout.write(JSON.stringify(r));"
    } > "$js"
    bash "$RWT" 30 node "$js" 2>&1
}

STEP_DONE='{"write_code":{"status":"complete","updated_seq":7,"updated_at":"2026-01-01T00:00:00Z"}}'
STEP_DONE_LATER='{"write_code":{"status":"complete","updated_seq":11,"updated_at":"2026-01-02T00:00:00Z"}}'
STEP_PENDING='{"write_code":{"status":"pending","updated_seq":null,"updated_at":null}}'

# --- 1-3: write_code completion produces exactly one TR4 candidate ---
out="$(candidates "$STEP_DONE")"
assert_match "1: collectAuditCandidates returns an array of triggers" "$out" '^\['
assert_match "2: a completed write_code step yields the TR4 trigger" "$out" 'TR4'
assert_match "3: the TR4 cause is the step-complete label, not stage-boundary" "$out" 'step-complete:write_code'
if printf '%s' "$out" | grep -q 'stage-boundary'; then
    fail "4: the retired stage-boundary cause prefix is gone" "output still contains stage-boundary"
else
    pass "4: the retired stage-boundary cause prefix is gone"
fi

# --- 5: a pending write_code step produces no TR4 candidate ---
out="$(candidates "$STEP_PENDING")"
if printf '%s' "$out" | grep -q 'TR4'; then
    fail "5: an incomplete write_code step arms nothing" "TR4 appeared for a pending step"
else
    pass "5: an incomplete write_code step arms nothing"
fi

# --- 6-7: the same transition key is consumed exactly once ---
consumed='{"consumed_transitions":["write_code#7"],"audit_phase":null}'
out="$(candidates "$STEP_DONE" "$consumed")"
if printf '%s' "$out" | grep -q 'TR4'; then
    fail "6: a consumed transition never re-arms on the next Stop" "TR4 re-appeared for write_code#7"
else
    pass "6: a consumed transition never re-arms on the next Stop"
fi
out="$(candidates "$STEP_DONE_LATER" "$consumed")"
assert_match "7: write_code re-entry at a new updated_seq arms again" "$out" 'TR4'

# --- 8: TR4 is an edge trigger — a moving diff alone must not produce a candidate ---
repo="$(mk_repo r4)"
before="$(candidates "$STEP_DONE" "$consumed")"
printf 'drifted\n' > "$WORK/r4/seed.txt"
printf 'undeclared\n' > "$WORK/r4/extra.txt"
after="$(candidates "$STEP_DONE" "$consumed")"
assert_eq "8: changing only the working tree yields the same (empty) TR4 verdict" "$after" "$before"

# --- 9-11: a new identity per re-entry, recorded in the ledger ---
sid="tr4-$$"
armjs="$WORK/arm.js"
{
    printf '%s\n' "const audit = require('$AUDIT_NODE');"
    printf '%s\n' "const writer = require('$WRITER_NODE');"
    printf '%s\n' "const schema = require('$SCHEMA_NODE');"
    printf '%s\n' "const fs = require('fs');"
    printf '%s\n' "fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(schema.createEmptyState('$sid')));"
    printf '%s\n' "const a = audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#7'], cwd: '$repo' });"
    printf '%s\n' "const ridA = a.audit_run_id || a.run_id;"
    printf '%s\n' "audit.finalizeAuditRun('$sid', { audit_run_id: ridA, verdict: 'CONTINUE', verdict_summary: 'ok' });"
    printf '%s\n' "const b = audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#11'], cwd: '$repo' });"
    printf '%s\n' "const ridB = b.audit_run_id || b.run_id;"
    printf '%s\n' "const st = writer.readState('$sid');"
    printf '%s\n' "const ids = (st.audit.ledger || []).map((e) => e.id).join(',');"
    printf '%s\n' "process.stdout.write([ridA, ridB, ids, (st.audit.consumed_transitions || []).join(',')].join('|'));"
} > "$armjs"
out="$(bash "$RWT" 30 node "$armjs" 2>&1)"
first="$(printf '%s' "$out" | cut -d'|' -f1)"
second="$(printf '%s' "$out" | cut -d'|' -f2)"
assert_ne "9: write_code re-entry gets a fresh audit run identity" "$first" "$second"
assert_match "10: both identities are recorded in the ledger" "$out" 'run-0001,run-0002'
assert_match "11: both transitions are recorded as consumed" "$out" 'write_code#7,write_code#11'

# --- 12-16: scope drift is computed from the full working-tree union ---
scope_probe() {
    local label="$1" state="$2" expect="$3"
    local r; r="$(mk_repo "sd-$state")"
    local dir="$WORK/sd-$state"
    printf 'declared change\n' >> "$dir/seed.txt"
    printf 'undeclared\n' > "$dir/rogue.txt"
    case "$state" in
        staged) git -C "$dir" add -A ;;
        committed) git -C "$dir" add -A; git -C "$dir" commit -q -m drift ;;
        unstaged) git -C "$dir" add rogue.txt; git -C "$dir" commit -q -m addrogue; printf 'more\n' >> "$dir/rogue.txt" ;;
        untracked) : ;;
    esac
    local s="sd-$state-$$"
    local js="$WORK/sd-$state.js"
    {
        printf '%s\n' "const audit = require('$AUDIT_NODE');"
        printf '%s\n' "const writer = require('$WRITER_NODE');"
        printf '%s\n' "const schema = require('$SCHEMA_NODE');"
        printf '%s\n' "const fs = require('fs');"
        printf '%s\n' "const st = schema.createEmptyState('$s');"
        printf '%s\n' "st.audit.declared_files = { detail_key: null, snapshot_at: '2026-01-01T00:00:00Z', run_id: 'run-0000', files: ['seed.txt'] };"
        printf '%s\n' "fs.writeFileSync(writer.getStatePath('$s'), JSON.stringify(st));"
        printf '%s\n' "const a = audit.armAuditRun('$s', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#1'], cwd: '$r' });"
        printf '%s\n' "const e = (writer.readState('$s').audit.ledger || []).filter((x) => x.id === (a.audit_run_id || a.run_id))[0] || {};"
        printf '%s\n' "process.stdout.write(JSON.stringify(e.scope_drift === undefined ? 'ABSENT' : e.scope_drift));"
    } > "$js"
    local o; o="$(bash "$RWT" 40 node "$js" 2>&1)"
    assert_match "$label" "$o" "$expect"
}
scope_probe "12: a committed undeclared file lands in ledger scope_drift" committed 'rogue\.txt'
scope_probe "13: a staged undeclared file lands in ledger scope_drift" staged 'rogue\.txt'
scope_probe "14: an unstaged undeclared change lands in ledger scope_drift" unstaged 'rogue\.txt'
scope_probe "15: an untracked undeclared file lands in ledger scope_drift" untracked 'rogue\.txt'

# --- 16: a fully declared change records no drift ---
repo="$(mk_repo clean)"
printf 'declared\n' >> "$WORK/clean/seed.txt"
sid="sdclean-$$"
js="$WORK/sdclean.js"
{
    printf '%s\n' "const audit = require('$AUDIT_NODE');"
    printf '%s\n' "const writer = require('$WRITER_NODE');"
    printf '%s\n' "const schema = require('$SCHEMA_NODE');"
    printf '%s\n' "const fs = require('fs');"
    printf '%s\n' "const st = schema.createEmptyState('$sid');"
    printf '%s\n' "st.audit.declared_files = { detail_key: null, snapshot_at: '2026-01-01T00:00:00Z', run_id: 'run-0000', files: ['seed.txt'] };"
    printf '%s\n' "fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));"
    printf '%s\n' "const a = audit.armAuditRun('$sid', { tr_ids: ['TR4'], cause: 'step-complete:write_code', transitions: ['write_code#1'], cwd: '$repo' });"
    printf '%s\n' "const e = (writer.readState('$sid').audit.ledger || []).filter((x) => x.id === (a.audit_run_id || a.run_id))[0] || {};"
    printf '%s\n' "const d = e.scope_drift;"
    printf '%s\n' "process.stdout.write(d === null || (Array.isArray(d) && d.length === 0) ? 'no-drift' : JSON.stringify(d === undefined ? 'ABSENT' : d));"
} > "$js"
out="$(bash "$RWT" 40 node "$js" 2>&1)"
assert_eq "16: a change confined to declared files records no scope drift" "$out" "no-drift"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && { echo "All tests passed."; exit 0; }
exit 1
