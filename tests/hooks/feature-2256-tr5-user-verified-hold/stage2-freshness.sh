#!/usr/bin/env bash
# tests/hooks/feature-2256-tr5-user-verified-hold/stage2-freshness.sh
# Tests: hooks/workflow-gate.js, hooks/lib/audit-ledger.js, hooks/lib/diff-fingerprint.js
# Tags: supervisor, tr5, freshness, sub-checks, declared-files, TL2, scope:issue-specific
# #2256 S5-c stage 2 — which sub-checks a TR5 re-audit may skip, and which it may not.

# Parent: tests/hooks/feature-2256-tr5-user-verified-hold.sh

# Axis alpha is input_version (the code side); axis beta is the per-artifact sub-check
# key settled through isSubCheckSettled (the plan side). A settled pair skips the
# sub-check; either side moving must bring exactly the sub-checks that depend on it back.

set -uo pipefail
# shellcheck source=./_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# settled_run — a terminal TR5 run whose sub-checks are all settled against the
# current plan artifacts and the current working tree.
settled_run() {
    IV="$(input_version)" \
    KI="$(artifact_key intent)" \
    KIO="$(artifact_key intent,outline)" \
    KIOD="$(artifact_key intent,outline,detail)" \
    FK="$(fresh_key)" \
    DK="$(artifact_key detail)" node -e "
const e = process.env;
process.stdout.write(JSON.stringify({
  ledger: [{
    id: 'run-0021', outcome: 'terminal', cause: 'step-complete:user_verification',
    tr_ids: ['TR3', 'TR4', 'TR5'], verdict: 'CONTINUE', freshness_key: e.FK,
    input_version: e.IV,
    artifact_keys: { intent: e.KI, outline: e.KIO, detail: e.KIOD },
    sub_checks: ['intent-internal', 'intent-outline', 'outline-detail', 'detail-code',
      'scope-drift', 'systemic-risk', 'recurrence-patterns'],
    input_key: {
      'intent-internal': e.KI, 'intent-outline': e.KIO, 'outline-detail': e.KIOD,
      'detail-code': e.IV, 'scope-drift': e.IV, 'systemic-risk': e.IV,
      'recurrence-patterns': e.FK,
    },
  }],
  last_terminal_run_id: 'run-0021',
  audit_verdict_summary: 'CONTINUE',
  declared_files: { snapshot_at: '2026-01-01T00:00:00.000Z', run_id: 'run-0021',
    detail_key: e.DK, files: ['seed.txt', 'extra.txt'], truncated: false },
}));
"
}

subchecks_of_armed() { state_field audit.pending_sub_checks; }

# --- 1-3: both axes settled ⇒ the sentinel passes with no re-audit at all ---
seed_state "$(settled_run)" >/dev/null
out="$(gate "$SENTINEL_UV")"
assert_eq "1: a fully settled run lets the sentinel through" "$(decision_of "$out")" "approve"
assert_eq "2: nothing is re-armed when both axes match" "$(state_field audit.audit_phase)" "null"
assert_eq "3: no new ledger entry is appended" "$(state_field audit.last_terminal_run_id)" "run-0021"

# --- 4-6: axis alpha moves (a code diff) ⇒ the code sub-checks come back ---
seed_state "$(settled_run)" >/dev/null
printf 'code moved after the audit settled\n' > "$REPO/seed.txt"
out="$(gate "$SENTINEL_UV")"
assert_ne "4: a code diff is not waved through" "$(decision_of "$out")" "approve"
assert_match "5: the code diff arms a re-audit" "$(state_field audit.audit_run_id)" '^run-[0-9]{4}$'
assert_match "6: the re-armed run covers the code sub-check" \
    "$(subchecks_of_armed)" 'detail-code'
printf 'seed\n' > "$REPO/seed.txt"

# --- 7-9: axis beta, detail.md ⇒ outline-detail comes back ---
seed_state "$(settled_run)" >/dev/null
write_plans i1 o1 "$DETAIL_BODY
- detail-moved.txt
"
out="$(gate "$SENTINEL_UV")"
assert_ne "7: a detail.md edit is not waved through" "$(decision_of "$out")" "approve"
assert_match "8: the detail edit brings back outline-detail" "$(subchecks_of_armed)" 'outline-detail'
assert_eq "9: the code side stays settled when only detail.md moved" \
    "$(input_version)" "$(state_field audit.ledger.0.input_version)"
write_plans

# --- 10-11: axis beta, outline.md ⇒ intent-outline comes back ---
seed_state "$(settled_run)" >/dev/null
write_plans i1 "o1 revised after the audit"
out="$(gate "$SENTINEL_UV")"
assert_ne "10: an outline.md edit is not waved through" "$(decision_of "$out")" "approve"
assert_match "11: the outline edit brings back intent-outline" "$(subchecks_of_armed)" 'intent-outline'
write_plans

# --- 12-13: axis beta, intent.md ⇒ intent-internal comes back ---
seed_state "$(settled_run)" >/dev/null
write_plans "i1 revised after the audit"
out="$(gate "$SENTINEL_UV")"
assert_ne "12: an intent.md edit is not waved through" "$(decision_of "$out")" "approve"
assert_match "13: the intent edit brings back intent-internal" "$(subchecks_of_armed)" 'intent-internal'
write_plans

# --- 14-16: both axes move together ⇒ every dependent sub-check returns ---
seed_state "$(settled_run)" >/dev/null
printf 'code and plan both moved\n' > "$REPO/seed.txt"
write_plans i1 o1 "$DETAIL_BODY
- both-axes.txt
"
armed="$(gate "$SENTINEL_UV")"
assert_ne "14: both axes moving is not waved through" "$(decision_of "$armed")" "approve"
assert_match "15: the code sub-check returns" "$(subchecks_of_armed)" 'detail-code'
assert_match "16: the plan sub-check returns" "$(subchecks_of_armed)" 'outline-detail'
printf 'seed\n' > "$REPO/seed.txt"
write_plans

# --- 17-20: declared-file narrowing refreshes the snapshot and forces a full re-audit ---
seed_state "$(settled_run)" >/dev/null
write_plans i1 o1 '# detail

## Files to modify

- seed.txt
'
out="$(gate "$SENTINEL_UV")"
assert_ne "17: narrowing the declared files is not waved through" "$(decision_of "$out")" "approve"
assert_eq "18: the declared-files snapshot is refreshed to the narrowed set" \
    "$(state_field audit.declared_files.files)" '["seed.txt"]'
assert_eq "19: the narrowing is recorded on the armed run" \
    "$(state_field audit.ledger.1.declared_files_narrowed)" "true"
assert_match "20: narrowing forces a full re-audit, not a partial one" \
    "$(subchecks_of_armed)" 'recurrence-patterns'
write_plans

# --- 21-23: infinite-loop regression — re-issuing after the verdict settles must pass ---
seed_state "$(settled_run)" >/dev/null
first="$(gate "$SENTINEL_UV")"
second="$(gate "$SENTINEL_UV")"
third="$(gate "$SENTINEL_UV")"
assert_eq "21: the first re-issue passes" "$(decision_of "$first")" "approve"
assert_eq "22: the second re-issue passes" "$(decision_of "$second")" "approve"
assert_eq "23: the third re-issue passes — no arm/deny ping-pong" "$(decision_of "$third")" "approve"

# --- 24-25: a truncated declared-files snapshot always forces the full re-audit ---
seed_state "$(SR="$(settled_run)" node -e "
const s = JSON.parse(process.env.SR);
s.declared_files.truncated = true;
process.stdout.write(JSON.stringify(s));
")" >/dev/null
out="$(gate "$SENTINEL_UV")"
assert_ne "24: a truncated declared-files snapshot is not waved through" \
    "$(decision_of "$out")" "approve"
assert_match "25: the truncated snapshot forces a full re-audit" \
    "$(subchecks_of_armed)" 'recurrence-patterns'

# --- 26-28: a resolved-but-empty state (no terminal TR5 run) arms the FULL
# initial judgment set and blocks — never approves or falls through. Guards the
# first-run branch at user-verified-audit.js `if (!tr5Run) return arm(ALL_SUB_CHECK_IDS…)`;
# without it a fresh session with no prior audit would reach coveredSetSettled on a
# null run and crash, or worse, wave the sentinel through. ---
ALL_SUB_CHECKS='["intent-internal","intent-outline","outline-detail","declared-files-snapshot","detail-code","scope-drift","systemic-risk","recurrence-patterns"]'
seed_state '{"ledger":[]}' >/dev/null
out="$(gate "$SENTINEL_UV")"
assert_eq "26: a first-run (no terminal TR5) sentinel is never waved through" \
    "$(decision_of "$out")" "block"
assert_match "27: the first-run gate arms an initial audit run" \
    "$(state_field audit.audit_phase)" '^(pending|in_progress)$'
assert_eq "28: the first-run arm covers the full initial judgment set, not a subset" \
    "$(subchecks_of_armed)" "$ALL_SUB_CHECKS"

# --- 29-32: a terminal TR5 run whose COVERED set is empty (or missing) is fail-closed.
# coveredSetSettled must return false on covered.length===0 rather than vacuously
# approve on "all settled" over nothing. Base is a fully settled run (case 1 approves
# it) with sub_checks forced to [] / removed; every other axis stays fresh, so the only
# thing that can block is the empty-covered-set guard in user-verified-audit.js
# (`if (covered.length === 0) return false;`). Deleting that line re-approves both,
# because the for-loop over [] is a vacuous truth. ---
seed_state "$(SR="$(settled_run)" node -e "
const s = JSON.parse(process.env.SR);
s.ledger[0].sub_checks = [];
process.stdout.write(JSON.stringify(s));
")" >/dev/null
out="$(gate "$SENTINEL_UV")"
assert_eq "29: an empty covered sub-check set is never waved through (fail-closed)" \
    "$(decision_of "$out")" "block"
assert_match "30: the empty covered set arms a re-audit" \
    "$(state_field audit.audit_phase)" '^(pending|in_progress)$'

seed_state "$(SR="$(settled_run)" node -e "
const s = JSON.parse(process.env.SR);
delete s.ledger[0].sub_checks;
process.stdout.write(JSON.stringify(s));
")" >/dev/null
out="$(gate "$SENTINEL_UV")"
assert_eq "31: a missing covered sub-check set is never waved through (fail-closed)" \
    "$(decision_of "$out")" "block"
assert_match "32: the missing covered set arms a re-audit" \
    "$(state_field audit.audit_phase)" '^(pending|in_progress)$'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
