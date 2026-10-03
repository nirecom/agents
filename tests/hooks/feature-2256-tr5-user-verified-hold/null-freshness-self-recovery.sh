#!/usr/bin/env bash
# tests/hooks/feature-2256-tr5-user-verified-hold/null-freshness-self-recovery.sh
# Tests: hooks/workflow-gate/user-verified-audit.js, hooks/workflow-gate/supervisor-check.js, hooks/lib/null-freshness.js, hooks/lib/supervisor-state-writer/audit-run.js
# Tags: supervisor, tr5, null-freshness, self-recovering, infinite-loop, artifact-side, code-side, TL2, scope:issue-specific
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
