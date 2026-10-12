#!/usr/bin/env bash
# Tests: bin/sweep-plans.sh, bin/sweep-plans/gate-artifact.js
# Tags: scope:common, TL2, sweep, plans, approval-gate, gate-signature, pwsh-not-required
# Part file of tests/bin/feature-sweep-plans-approval-gate.sh (sourced; uses its helpers).
# Pass flow: approval, single use, skips (not-a-candidate / changed-since-gate),
# token validation, --dry-run, the empty-prefix bucket and the deletion scope.

case_begin "G4-approve-one-of-two" "bin/sweep-plans/gate-artifact.js"
reset_gate
P="$(new_dir g4)"; mk_old "$P" "${GA[@]}" "${GB[@]}"
pass1 "$P"
has_line "G4 pass 1 shows session B too" "$OUT" "^$B$TAB"
AF_G4="$(approve_file "$A")"; GID_G4="$GID"; P_G4="$P"
pass2 "$P" "$GID" "$AF_G4" --ci-mode
check "G4 pass 2 exits 0" "0" "$RC"
for n in "${GA[@]}"; do expect_gone "G4 approved A: $n is removed" "$P/$n"; done
expect_all_present "G4 unapproved B" "$P" "${GB[@]}"
check "G4 files_plan_removed=1" "1" "$(jget "$OUT" files_plan_removed)"
check "G4 files_user_requested_removed=1" "1" "$(jget "$OUT" files_user_requested_removed)"
expect_gone "G4 the gate artifact is consumed" "$GATE_FILE"
case_end

case_begin "G13-gate-is-single-use" "bin/sweep-plans.sh"
pass2 "$P_G4" "$GID_G4" "$AF_G4"
check "G13 repeating pass 2 after a success exits 2 (artifact consumed)" "2" "$RC"
has_line "G13 the error names the missing gate artifact" "$ERR" \
  "^ERROR: sweep-plans: approval gate artifact missing or mismatched; nothing deleted$"
expect_all_present "G13" "$P_G4" "${GB[@]}"
case_end

case_begin "G5-approved-group-turned-young" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g5)"; mk_old "$P" "${GA[@]}"
pass1 "$P"
touch "$P/$A-intent.md"
pass2 "$P" "$GID" "$(approve_file "$A")"
check "G5 pass 2 exits 0" "0" "$RC"
expect_all_present "G5 young A" "$P" "${GA[@]}"
has_line "G5 the skip is reported as not-a-candidate" "$ALL" "^APPROVAL-SKIP: session=$A reason=not-a-candidate$"
case_end

case_begin "G6-bad-token-or-missing-approval-file" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g6)"; mk_old "$P" "${GA[@]}"
pass1 "$P"
mk_old "$P" "$RAW_A"
pass2 "$P" "$GID" "$(approve_file "../x")"
check "G6 a malformed token exits 2" "2" "$RC"
expect_all_present "G6 malformed token (non-plan included)" "$P" "${GA[@]}" "$RAW_A"
pass1 "$P"
mk_old "$P" "$RAW_A"
pass2 "$P" "$GID" "$T_ROOT/no-such-approved-file.txt"
check "G6 a missing approval file exits 2" "2" "$RC"
expect_all_present "G6 missing approval file (non-plan included)" "$P" "${GA[@]}" "$RAW_A"
case_end

case_begin "G7-pass2-dry-run" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g7)"; mk_old "$P" "${GA[@]}"
pass1 "$P"
pass2 "$P" "$GID" "$(approve_file "$A")" --dry-run
check "G7 pass 2 --dry-run exits 0" "0" "$RC"
expect_all_present "G7 --dry-run" "$P" "${GA[@]}"
has_line "G7 a would-remove line for the plan file" "$ALL" "^DRY-RUN: would remove plan $A-intent\.md$"
has_line "G7 a would-remove line for the user-requested file" "$ALL" "^DRY-RUN: would remove user-requested $A-user-requested-progress\.md$"
expect_present "G7 --dry-run does not consume the gate artifact" "$GATE_FILE"
case_end

case_begin "G8-empty-prefix-exception" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g8)"; mk_old "$P" "-intent.md" "-detail-codex-round-1-raw.md"
run_sweep "$P"
expect_gone "G8 flagless: the empty-prefix non-plan raw is removed" "$P/-detail-codex-round-1-raw.md"
expect_present "G8 flagless: the empty-prefix plan -intent.md is kept" "$P/-intent.md"
lacks_line "G8 flagless: no PLAN-CANDIDATE line for the @empty bucket" "$ALL" "^PLAN-CANDIDATE:"
has_line "G8 flagless: the hint counts the @empty plan file" "$ALL" "^plan / user-requested files kept: 1 in 1 sessions "
pass1 "$P"
has_line "G8 pass 1 shows an @empty row" "$OUT" "^@empty$TAB"
pass2 "$P" "$GID" "$(approve_file "@empty")"
check "G8 pass 2 exits 0" "0" "$RC"
expect_gone "G8 approving @empty removes -intent.md" "$P/-intent.md"
case_end

# G8b: the empty-prefix bucket's user-requested member follows the same approval-only rule.
UR_EMPTY="-user-requested-topic.md"
case_begin "G8b-empty-prefix-user-requested" "bin/sweep-plans.sh"
reset_gate
UR_CLASS="$(printf '\0%s\0' "$UR_EMPTY" | node "$(np "$SCRIPT_CHECKOUT_ROOT/bin/sweep-plans/retention-class.js")" 2>/dev/null | tr -d '\r\n')"
check "G8b precondition: the bridge classifies $UR_EMPTY as user-requested" "user-requested" "$UR_CLASS"
P="$(new_dir g8b)"; mk_old "$P" "$UR_EMPTY"
run_sweep "$P" --ci-mode
check "G8b flagless run exits 0" "0" "$RC"
check "G8b precondition: the #847 allowlist admits it (files_skipped_unrecognized=0)" "0" "$(jget "$OUT" files_skipped_unrecognized)"
check "G8b flagless: files_user_requested_candidates=1" "1" "$(jget "$OUT" files_user_requested_candidates)"
expect_present "G8b flagless: the empty-prefix user-requested file is kept" "$P/$UR_EMPTY"
lacks_line "G8b flagless: no USER-REQUESTED-CANDIDATE line" "$ALL" "^USER-REQUESTED-CANDIDATE:"
check "G8b flagless: the @empty bucket is an approval candidate" "1" "$(jget "$OUT" groups_approval_candidates)"
pass1 "$P"
has_line "G8b pass 1 shows an @empty row with 0 plan / 1 user-requested" "$OUT" "^@empty${TAB}0${TAB}1${TAB}"
pass2 "$P" "$GID" "$(approve_file "@empty")" --ci-mode
check "G8b pass 2 exits 0" "0" "$RC"
expect_gone "G8b approving @empty removes $UR_EMPTY" "$P/$UR_EMPTY"
check "G8b files_user_requested_removed=1" "1" "$(jget "$OUT" files_user_requested_removed)"
case_end

case_begin "G9-unshown-token-rejected" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g9)"; mk_old "$P" "${GA[@]}"
pass1 "$P"
mk_old "$P" "$C-intent.md" "$RAW_A"
pass2 "$P" "$GID" "$(approve_file "$A" "$C")"
check "G9 approving a group aged in after pass 1 exits 2" "2" "$RC"
has_line "G9 the error names the unshown token" "$ERR" \
  "^ERROR: sweep-plans: approved token not shown in the gate: $C; nothing deleted$"
expect_all_present "G9 aged-in C (non-plan included)" "$P" "${GA[@]}" "$C-intent.md" "$RAW_A"
reset_gate; rm -f "$P/$C-intent.md"
pass1 "$P"
mk_old "$P" "$RAW_A"
pass2 "$P" "$GID" "$(approve_file "$A" "$D_UNSHOWN")"
check "G9 a well-formed but unshown token exits 2" "2" "$RC"
expect_all_present "G9 mistyped token (non-plan included)" "$P" "${GA[@]}" "$RAW_A"
case_end

case_begin "G10-changed-since-gate" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g10)"; mk_old "$P" "${GA[@]}"
pass1 "$P"
mk_old "$P" "$A-detail.md"
pass2 "$P" "$GID" "$(approve_file "$A")"
check "G10 pass 2 exits 0" "0" "$RC"
expect_all_present "G10 changed A" "$P" "${GA[@]}" "$A-detail.md"
has_line "G10 the skip is reported as changed-since-gate" "$ALL" "^APPROVAL-SKIP: session=$A reason=changed-since-gate$"
case_end

# G14: the user answers "do not delete" at SP-3, so the skill never runs pass 2.
case_begin "G14-approval-declined-pass1-only" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g14)"; mk_old "$P" "${GA[@]}" "$RAW_A"
pass1 "$P"
check "G14 pass 1 exits 0" "0" "$RC"
has_line "G14 the gate block is printed" "$OUT" "^<<<APPROVAL-GATE-SP3$"
has_line "G14 the block lists session A" "$OUT" "^$A$TAB"
expect_all_present "G14 declined (no pass 2)" "$P" "${GA[@]}"
expect_gone "G14 pass 1 still removes non-plan like a flagless run" "$P/$RAW_A"
expect_present "G14 the unconsumed gate artifact stays for a later pass 2" "$GATE_FILE"
case_end

case_begin "G15-pass2-empty-approval-file" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g15)"; mk_old "$P" "${GA[@]}"
pass1 "$P"
mk_old "$P" "$RAW_A"
pass2 "$P" "$GID" "$(approve_file)" --ci-mode
check "G15 pass 2 with no approved token exits 0 (vacuous validation)" "0" "$RC"
expect_all_present "G15 nothing approved" "$P" "${GA[@]}"
check "G15 files_plan_removed=0" "0" "$(jget "$OUT" files_plan_removed)"
check "G15 files_user_requested_removed=0" "0" "$(jget "$OUT" files_user_requested_removed)"
expect_gone "G15 pass 2 removes non-plan like a flagless run" "$P/$RAW_A"
expect_gone "G15 the validated gate artifact is consumed" "$GATE_FILE"
case_end

# G7b: pass 1 with --dry-run deletes nothing and, since gate_write is skipped under DRY_RUN, writes no gate.
case_begin "G7b-pass1-dry-run-writes-nothing" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g7b)"; mk_old "$P" "${GA[@]}" "$RAW_A"
run_sweep "$P" --include-plan-and-user-requested --gate-session "$GATE_SID" --dry-run
check "G7b pass 1 --dry-run exits 0" "0" "$RC"
expect_all_present "G7b pass 1 --dry-run" "$P" "${GA[@]}" "$RAW_A"
has_line "G7b the non-plan is only previewed" "$ALL" "^DRY-RUN: would remove non-plan $RAW_A$"
has_line "G7b the plan candidate is still listed" "$ALL" "^PLAN-CANDIDATE: session=$A "
expect_gone "G7b pass 1 --dry-run writes no gate artifact" "$GATE_FILE"
lacks_line "G7b pass 1 --dry-run prints no gate block" "$ALL" "^<<<APPROVAL-GATE-SP3$"
case_end

# G4b: a non-plan newer than the plan files must not enter the gate signature or its newest_epoch.
case_begin "G4b-non-plan-does-not-perturb-gate" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g4b)"; mk_old "$P" "${GA[@]}"
printf 'x\n' > "$P/$RAW_A"; backdate_days 40 "$P/$RAW_A"
lt_mtime "G4b precondition: the non-plan is newer than the plan file" "$P/$A-intent.md" "$P/$RAW_A"
pass1 "$P"
check "G4b pass 1 exits 0" "0" "$RC"
expect_gone "G4b pass 1 removes the old non-plan" "$P/$RAW_A"
pass2 "$P" "$GID" "$(approve_file "$A")" --ci-mode
check "G4b pass 2 exits 0" "0" "$RC"
lacks_line "G4b no changed-since-gate skip" "$ALL" "^APPROVAL-SKIP: session=$A reason=changed-since-gate$"
for n in "${GA[@]}"; do expect_gone "G4b approved A: $n is removed" "$P/$n"; done
check "G4b files_plan_removed=1" "1" "$(jget "$OUT" files_plan_removed)"
check "G4b files_user_requested_removed=1" "1" "$(jget "$OUT" files_user_requested_removed)"
case_end

# G16: touching a non-newest file keeps newest_epoch but must still change the signature.
case_begin "G16-non-newest-touch-detected" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g16)"; mkdir -p "$P"
printf 'x\n' > "$P/$A-intent.md"; backdate_days 60 "$P/$A-intent.md"
printf 'x\n' > "$P/$A-detail.md"; backdate_days 50 "$P/$A-detail.md"
lt_mtime "G16 precondition: intent is older than detail" "$P/$A-intent.md" "$P/$A-detail.md"
pass1 "$P"
check "G16 pass 1 exits 0" "0" "$RC"
has_line "G16 pass 1 shows session A" "$OUT" "^$A$TAB"
M_BEFORE="$(mtime_of "$P/$A-intent.md")"
backdate_days 55 "$P/$A-intent.md"
if (( "$(mtime_of "$P/$A-intent.md")" > M_BEFORE )); then pass "G16 precondition: intent mtime changed"; else fail "G16 precondition: intent mtime changed" "unchanged=$M_BEFORE"; fi
lt_mtime "G16 precondition: detail stays the newest" "$P/$A-intent.md" "$P/$A-detail.md"
pass2 "$P" "$GID" "$(approve_file "$A")"
check "G16 pass 2 exits 0" "0" "$RC"
has_line "G16 the skip is reported as changed-since-gate" "$ALL" "^APPROVAL-SKIP: session=$A reason=changed-since-gate$"
expect_all_present "G16 touched A" "$P" "$A-intent.md" "$A-detail.md"
case_end

# G18: approval widens deletion to plan + user-requested only; an aged unknown file stays.
UNK_A="$A-x-history-staging.md"
case_begin "G18-approved-group-keeps-unknown" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g18)"; mk_old "$P" "${GA[@]}" "$UNK_A"
pass1 "$P"
check "G18 pass 1 exits 0" "0" "$RC"
has_line "G18 pass 1 shows session A" "$OUT" "^$A$TAB"
pass2 "$P" "$GID" "$(approve_file "$A")" --ci-mode
check "G18 pass 2 exits 0" "0" "$RC"
check "G18 precondition: the classifier counts one unknown file" "1" "$(jget "$OUT" files_unknown_kept)"
for n in "${GA[@]}"; do expect_gone "G18 approved A: $n is removed" "$P/$n"; done
expect_present "G18 approved A: the aged unknown $UNK_A is kept" "$P/$UNK_A"
check "G18 files_plan_removed=1" "1" "$(jget "$OUT" files_plan_removed)"
check "G18 files_user_requested_removed=1" "1" "$(jget "$OUT" files_user_requested_removed)"
check "G18 files_removed=2 (unknown not counted)" "2" "$(jget "$OUT" files_removed)"
case_end
