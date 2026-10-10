#!/usr/bin/env bash
# tests/hooks/feature-2256-tr5-user-verified-hold/null-freshness-artifact-match.sh
# Tests: hooks/workflow-gate/supervisor-check.js, hooks/workflow-gate/user-verified-audit.js, hooks/lib/null-freshness.js, hooks/workflow-gate.js
# Tags: supervisor, tr5, premerge, null-freshness, artifact-side, code-side, TL2, scope:issue-specific, unreadable-artifact
# #2400 — both gates certify a null freshness_key only through the shared predicate:
# CONTINUE, no later BLOCK, and every per-artifact hash unchanged since the TR5 run
# (plus the trigger key on the artifact side). M1/M12 FAIL before the fix (the merge
# gate denied every null key); U2-U5 FAIL before it (code-only matching approved).
# Parent: tests/hooks/feature-2256-tr5-user-verified-hold.sh

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# TL3 gap (what this test does NOT catch):
# - a real outline-skipping session merging via a real `gh pr merge` intercepted by the
#   registered Bash PreToolUse hook — fixtures reach a null key by deleting outline.md /
#   using a repo with no merge base, and pipe the payload into workflow-gate.js
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

# Same no-merge-base fixture as null-freshness-short-circuit.sh (code-side null).
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
    CMDTEXT="$1" RCWD="$2" SESS="$SID" node 2>/dev/null <<'JS' | bash "$RWT" 60 node "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate.js" 2>/dev/null
process.stdout.write(JSON.stringify({
  tool_name: 'Bash',
  tool_input: { command: process.env.CMDTEXT, cwd: process.env.RCWD },
  session_id: process.env.SESS,
}));
JS
}

# tr5_run <verdict> <fkey|null> <tiv|__NONE__> <yes|no> — one terminal TR5 run at the
# given freshness_key; yes records the current artifact_keys (as armCore does), no
# models a legacy run.
tr5_run() {
    local ak='null'
    [ "$4" = "yes" ] && ak="$(artifact_keys_json)"
    VERD="$1" FKEY="$2" TIV="$3" AK="$ak" node <<'JS'
const fk = process.env.FKEY === 'null' ? null : process.env.FKEY;
const e = {
  id: 'run-0011', outcome: 'terminal', cause: 'step-complete:user_verification',
  tr_ids: ['TR5'], verdict: process.env.VERD, freshness_key: fk,
  sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': fk },
};
if (process.env.TIV !== '__NONE__') e.trigger_input_keys = { TR5: process.env.TIV };
const ak = JSON.parse(process.env.AK);
if (ak !== null) e.artifact_keys = ak;
process.stdout.write(JSON.stringify({ ledger: [e], last_terminal_run_id: 'run-0011', audit_verdict_summary: process.env.VERD }));
JS
}
# null_run <verdict> <tiv|__NONE__> <yes|no> — a tr5_run whose freshness_key is null.
null_run() { tr5_run "$1" null "$2" "$3"; }
# null_run_then_block <tiv> — a certifiable CONTINUE TR5 followed by a terminal TR6 BLOCK.
null_run_then_block() {
    BASE="$(null_run CONTINUE "$1" yes)" node <<'JS'
const o = JSON.parse(process.env.BASE);
o.ledger.push({ id: 'run-0012', outcome: 'terminal', cause: 'step-complete:user_verification',
  tr_ids: ['TR6'], verdict: 'BLOCK', freshness_key: null, sub_checks: [], input_key: {} });
o.last_terminal_run_id = 'run-0012'; o.audit_verdict_summary = 'BLOCK';
process.stdout.write(JSON.stringify(o));
JS
}
artifact_side() { write_plans; rm -f "$OUTLINE"; }
edit_intent() { printf '# intent\nedited after the TR5 verdict\n' > "$WORK/plans/$SID-intent.md"; }
edit_detail() { printf '\n- added-after-tr5.txt\n' >> "$WORK/plans/$SID-detail.md"; }
merge_out() { gate_at "$MERGE_CMD" "${1:-$REPO_NODE}"; }

# --- premise guards: each fixture really yields the null kind it claims ---
case_begin "artifact-side-null-fixture-premise" "hooks/lib/null-freshness.js"
artifact_side
IV="$(input_version)"
assert_ne "0a: artifact side — input_version is computable" "$IV" "null"
assert_eq "0b: artifact side — freshness_key is null" "$(fresh_key)" "null"
assert_match "0c: artifact_keys_json records outline as null" "$(artifact_keys_json)" '"outline":null'
REPO_NULL="$(mk_null_repo "$WORK/repo-null-am")"
case_end

# ===== pre-merge backstop (merge gate) =====
case_begin "merge-approves-continue-with-unchanged-artifacts" "hooks/workflow-gate/supervisor-check.js"
seed_state "$(null_run CONTINUE "$IV" yes)" >/dev/null
assert_eq "M1: CONTINUE + trigger match + artifacts unchanged — the merge is approved" \
    "$(decision_of "$(merge_out)")" "approve"
case_end

case_begin "merge-denies-intent-edited-after-tr5" "hooks/workflow-gate/supervisor-check.js"
seed_state "$(null_run CONTINUE "$IV" yes)" >/dev/null
edit_intent
out="$(merge_out)"
assert_eq "M2: intent.md edited after TR5 — the merge is denied" "$(decision_of "$out")" "block"
assert_match "M2b: the deny names the null key and the moved intent" "$(reason_of "$out")" 'freshness key is null.*changed: .*intent'
assert_eq "M10a: the M2 deny arms nothing" "$(state_field audit.audit_phase)" "null"
artifact_side
case_end

case_begin "merge-denies-detail-edited-after-tr5" "hooks/workflow-gate/supervisor-check.js"
seed_state "$(null_run CONTINUE "$IV" yes)" >/dev/null
edit_detail
out="$(merge_out)"
assert_eq "M3: detail.md edited after TR5 — the merge is denied" "$(decision_of "$out")" "block"
assert_match "M3b: the deny names the moved detail" "$(reason_of "$out")" 'changed: .*detail'
assert_eq "M10b: the M3 deny arms nothing" "$(state_field audit.audit_phase)" "null"
artifact_side
case_end

# Artifact side: with outline.md present and code computable the real TR5 run carries a
# non-null key; deleting outline.md afterwards is what makes the current key null.
case_begin "merge-denies-outline-deleted-after-tr5" "hooks/workflow-gate/supervisor-check.js"
write_plans
FK_PRESENT="$(fresh_key)"
assert_ne "M4-0: outline present at TR5 — the run's real freshness_key is non-null" "$FK_PRESENT" "null"
seed_state "$(tr5_run CONTINUE "$FK_PRESENT" "$IV" yes)" >/dev/null
rm -f "$OUTLINE"
assert_eq "M4-0b: outline deleted since — the current freshness_key is null" "$(fresh_key)" "null"
out="$(merge_out)"
assert_eq "M4: outline present at TR5, deleted since — the merge is denied" "$(decision_of "$out")" "block"
assert_match "M4b: the deny names the moved outline" "$(reason_of "$out")" 'changed: .*outline'
assert_eq "M10c: the M4 deny arms nothing" "$(state_field audit.audit_phase)" "null"
assert_eq "M4c: the sentinel refuses the same state" "$(decision_of "$(gate "$SENTINEL_UV")")" "block"
assert_eq "M4d: the sentinel refusal arms a re-audit" "$(state_field audit.audit_phase)" "pending"
case_end

# Code side: no merge base keeps the key null at TR5 even with outline.md present, so a
# null-key run recorded with the outline hash is exactly what armCore writes there.
case_begin "merge-denies-code-side-null-outline-deleted-after-tr5" "hooks/workflow-gate/supervisor-check.js"
write_plans
assert_eq "M4e-0: code side — the key is null with outline present" "$(REPO_NODE="$REPO_NULL" fresh_key)" "null"
assert_nomatch "M4e-0b: the recorded artifact_keys carry the outline hash" "$(artifact_keys_json)" '"outline":null'
seed_state "$(null_run CONTINUE __NONE__ yes)" >/dev/null
rm -f "$OUTLINE"
out="$(merge_out "$REPO_NULL")"
assert_eq "M4e: code-side null + outline deleted after TR5 — the merge is denied" "$(decision_of "$out")" "block"
assert_match "M4f: the deny names the moved outline" "$(reason_of "$out")" 'changed: .*outline'
assert_eq "M10c2: the M4e deny arms nothing" "$(state_field audit.audit_phase)" "null"
assert_eq "M4g: the sentinel refuses the same state" "$(decision_of "$(gate_at "$SENTINEL_UV" "$REPO_NULL")")" "block"
assert_eq "M4h: the sentinel refusal arms a re-audit" "$(state_field audit.audit_phase)" "pending"
case_end

case_begin "merge-denies-warn-verdict-on-null-key" "hooks/workflow-gate/supervisor-check.js"
seed_state "$(null_run WARN "$IV" yes)" >/dev/null
out="$(merge_out)"
assert_eq "M5: WARN on a null key — the merge is denied (CONTINUE-only allow-list)" "$(decision_of "$out")" "block"
assert_match "M5b: the deny names the allow-list" "$(reason_of "$out")" 'verdict \(WARN\).*allow-list'
assert_eq "M10d: the M5 deny arms nothing" "$(state_field audit.audit_phase)" "null"
case_end

case_begin "merge-denies-block-verdict-on-null-key" "hooks/workflow-gate/supervisor-check.js"
seed_state "$(null_run BLOCK "$IV" yes)" >/dev/null
out="$(merge_out)"
assert_eq "M6: BLOCK on a null key — the merge is denied" "$(decision_of "$out")" "block"
assert_match "M6b: the deny names the BLOCK verdict" "$(reason_of "$out")" 'verdict \(BLOCK\)'
assert_eq "M10e: the M6 deny arms nothing" "$(state_field audit.audit_phase)" "null"
case_end

case_begin "merge-denies-later-tr6-block" "hooks/workflow-gate/supervisor-check.js"
seed_state "$(null_run_then_block "$IV")" >/dev/null
out="$(merge_out)"
assert_eq "M7: a later TR6 BLOCK on a null key — the merge is denied" "$(decision_of "$out")" "block"
assert_match "M7b: the deny names the post-TR5 BLOCK" "$(reason_of "$out")" 'later audit BLOCK verdict \(post-TR5\)'
assert_eq "M10f: the M7 deny arms nothing" "$(state_field audit.audit_phase)" "null"
case_end

case_begin "merge-denies-legacy-run-without-artifact-keys" "hooks/workflow-gate/supervisor-check.js"
seed_state "$(null_run CONTINUE "$IV" no)" >/dev/null
out="$(merge_out)"
assert_eq "M8: a legacy run without artifact_keys — the merge is denied (fail-closed)" "$(decision_of "$out")" "block"
assert_match "M8b: the deny names the missing per-artifact hashes" "$(reason_of "$out")" 'per-artifact hashes'
assert_eq "M10g: the M8 deny arms nothing" "$(state_field audit.audit_phase)" "null"
case_end

case_begin "merge-denies-code-moved-after-tr5" "hooks/workflow-gate/supervisor-check.js"
seed_state "$(null_run CONTINUE "$IV" yes)" >/dev/null
printf 'code moved after the verdict\n' > "$REPO/seed.txt"
out="$(merge_out)"
printf 'seed\n' > "$REPO/seed.txt"
assert_eq "M9: code moved after TR5 (trigger key stale) — the merge is denied" "$(decision_of "$out")" "block"
assert_match "M9b: the deny names the code diff" "$(reason_of "$out")" 'changed: .*code diff'
assert_eq "M10h: the M9 deny arms nothing" "$(state_field audit.audit_phase)" "null"
assert_eq "M9c: restoring seed.txt restores the trigger key" "$(input_version)" "$IV"
case_end

case_begin "merge-denies-null-key-without-tr5-run" "hooks/workflow-gate/supervisor-check.js"
seed_state '{"ledger":[]}' >/dev/null
out="$(merge_out)"
assert_eq "M11: no TR5 run on a null key — the merge is denied" "$(decision_of "$out")" "block"
assert_match "M11b: the TR5-run check now precedes the null branch" "$(reason_of "$out")" 'no terminal user_verification'
case_end

case_begin "merge-approves-code-side-null-with-unchanged-artifacts" "hooks/workflow-gate/supervisor-check.js"
write_plans
seed_state "$(null_run CONTINUE __NONE__ yes)" >/dev/null
assert_eq "M12: code-side null + CONTINUE + artifacts unchanged — the merge is approved" \
    "$(decision_of "$(merge_out "$REPO_NULL")")" "approve"
case_end

case_begin "merge-denies-code-side-null-detail-edit" "hooks/workflow-gate/supervisor-check.js"
seed_state "$(null_run CONTINUE __NONE__ yes)" >/dev/null
edit_detail
out="$(merge_out "$REPO_NULL")"
assert_eq "M13: code-side null + detail.md edited — the merge is denied" "$(decision_of "$out")" "block"
assert_match "M13b: the deny carries the code-side label and the moved detail" "$(reason_of "$out")" 'code side uncomputable.*changed: .*detail'
write_plans
case_end

case_begin "merge-denies-code-side-null-legacy-run" "hooks/workflow-gate/supervisor-check.js"
seed_state "$(null_run CONTINUE __NONE__ no)" >/dev/null
out="$(merge_out "$REPO_NULL")"
assert_eq "M14: code-side null + legacy run — the merge is denied (fail-closed)" "$(decision_of "$out")" "block"
assert_match "M14b: the deny names the missing per-artifact hashes" "$(reason_of "$out")" 'per-artifact hashes'
case_end

# ===== user_verification gate (sentinel) — the same predicate =====
case_begin "sentinel-approves-continue-with-unchanged-artifacts" "hooks/workflow-gate/user-verified-audit.js"
artifact_side
seed_state "$(null_run CONTINUE "$IV" yes)" >/dev/null
assert_eq "U1: the M1 seed approves the sentinel too" "$(decision_of "$(gate "$SENTINEL_UV")")" "approve"
assert_eq "U1b: the approve arms nothing" "$(state_field audit.audit_phase)" "null"
case_end

case_begin "sentinel-refuses-intent-edited-after-tr5" "hooks/workflow-gate/user-verified-audit.js"
seed_state "$(null_run CONTINUE "$IV" yes)" >/dev/null
edit_intent
assert_eq "U2: intent.md edited after TR5 — the sentinel is not approved" "$(decision_of "$(gate "$SENTINEL_UV")")" "block"
assert_eq "U2b: the refusal arms a re-audit" "$(state_field audit.audit_phase)" "pending"
artifact_side
case_end

case_begin "sentinel-refuses-detail-edited-after-tr5" "hooks/workflow-gate/user-verified-audit.js"
seed_state "$(null_run CONTINUE "$IV" yes)" >/dev/null
edit_detail
assert_eq "U3: detail.md edited after TR5 — the sentinel is not approved" "$(decision_of "$(gate "$SENTINEL_UV")")" "block"
assert_eq "U3b: the refusal arms a re-audit" "$(state_field audit.audit_phase)" "pending"
artifact_side
case_end

case_begin "sentinel-refuses-legacy-run-without-artifact-keys" "hooks/workflow-gate/user-verified-audit.js"
seed_state "$(null_run CONTINUE "$IV" no)" >/dev/null
assert_eq "U4: a legacy run (trigger key matches, no artifact_keys) is not approved" "$(decision_of "$(gate "$SENTINEL_UV")")" "block"
assert_eq "U4b: the refusal arms a re-audit" "$(state_field audit.audit_phase)" "pending"
case_end

case_begin "sentinel-refuses-code-side-null-legacy-run" "hooks/workflow-gate/user-verified-audit.js"
write_plans
seed_state "$(null_run CONTINUE __NONE__ no)" >/dev/null
assert_eq "U5: code-side null + legacy run is not approved" "$(decision_of "$(gate_at "$SENTINEL_UV" "$REPO_NULL")")" "block"
assert_eq "U5b: the refusal arms a re-audit" "$(state_field audit.audit_phase)" "pending"
write_plans
case_end

# ===== #2400 run-0003 D3: an unreadable artifact is not an absent one =====
DETAIL_PATH="$WORK/plans/$SID-detail.md"
absent_detail_run() { artifact_side; rm -f "$DETAIL_PATH"; seed_state "$(null_run CONTINUE "$IV" yes)" >/dev/null; }
case_begin "unreadable-detail-blocks-both-gates" "hooks/workflow-gate/supervisor-check.js"
absent_detail_run
mkdir "$DETAIL_PATH"
out="$(merge_out)"
assert_eq "X1: a directory in place of detail.md — the merge is denied" "$(decision_of "$out")" "block"
assert_match "X1b: the deny says detail could not be read" "$(reason_of "$out")" 'detail.*could not be read'
out="$(gate "$SENTINEL_UV")"
assert_eq "X2: the sentinel is held over an unreadable artifact" "$(decision_of "$out")" "block"
assert_match "X2b: the hold says the artifact could not be read" "$(reason_of "$out")" 'could not be read'
assert_eq "X2c: the hold arms nothing" "$(state_field audit.audit_phase)" "null"
rmdir "$DETAIL_PATH"
case_end

case_begin "absent-detail-keeps-artifact-match" "hooks/workflow-gate/supervisor-check.js"
absent_detail_run
assert_eq "X3a: absent at TR5 and absent now — the merge is approved" "$(decision_of "$(merge_out)")" "approve"
printf '%s' "$DETAIL_BODY" > "$DETAIL_PATH"
out="$(merge_out)"
assert_eq "X3b: detail.md re-created after TR5 — the merge is denied" "$(decision_of "$out")" "block"
assert_match "X3c: the deny names the moved detail" "$(reason_of "$out")" 'a plan artifact is missing.*changed: .*detail'
write_plans
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
