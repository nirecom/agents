#!/usr/bin/env bash
# tests/feature-2256-tr5-user-verified-hold/null-freshness-short-circuit.sh
# Tests: hooks/workflow-gate/user-verified-audit.js, hooks/lib/supervisor-state-schema.js, hooks/workflow-gate/supervisor-check.js, hooks/supervisor-guard/audit-arm.js
# Tags: supervisor, tr5, freshness, null-arm, self-recovering, infinite-loop, artifact-side, TL2, scope:issue-specific
# #2323 — a null freshness_key (code side uncomputable: no merge base) must not re-arm
# the WE-8 sentinel forever. selfRecovering short-circuit approves a prior CONTINUE
# terminal TR5; every other verdict/state stays fail-closed. Scenarios 1 & 3(i) FAIL
# before the fix (fail-before-fix); the rest are fail-closed regressions.
# Parent: tests/feature-2256-tr5-user-verified-hold.sh
# TL3 gap (not caught here): a real stale AGENTS_CONFIG_DIR against a live origin on a
# CI host — fixtures reach null freshness via a fixture repo with no merge base instead.

set -uo pipefail
# shellcheck source=./_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

MERGE_CMD='gh pr merge 42 --squash --delete-branch'

# A repo whose HEAD has no protected-branch ancestor → resolveMergeBase null →
# computeInputVersion null → freshness_key null with input_version null (code side
# uncomputable). $REPO (from _common) has main, so it needs its own fixture.
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

# gate_at <command> <cwd-node> — drive the real PreToolUse gate with an explicit cwd.
gate_at() {
    CMDTEXT="$1" RCWD="$2" SESS="$SID" node -e "
process.stdout.write(JSON.stringify({
  tool_name: 'Bash',
  tool_input: { command: process.env.CMDTEXT, cwd: process.env.RCWD },
  session_id: process.env.SESS,
}));
" 2>/dev/null | bash "$RWT" 60 node "$AGENTS_DIR/hooks/workflow-gate.js" 2>/dev/null
}

fresh_key_at() {
    FP="$FP_NODE" RCWD="$1" PLANS="$WORK_NODE/plans" SESS="$SID" node -e "
const fp = require(process.env.FP);
const r = fp.computeFreshnessKey(process.env.RCWD, process.env.PLANS, process.env.SESS);
process.stdout.write(String((r && r.freshness_key) || 'null'));
" 2>/dev/null
}
input_version_at() {
    FP="$FP_NODE" RCWD="$1" node -e "
const fp = require(process.env.FP);
process.stdout.write(String(fp.computeInputVersion(process.env.RCWD) || 'null'));
" 2>/dev/null
}

# terminal_null <verdict|__MISSING__> — one terminal TR5 run recorded under stale
# conditions (freshness_key:null, input_key null). __MISSING__ omits verdict entirely,
# modeling a malformed ledger entry the schema does not validate. Direct ledger write
# is the sanctioned finalizeAuditRun-equivalent for seeding a terminal run.
terminal_null() {
    VERD="$1" node -e "
const e = {
  id: 'run-0011', outcome: 'terminal', cause: 'step-complete:user_verification',
  tr_ids: ['TR5'], freshness_key: null,
  sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': null },
};
if (process.env.VERD !== '__MISSING__') e.verdict = process.env.VERD;
process.stdout.write(JSON.stringify({ ledger: [e], last_terminal_run_id: 'run-0011', audit_verdict_summary: null }));
"
}

# terminal_null_artifact <verdict> <trigger_iv> — artifact-side null: freshness_key=null,
# input_version non-null, trigger_input_keys.TR5=<trigger_iv>.
terminal_null_artifact() {
    VERD="$1" TIV="$2" node -e "
const e = {
  id: 'run-0011', outcome: 'terminal', cause: 'step-complete:user_verification',
  tr_ids: ['TR5'], freshness_key: null, verdict: process.env.VERD,
  sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': null },
  trigger_input_keys: { TR5: process.env.TIV },
};
process.stdout.write(JSON.stringify({ ledger: [e], last_terminal_run_id: 'run-0011', audit_verdict_summary: process.env.VERD }));
"
}

# terminal_null_artifact_null_tiv <verdict> — artifact-side null with TR5: null (explicit JS null).
terminal_null_artifact_null_tiv() {
    VERD="$1" node -e "
const e = {
  id: 'run-0011', outcome: 'terminal', cause: 'step-complete:user_verification',
  tr_ids: ['TR5'], freshness_key: null, verdict: process.env.VERD,
  sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': null },
  trigger_input_keys: { TR5: null },
};
process.stdout.write(JSON.stringify({ ledger: [e], last_terminal_run_id: 'run-0011', audit_verdict_summary: null }));
"
}

# terminal_null_artifact_num_tiv <verdict> — artifact-side null with TR5: 42 (non-string number).
terminal_null_artifact_num_tiv() {
    VERD="$1" node -e "
const e = {
  id: 'run-0011', outcome: 'terminal', cause: 'step-complete:user_verification',
  tr_ids: ['TR5'], freshness_key: null, verdict: process.env.VERD,
  sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': null },
  trigger_input_keys: { TR5: 42 },
};
process.stdout.write(JSON.stringify({ ledger: [e], last_terminal_run_id: 'run-0011', audit_verdict_summary: null }));
"
}

# terminal_null_artifact_input_ver <verdict> <iv> — artifact-side null with run.input_version
# present but no trigger_input_keys (tests no-fallback behavior in inputVersionMatches).
terminal_null_artifact_input_ver() {
    VERD="$1" IV="$2" node -e "
const e = {
  id: 'run-0011', outcome: 'terminal', cause: 'step-complete:user_verification',
  tr_ids: ['TR5'], freshness_key: null, verdict: process.env.VERD,
  sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': null },
  input_version: process.env.IV,
};
process.stdout.write(JSON.stringify({ ledger: [e], last_terminal_run_id: 'run-0011', audit_verdict_summary: null }));
"
}

# --- premise guard: the null repo really produces a null code side (no false-green) ---
REPO_NULL="$(mk_null_repo "$WORK/repo-null")"
assert_eq "0a: the null-repo fixture has a null input_version" "$(input_version_at "$REPO_NULL")" "null"
assert_eq "0b: the null-repo fixture has a null freshness_key" "$(fresh_key_at "$REPO_NULL")" "null"

# --- 1-3: primary regression — CONTINUE terminal + null code side approves and never
# loops. FAIL-BEFORE-FIX: current code arms (blocks) on !currentFk. ---
seed_state "$(terminal_null CONTINUE)" >/dev/null
out1="$(gate_at "$SENTINEL_UV" "$REPO_NULL")"
assert_eq "1: a CONTINUE terminal with a null code side is approved (self-recovering)" \
    "$(decision_of "$out1")" "approve"
assert_eq "2: the self-recovering approve arms no audit run" \
    "$(state_field audit.audit_phase)" "null"
out1b="$(gate_at "$SENTINEL_UV" "$REPO_NULL")"
assert_eq "3: re-issuing the sentinel still approves — no arm/deny loop" \
    "$(decision_of "$out1b")" "approve"

# --- 4: WARN terminal + null code side stays fail-closed (allow-list is CONTINUE-only) ---
seed_state "$(terminal_null WARN)" >/dev/null
out="$(gate_at "$SENTINEL_UV" "$REPO_NULL")"
assert_eq "4: a WARN terminal with a null code side is NOT approved (arms, fail-closed)" \
    "$(decision_of "$out")" "block"
assert_eq "4b: WARN+null arms the audit phase (arm() was invoked)" \
    "$(state_field audit.audit_phase)" "pending"

# --- 5-6: C2 — a missing or malformed verdict stays fail-closed under a null code side ---
seed_state "$(terminal_null __MISSING__)" >/dev/null
assert_eq "5: a terminal with a MISSING verdict is not approved (fail-closed)" \
    "$(decision_of "$(gate_at "$SENTINEL_UV" "$REPO_NULL")")" "block"
seed_state "$(terminal_null OK)" >/dev/null
assert_eq "6: a terminal with a malformed verdict ('OK') is not approved (fail-closed)" \
    "$(decision_of "$(gate_at "$SENTINEL_UV" "$REPO_NULL")")" "block"

# --- 7: BLOCK terminal + null code side stays fail-closed ---
seed_state "$(terminal_null BLOCK)" >/dev/null
out7="$(gate_at "$SENTINEL_UV" "$REPO_NULL")"
assert_eq "7: a BLOCK terminal with a null code side is not approved (fail-closed)" \
    "$(decision_of "$out7")" "block"
assert_eq "7b: BLOCK+null arms the audit phase (arm() was invoked)" \
    "$(state_field audit.audit_phase)" "pending"

# --- 8: a later terminal BLOCK (TR6) postdating a CONTINUE TR5 + null code side blocks ---
seed_state "$(two_terminal_runs CONTINUE null BLOCK)" >/dev/null
out8="$(gate_at "$SENTINEL_UV" "$REPO_NULL")"
assert_eq "8: a later TR6 BLOCK is honored even with a null code side (fail-closed)" \
    "$(decision_of "$out8")" "block"
assert_eq "8b: TR6 BLOCK+null arms the audit phase (arm() was invoked)" \
    "$(state_field audit.audit_phase)" "pending"

# --- 9: no terminal TR5 run at all + null code side arms the full set (fail-closed) ---
seed_state '{"ledger":[]}' >/dev/null
out9="$(gate_at "$SENTINEL_UV" "$REPO_NULL")"
assert_eq "9: an absent terminal TR5 run is not approved on a null code side (fail-closed)" \
    "$(decision_of "$out9")" "block"
assert_eq "9b: no TR5+null arms the audit phase (arm() was invoked)" \
    "$(state_field audit.audit_phase)" "pending"

# --- 10-11: CPR-SC — an artifact-side null (input_version computable, a plan file
# missing) must NOT self-recover. Uses $REPO (main resolvable → non-null input_version)
# with outline.md deleted so freshness_key is null but input_version is not. ---
rm -f "$WORK/plans/$SID-outline.md"
assert_ne "10: with a plan artifact missing the code side is still computable (non-null)" \
    "$(input_version)" "null"
# --- 10c/10d: filterNullKeySubChecks unit — artifact-side null excludes recurrence-patterns ---
# FAIL-BEFORE-FIX: armJudgmentSet / buildJudgmentSet do not yet filter on freshness_key==null.
result_10c="$(AN="$AGENTS_NODE" node -e "
const m = require(process.env.AN + '/hooks/workflow-gate/user-verified-audit.js');
const freshness = { freshness_key: null, input_version: 'abc123', artifact_keys: {} };
const ids = m.armJudgmentSet({}, freshness, 'test', '/nonexistent');
process.stdout.write(JSON.stringify(ids));
" 2>/dev/null)"
assert_nomatch "10c: armJudgmentSet artifact-side null excludes recurrence-patterns" \
    "$result_10c" '"recurrence-patterns"'
assert_match "10c-b: armJudgmentSet still includes detail-code" "$result_10c" '"detail-code"'

result_10d="$(AN="$AGENTS_NODE" node -e "
const { buildJudgmentSet, coalesce } = require(process.env.AN + '/hooks/supervisor-guard/audit-arm.js');
const candidates = [{ tr_id: 'TR5', sub_checks: ['recurrence-patterns','detail-code','scope-drift','systemic-risk'], cause: 'step-complete:user_verification' }];
const coalesced = coalesce(candidates);
const freshness = { freshness_key: null, input_version: 'abc123', artifact_keys: {} };
const ids = buildJudgmentSet({}, coalesced, freshness, 'test', '/nonexistent');
process.stdout.write(JSON.stringify(ids));
" 2>/dev/null)"
assert_nomatch "10d: buildJudgmentSet artifact-side null excludes recurrence-patterns" \
    "$result_10d" '"recurrence-patterns"'
assert_match "10d-b: buildJudgmentSet still includes detail-code" "$result_10d" '"detail-code"'

# --- 10e: Stage 1 BLOCK terminal + artifact-side null — arm excludes recurrence-patterns ---
# FAIL-BEFORE-FIX: Stage 1 direct arm still includes recurrence-patterns before filterNullKeySubChecks.
# outline.md was deleted above (line ~138); freshness_key is null, input_version is non-null.
rm -f "$WORK/plans/$SID-outline.md"
seed_state "$(terminal_null BLOCK)" >/dev/null
out_10e="$(gate "$SENTINEL_UV")"
assert_eq "10e: BLOCK + artifact-side null still blocks (fail-closed)" \
    "$(decision_of "$out_10e")" "block"
assert_nomatch "10e-b: Stage 1 arm reason excludes recurrence-patterns" \
    "$(reason_of "$out_10e")" "recurrence-patterns"
write_plans

# --- 11: CONTINUE + artifact-side null + matching trigger_input_keys.TR5 → approved ---
# FAIL-BEFORE-FIX: selfRecovering does not cover artifact-side null before the fix.
rm -f "$WORK/plans/$SID-outline.md"
IV_11="$(input_version)"
seed_state "$(terminal_null_artifact CONTINUE "$IV_11")" >/dev/null
assert_eq "11: CONTINUE + artifact-side null + matching trigger_input_keys.TR5 → approved" \
    "$(decision_of "$(gate "$SENTINEL_UV")")" "approve"
write_plans

# --- 11b-11e: inputVersionMatches fail-closed cases — block regardless of fix ---
# 11b: stale trigger_input_keys.TR5 — stored key predates current input_version → block.
rm -f "$WORK/plans/$SID-outline.md"
seed_state "$(terminal_null_artifact CONTINUE "stale-iv-not-matching-current")" >/dev/null
assert_eq "11b: CONTINUE + artifact-side null + stale trigger_input_keys.TR5 → block" \
    "$(decision_of "$(gate "$SENTINEL_UV")")" "block"
write_plans

# 11c: trigger_input_keys.TR5 is null (explicit JS null) → fail-closed.
rm -f "$WORK/plans/$SID-outline.md"
seed_state "$(terminal_null_artifact_null_tiv CONTINUE)" >/dev/null
assert_eq "11c: CONTINUE + artifact-side null + null trigger_input_keys.TR5 → block (fail-closed)" \
    "$(decision_of "$(gate "$SENTINEL_UV")")" "block"
write_plans

# 11d: trigger_input_keys.TR5 is a number (non-string) → fail-closed.
rm -f "$WORK/plans/$SID-outline.md"
seed_state "$(terminal_null_artifact_num_tiv CONTINUE)" >/dev/null
assert_eq "11d: CONTINUE + artifact-side null + non-string trigger_input_keys.TR5 → block (fail-closed)" \
    "$(decision_of "$(gate "$SENTINEL_UV")")" "block"
write_plans

# 11e-a: no trigger_input_keys at all (old terminal_null path) → block (no approval without the key).
rm -f "$WORK/plans/$SID-outline.md"
seed_state "$(terminal_null CONTINUE)" >/dev/null
assert_eq "11e-a: CONTINUE + artifact-side null + no trigger_input_keys → block (fail-closed)" \
    "$(decision_of "$(gate "$SENTINEL_UV")")" "block"
write_plans

# 11e-b: run.input_version present but no trigger_input_keys → block (no fallback to run.input_version).
rm -f "$WORK/plans/$SID-outline.md"
IV_11eb="$(input_version)"
seed_state "$(terminal_null_artifact_input_ver CONTINUE "$IV_11eb")" >/dev/null
assert_eq "11e-b: CONTINUE + artifact-side null + run.input_version present but no trigger_input_keys → block (no fallback)" \
    "$(decision_of "$(gate "$SENTINEL_UV")")" "block"
write_plans

# --- 12-13: non-null freshness — existing behavior is unchanged (settled approves,
# a moved code side arms). Guards that the fix touches only the null path. ---
FK_REPO="$(fresh_key)"
seed_state "$(terminal_run CONTINUE "$FK_REPO")" >/dev/null
assert_eq "12: a fresh (non-null) settled CONTINUE run still approves" \
    "$(decision_of "$(gate "$SENTINEL_UV")")" "approve"
printf 'code moved after the verdict\n' > "$REPO/seed.txt"
assert_eq "13: a moved code side (non-null) still arms — not waved through" \
    "$(decision_of "$(gate "$SENTINEL_UV")")" "block"
printf 'seed\n' > "$REPO/seed.txt"

# --- 14-19: C1 end-to-end recovery. A stale (no merge base) repo is synced by giving
# HEAD a protected-branch ancestor; the merge gate must still DENY until a fresh TR5
# terminal run is recorded, then PERMIT. supervisor-check.js is unchanged. ---
REPO3="$(mk_null_repo "$WORK/repo3")"
# (i) loop stop: CONTINUE + null code side approves the sentinel and terminalizes nothing.
seed_state "$(terminal_null CONTINUE)" >/dev/null
out="$(gate_at "$SENTINEL_UV" "$REPO3")"
assert_eq "14: (i) the WE-8 loop stops — CONTINUE + null code side approves" \
    "$(decision_of "$out")" "approve"
assert_eq "15: (i) checkUserVerifiedAudit arms nothing — the ledger's terminal run is unchanged" \
    "$(state_field audit.last_terminal_run_id)" "run-0011"
# (i-supplementary) while still stale, the merge gate denies on an uncomputable key.
assert_eq "16: (ii) while still stale, the merge gate denies (freshness uncomputable)" \
    "$(decision_of "$(gate_at "$MERGE_CMD" "$REPO3")")" "block"
# (ii) sync: give HEAD a main ancestor so the merge base resolves (input_version non-null).
git -C "$WORK/repo3" branch main HEAD
assert_ne "17: (ii) after sync the code side is computable (non-null)" \
    "$(input_version_at "$REPO3")" "null"
# (iii) synced but the stored TR5 run's null freshness != the fresh key → DENY (fail-closed).
assert_eq "18: (iii) syncing alone still denies the merge — stored null != fresh key" \
    "$(decision_of "$(gate_at "$MERGE_CMD" "$REPO3")")" "block"
# (iv+v) record a fresh TR5 terminal run (audit re-run), then the merge PERMITs.
FK3="$(fresh_key_at "$REPO3")"
assert_match "19a: (iv) the synced repo yields a real fresh key to certify against" \
    "$FK3" '^[0-9a-f]{64}$'
seed_state "$(terminal_run CONTINUE "$FK3")" >/dev/null
assert_eq "19: (v) after a fresh TR5 terminal run is recorded, the merge is permitted" \
    "$(decision_of "$(gate_at "$MERGE_CMD" "$REPO3")")" "approve"

# --- 20-22: #2323 main real-world scenario — prior CONTINUE terminal stored with a
# non-null freshness_key (recorded when repo was healthy) + null code side (AGENTS_CONFIG_DIR
# became stale: merge base gone) → selfRecovering=true → approveFn, no arm, no loop.
# FAIL-BEFORE-FIX: Stage 2 (!currentFk) arms on a stale-now-null code side even though
# the terminal was settled against a valid key in a prior healthy state.
PRIOR_FK="abc123def456abc1abc123def456abc1abc123def456abc1abc123def456abc1"
seed_state "$(terminal_run CONTINUE "$PRIOR_FK")" >/dev/null
out20="$(gate_at "$SENTINEL_UV" "$REPO_NULL")"
assert_eq "20: prior CONTINUE (non-null stored key) + null code side (stale AGENTS_CONFIG_DIR) is approved" \
    "$(decision_of "$out20")" "approve"
assert_eq "21: the self-recovering approve arms no audit run" \
    "$(state_field audit.audit_phase)" "null"
out20b="$(gate_at "$SENTINEL_UV" "$REPO_NULL")"
assert_eq "22: re-issuing the sentinel still approves — no arm/deny loop" \
    "$(decision_of "$out20b")" "approve"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
