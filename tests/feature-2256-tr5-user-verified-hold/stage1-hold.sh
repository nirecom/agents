#!/usr/bin/env bash
# tests/feature-2256-tr5-user-verified-hold/stage1-hold.sh
# Tests: hooks/workflow-gate.js, hooks/lib/audit-ledger.js, hooks/lib/diff-fingerprint.js
# Tags: supervisor, tr5, user-verified, hold, freshness, TL2, scope:issue-specific
# #2256 S5-b stage 1 — the unresolved-BLOCK hold keyed on freshness_key.

# Parent: tests/feature-2256-tr5-user-verified-hold.sh

# The four branches are: BLOCK + key match deny, BLOCK + key mismatch arm,
# non-BLOCK pass, key uncomputable full re-audit. Two regression cases follow:
# an untouched second attempt must still pass (no over-arming), and a detail.md
# edit under a standing BLOCK must re-arm rather than stay denied forever.

set -uo pipefail
# shellcheck source=./_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

FK0="$(fresh_key)"

# --- 1-3: BLOCK + freshness_key match ⇒ deny ---
seed_state "$(terminal_run BLOCK "$FK0")" >/dev/null
out="$(gate "$SENTINEL_UV")"
assert_eq "1: BLOCK with a matching freshness_key denies the sentinel" "$(decision_of "$out")" "block"
assert_match "2: the deny reason names the unresolved BLOCK hold" "$(reason_of "$out")" 'BLOCK'
assert_eq "3: a denied stage-1 hold arms no new audit run" "$(state_field audit.audit_phase)" "null"

# --- 4-6: BLOCK + freshness_key mismatch ⇒ arm a fresh audit, do not stand on the stale hold ---
seed_state "$(terminal_run BLOCK "0000000000000000000000000000000000000000000000000000000000000000")" >/dev/null
out="$(gate "$SENTINEL_UV")"
assert_ne "4: a stale BLOCK key does not reuse the old deny reason" "$(reason_of "$out")" ""
assert_match "5: the mismatching BLOCK arms a fresh audit run" "$(state_field audit.audit_run_id)" '^run-[0-9]{4}$'
assert_match "6: the re-armed run is pending or in_progress" "$(state_field audit.audit_phase)" '^(pending|in_progress)$'

# --- 7-9: non-BLOCK terminal run with a matching key ⇒ the sentinel passes untouched ---
seed_state "$(terminal_run CONTINUE "$FK0")" >/dev/null
out="$(gate "$SENTINEL_UV")"
assert_eq "7: a fresh CONTINUE verdict lets the sentinel through" "$(decision_of "$out")" "approve"
assert_eq "8: passing stage 1 arms nothing" "$(state_field audit.audit_phase)" "null"
seed_state "$(terminal_run WARN "$FK0")" >/dev/null
assert_eq "9: a fresh WARN verdict also lets the sentinel through" "$(decision_of "$(gate "$SENTINEL_UV")")" "approve"

# --- 10-12: freshness_key uncomputable ⇒ full re-audit, never a silent pass ---
seed_state "$(terminal_run BLOCK "$FK0")" >/dev/null
mv "$WORK/plans/$SID-detail.md" "$WORK/plans/$SID-detail.md.bak"
nokey="$(fresh_key)"
assert_eq "10: removing detail.md makes the freshness key uncomputable" "$nokey" "null"
out="$(gate "$SENTINEL_UV")"
assert_ne "11: an uncomputable key never yields a bare approve" "$(decision_of "$out")" "approve"
assert_match "12: an uncomputable key forces a full re-audit run" "$(state_field audit.audit_run_id)" '^run-[0-9]{4}$'
mv "$WORK/plans/$SID-detail.md.bak" "$WORK/plans/$SID-detail.md"

# --- 13-15: over-arming regression — an untouched second attempt must pass ---
seed_state "$(terminal_run CONTINUE "$(fresh_key)")" >/dev/null
first="$(gate "$SENTINEL_UV")"
second="$(gate "$SENTINEL_UV")"
assert_eq "13: the first attempt passes" "$(decision_of "$first")" "approve"
assert_eq "14: an untouched second attempt passes too" "$(decision_of "$second")" "approve"
assert_eq "15: neither attempt armed an audit run" "$(state_field audit.audit_run_id)" "none"

# --- 16-18: a detail.md edit under a standing BLOCK re-arms instead of denying forever ---
seed_state "$(terminal_run BLOCK "$(fresh_key)")" >/dev/null
assert_eq "16: the standing BLOCK denies while nothing has moved" \
    "$(decision_of "$(gate "$SENTINEL_UV")")" "block"
write_plans i1 o1 "$DETAIL_BODY
- third.txt
"
out="$(gate "$SENTINEL_UV")"
assert_ne "17: editing detail.md breaks the hold's key match" "$(fresh_key)" "$(printf '%s' "$FK0")"
assert_match "18: the edited plan re-arms an audit run instead of denying forever" \
    "$(state_field audit.audit_run_id)" '^run-[0-9]{4}$'
write_plans

# --- 19-21: WE-7 — a sentinel issued with no merge command still traverses TR5 ---
seed_state "$(terminal_run BLOCK "$(fresh_key)")" >/dev/null
we7="$(gate "$SENTINEL_UV")"
assert_eq "19: a bare sentinel with no merge command still hits the TR5 hold" \
    "$(decision_of "$we7")" "block"
assert_match "20: the WE-7 deny cites the audit hold, not a merge gate" \
    "$(reason_of "$we7")" 'BLOCK'
assert_nomatch "21: the WE-7 deny is not the pre-merge backstop" \
    "$(reason_of "$we7")" 'freshness-backstop'

# --- 22-24: a later TR6 BLOCK postdating a fresh non-BLOCK TR5 still holds ---
# Guards user-verified-audit.js:174/176 (laterBlockExists in the Stage 1 gate).
# A fresh CONTINUE TR5 alone passes (cases 7-8); adding a later terminal TR6 BLOCK
# must flip that to a hold. Deleting `|| laterBlockExists` at line 176 lets Stage 2
# re-approve the fresh CONTINUE (the case-7 path) — this case fails then.
FK1="$(fresh_key)"
seed_state "$(two_terminal_runs CONTINUE "$FK1" BLOCK)" >/dev/null
out="$(gate "$SENTINEL_UV")"
assert_eq "22: a later TR6 BLOCK holds the sentinel despite a fresh CONTINUE TR5" \
    "$(decision_of "$out")" "block"
assert_match "23: the hold cites the unresolved BLOCK" "$(reason_of "$out")" 'BLOCK'
assert_eq "24: the held sentinel arms no new audit run" "$(state_field audit.audit_phase)" "null"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
