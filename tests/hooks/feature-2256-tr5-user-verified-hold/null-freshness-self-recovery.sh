#!/usr/bin/env bash
# tests/hooks/feature-2256-tr5-user-verified-hold/null-freshness-self-recovery.sh
# Tests: hooks/workflow-gate/user-verified-audit.js, hooks/workflow-gate/supervisor-check.js, hooks/lib/null-freshness.js, hooks/lib/supervisor-state-writer/audit-run.js
# Tags: supervisor, tr5, null-freshness, self-recovering, infinite-loop, artifact-side, code-side, TL2, scope:issue-specific, newer-audit-unsettled
# #2400 / #2360 — a null-key refusal arms one re-audit; once that run is finalized
# CONTINUE through the sanctioned writer, both gates certify it and the sentinel
# never re-arms (no loop). The armed run's artifact_keys / trigger key are what the
# next decision compares against, so R2 pins armCore's record. R1/R7 FAIL before the
# fix (a post-TR5 detail edit was approved on a code-only match).
# Parent: tests/hooks/feature-2256-tr5-user-verified-hold.sh

set -uo pipefail
# TL3 gap (what this test does NOT catch):
# - a real outline-skipped session (outline.md never written) merging via a real
#   `gh pr merge` intercepted by the registered Bash PreToolUse hook — payloads here
#   are piped straight into workflow-gate.js
# - the real supervisor-audit subagent finalizing the re-armed run (R3 calls the writer)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT
# shellcheck source=./_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

MERGE_CMD='gh pr merge 42 --squash --delete-branch'
OUTLINE="$WORK/plans/$SID-outline.md"

mk_null_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b work
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config core.autocrlf false
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" config user.email t@example.invalid
    git -C "$dir" config user.name tester
    printf 'seed\n' > "$dir/seed.txt"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m seed
    nrm "$dir"
}
gate_at() {
    CMDTEXT="$1" RCWD="$2" SESS="$SID" node 2>/dev/null <<'JS' | bash "$RWT" 60 node "$AGENTS_DIR/hooks/workflow-gate.js" 2>/dev/null
process.stdout.write(JSON.stringify({
  tool_name: 'Bash',
  tool_input: { command: process.env.CMDTEXT, cwd: process.env.RCWD },
  session_id: process.env.SESS,
}));
JS
}

# seed_continue <tiv|__NONE__> — terminal CONTINUE run-0011, null key, current artifact_keys.
seed_continue() {
    TIV="$1" AK="$(artifact_keys_json)" node <<'JS'
const e = {
  id: 'run-0011', outcome: 'terminal', cause: 'step-complete:user_verification',
  tr_ids: ['TR5'], verdict: 'CONTINUE', freshness_key: null, artifact_keys: JSON.parse(process.env.AK),
  sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': null },
};
if (process.env.TIV !== '__NONE__') e.trigger_input_keys = { TR5: process.env.TIV };
process.stdout.write(JSON.stringify({ ledger: [e], last_terminal_run_id: 'run-0011', audit_verdict_summary: 'CONTINUE' }));
JS
}
# ledger_field <run-id> <dotted-path> — a field of the ledger entry with that id.
ledger_field() {
    WR="$WRITER_NODE" SESS="$SID" RID="$1" RSPATH="$2" node 2>&1 <<'JS'
const st = require(process.env.WR).readState(process.env.SESS);
let v = ((st && st.audit && st.audit.ledger) || []).find((e) => e && e.id === process.env.RID);
for (const k of process.env.RSPATH.split('.')) v = v === null || v === undefined ? undefined : v[k];
process.stdout.write(v === undefined ? 'none' : String(v));
JS
}
finalize_continue() {
    WR="$WRITER_NODE" SESS="$SID" RID="$1" node 2>&1 <<'JS'
const r = require(process.env.WR).finalizeAuditRun(process.env.SESS, { audit_run_id: process.env.RID, verdict: 'CONTINUE' });
process.stdout.write(String(r && r.accepted));
JS
}
edit_detail() { printf '\n- added-after-tr5.txt\n' >> "$WORK/plans/$SID-detail.md"; }

# ===== artifact-side null: outline.md absent, code side computable =====
case_begin "artifact-side-detail-edit-refusal-arms-reaudit" "hooks/workflow-gate/user-verified-audit.js"
write_plans
rm -f "$OUTLINE"
IV="$(input_version)"
assert_ne "0a: artifact side — input_version is computable" "$IV" "null"
seed_state "$(seed_continue "$IV")" >/dev/null
edit_detail
assert_eq "R1: a detail edit after TR5 refuses the sentinel" "$(decision_of "$(gate "$SENTINEL_UV")")" "block"
assert_eq "R1b: the refusal arms a re-audit" "$(state_field audit.audit_phase)" "pending"
RID="$(state_field audit.audit_run_id)"
assert_match "R1c: the armed run has a run id" "$RID" '^run-[0-9]{4}$'
assert_ne "R1d: the armed run is a new run, not the seeded one" "$RID" "run-0011"
case_end

case_begin "artifact-side-armed-run-records-current-keys" "hooks/lib/supervisor-state-writer/audit-run.js"
assert_eq "R2a: the armed run records the edited detail hash" "$(ledger_field "$RID" artifact_keys.detail)" "$(artifact_key detail)"
assert_eq "R2b: the armed run records the absent outline as null" "$(ledger_field "$RID" artifact_keys.outline)" "null"
assert_eq "R2c: the armed run records the current trigger key" "$(ledger_field "$RID" trigger_input_keys.TR5)" "$IV"
case_end

case_begin "artifact-side-own-pending-run-holds-merge" "hooks/workflow-gate/supervisor-check.js"
out="$(gate_at "$MERGE_CMD" "$REPO_NODE")"
assert_eq "R1e: the sentinel's own pending run holds the merge" "$(decision_of "$out")" "block"
assert_match "R1e2: the deny names the pending run" "$(reason_of "$out")" "newer audit run \\($RID, pending\\)"
case_end

case_begin "artifact-side-own-pending-run-no-new-arm" "hooks/workflow-gate/user-verified-audit.js"
out="$(gate "$SENTINEL_UV")"
assert_eq "R1f: re-issuing the sentinel while its run is pending still blocks" "$(decision_of "$out")" "block"
assert_eq "R1f2: no new run is armed over the pending one" "$(state_field audit.audit_run_id)" "$RID"
assert_match "R1f3: the block names the pending run" "$(reason_of "$out")" "$RID"
case_end

case_begin "artifact-side-writer-finalizes-armed-run" "hooks/lib/supervisor-state-writer/audit-run.js"
assert_eq "R3: the sanctioned writer finalizes the armed run CONTINUE" "$(finalize_continue "$RID")" "true"
case_end

case_begin "artifact-side-finalized-run-certifies-sentinel-without-loop" "hooks/workflow-gate/user-verified-audit.js"
assert_eq "R4: the finalized run certifies the sentinel" "$(decision_of "$(gate "$SENTINEL_UV")")" "approve"
assert_eq "R5: re-issuing the sentinel still approves (no re-arm loop)" "$(decision_of "$(gate "$SENTINEL_UV")")" "approve"
assert_eq "R5b: no new run was armed" "$(state_field audit.audit_run_id)" "$RID"
assert_eq "R5c: the audit phase stays done" "$(state_field audit.audit_phase)" "done"
case_end

case_begin "artifact-side-merge-gate-certifies-finalized-run" "hooks/workflow-gate/supervisor-check.js"
assert_eq "R6: the merge gate certifies the same run" "$(decision_of "$(gate_at "$MERGE_CMD" "$REPO_NODE")")" "approve"
case_end

# ===== code-side null: no merge base, trigger key recorded as null =====
case_begin "code-side-detail-edit-refusal-arms-reaudit" "hooks/workflow-gate/user-verified-audit.js"
write_plans
REPO_NULL="$(mk_null_repo "$WORK/repo-null-sr")"
seed_state "$(seed_continue __NONE__)" >/dev/null
edit_detail
assert_eq "R7: code-side null — a detail edit after TR5 refuses the sentinel" \
    "$(decision_of "$(gate_at "$SENTINEL_UV" "$REPO_NULL")")" "block"
assert_eq "R7b: the refusal arms a re-audit" "$(state_field audit.audit_phase)" "pending"
RID2="$(state_field audit.audit_run_id)"
assert_ne "R7c: the armed run is a new run" "$RID2" "run-0011"
case_end

case_begin "code-side-armed-run-records-null-trigger-key" "hooks/lib/supervisor-state-writer/audit-run.js"
assert_eq "R7d: the armed run records a null trigger key on the code side" "$(ledger_field "$RID2" trigger_input_keys.TR5)" "null"
assert_eq "R7e: the armed run records the edited detail hash" "$(ledger_field "$RID2" artifact_keys.detail)" "$(artifact_key detail)"
case_end

case_begin "code-side-writer-finalizes-armed-run" "hooks/lib/supervisor-state-writer/audit-run.js"
assert_eq "R8: the sanctioned writer finalizes the armed run CONTINUE" "$(finalize_continue "$RID2")" "true"
case_end

case_begin "code-side-finalized-run-certifies-sentinel-without-loop" "hooks/workflow-gate/user-verified-audit.js"
assert_eq "R9: code side certifies without a trigger key" "$(decision_of "$(gate_at "$SENTINEL_UV" "$REPO_NULL")")" "approve"
assert_eq "R9b: re-issuing the sentinel still approves" "$(decision_of "$(gate_at "$SENTINEL_UV" "$REPO_NULL")")" "approve"
assert_eq "R9c: no new run was armed" "$(state_field audit.audit_run_id)" "$RID2"
case_end

case_begin "code-side-merge-gate-certifies-finalized-run" "hooks/workflow-gate/supervisor-check.js"
assert_eq "R9d: the merge gate certifies the same run" "$(decision_of "$(gate_at "$MERGE_CMD" "$REPO_NULL")")" "approve"
write_plans
case_end

# ===== #2400 run-0003: a newer audit run without a verdict blocks null-key certification =====
# seed_unsettled <phase> <tiv|__NONE__> — seed_continue plus an armed TR6 run-0012 in the slot.
seed_unsettled() {
    BASE="$(seed_continue "$2")" PH="$1" node <<'JS'
const o = JSON.parse(process.env.BASE);
o.ledger.push({ id: 'run-0012', outcome: 'armed', tr_ids: ['TR6'], cause: 'severity-threshold:error', verdict: null,
  freshness_key: null, sub_checks: ['scope-drift'], input_key: { 'scope-drift': null }, armed_at: new Date().toISOString() });
Object.assign(o, { audit_run_id: 'run-0012', audit_phase: process.env.PH, run_seq: 12, pending_sub_checks: ['scope-drift'] });
process.stdout.write(JSON.stringify(o));
JS
}

case_begin "code-side-pending-newer-run-holds-merge" "hooks/workflow-gate/supervisor-check.js"
write_plans
seed_state "$(seed_unsettled pending __NONE__)" >/dev/null
out="$(gate_at "$MERGE_CMD" "$REPO_NULL")"
assert_eq "N1: code-side null + a pending TR6 run — the merge is denied" "$(decision_of "$out")" "block"
assert_match "N1b: the deny names the pending run and the audit agent" "$(reason_of "$out")" 'newer audit run \(run-0012, pending\).*supervisor-audit\.md'
case_end

case_begin "code-side-pending-newer-run-holds-sentinel-idempotently" "hooks/workflow-gate/user-verified-audit.js"
assert_eq "N2: the sentinel is held too" "$(decision_of "$(gate_at "$SENTINEL_UV" "$REPO_NULL")")" "block"
assert_eq "N2b: the pending run is kept (no new arm)" "$(state_field audit.audit_run_id)" "run-0012"
assert_eq "N2c: the slot stays pending" "$(state_field audit.audit_phase)" "pending"
case_end

case_begin "code-side-finalized-newer-run-releases-both-gates" "hooks/workflow-gate/supervisor-check.js"
assert_eq "N3: the writer finalizes run-0012 CONTINUE" "$(finalize_continue run-0012)" "true"
assert_eq "N3b: the merge is approved once the TR6 run settles CONTINUE" "$(decision_of "$(gate_at "$MERGE_CMD" "$REPO_NULL")")" "approve"
assert_eq "N4: the sentinel is approved (no self-block, no deadlock)" "$(decision_of "$(gate_at "$SENTINEL_UV" "$REPO_NULL")")" "approve"
case_end

case_begin "code-side-in-progress-and-frozen-runs-hold-merge" "hooks/workflow-gate/supervisor-check.js"
seed_state "$(seed_unsettled in_progress __NONE__)" >/dev/null
assert_eq "N5: an in_progress run holds the merge" "$(decision_of "$(gate_at "$MERGE_CMD" "$REPO_NULL")")" "block"
seed_state "$(seed_unsettled frozen __NONE__)" >/dev/null
out="$(gate_at "$MERGE_CMD" "$REPO_NULL")"
assert_eq "N6: a frozen run holds the merge" "$(decision_of "$out")" "block"
assert_match "N6b: the frozen deny points at re-issuing the sentinel" "$(reason_of "$out")" 'USER_VERIFIED'
case_end

case_begin "code-side-frozen-run-recovers-through-sentinel" "hooks/workflow-gate/user-verified-audit.js"
assert_eq "N7: the sentinel over a frozen run blocks" "$(decision_of "$(gate_at "$SENTINEL_UV" "$REPO_NULL")")" "block"
assert_eq "N7b: it arms a fresh run" "$(state_field audit.audit_run_id)" "run-0013"
assert_eq "N7c: the fresh run is pending" "$(state_field audit.audit_phase)" "pending"
assert_eq "N8: the writer finalizes run-0013 CONTINUE" "$(finalize_continue run-0013)" "true"
assert_eq "N8b: the sentinel is approved" "$(decision_of "$(gate_at "$SENTINEL_UV" "$REPO_NULL")")" "approve"
assert_eq "N8c: the merge is approved" "$(decision_of "$(gate_at "$MERGE_CMD" "$REPO_NULL")")" "approve"
case_end

case_begin "artifact-side-pending-newer-run-holds-both-gates" "hooks/workflow-gate/supervisor-check.js"
write_plans
rm -f "$OUTLINE"
seed_state "$(seed_unsettled pending "$(input_version)")" >/dev/null
out="$(gate_at "$MERGE_CMD" "$REPO_NODE")"
assert_eq "N9: artifact-side null + a pending TR6 run — the merge is denied" "$(decision_of "$out")" "block"
assert_match "N9b: the deny names the pending run" "$(reason_of "$out")" 'newer audit run \(run-0012, pending\)'
assert_eq "N9c: the sentinel is held too" "$(decision_of "$(gate "$SENTINEL_UV")")" "block"
write_plans
case_end

# ===== #2400 D3: an unreadable artifact holds the sentinel before Stage 1, never arming =====
# detail.md replaced by a directory = a non-regular file, unreadable on every platform.
make_detail_unreadable() { rm -f "$WORK/plans/$SID-detail.md"; mkdir "$WORK/plans/$SID-detail.md"; }
restore_detail() { rmdir "$WORK/plans/$SID-detail.md"; write_plans; }
UNREADABLE_RE='detail exist but could not be read'

case_begin "unreadable-artifact-holds-over-block-run-without-arming" "hooks/workflow-gate/user-verified-audit.js"
write_plans
seed_state "$(terminal_run BLOCK "$(fresh_key)")" >/dev/null
make_detail_unreadable
out="$(gate "$SENTINEL_UV")"
assert_eq "X4: unreadable detail + a BLOCK TR5 run — the sentinel is blocked" "$(decision_of "$out")" "block"
assert_match "X4b: the block names the unreadable artifact" "$(reason_of "$out")" "$UNREADABLE_RE"
assert_eq "X4c: no run is armed" "$(state_field audit.audit_run_id)" "none"
assert_eq "X4d: the ledger keeps only the seeded run" "$(state_field audit.ledger.length)" "1"
restore_detail
case_end

case_begin "unreadable-artifact-holds-without-tr5-run-without-arming" "hooks/workflow-gate/user-verified-audit.js"
seed_state '{}' >/dev/null
make_detail_unreadable
out="$(gate "$SENTINEL_UV")"
assert_eq "X5: unreadable detail + no TR5 run — the sentinel is blocked" "$(decision_of "$out")" "block"
assert_match "X5b: the block names the unreadable artifact" "$(reason_of "$out")" "$UNREADABLE_RE"
assert_eq "X5c: no run is armed" "$(state_field audit.audit_run_id)" "none"
assert_eq "X5d: the ledger stays empty" "$(state_field audit.ledger.length)" "0"
restore_detail
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
