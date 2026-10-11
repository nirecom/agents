# shellcheck shell=bash
# AD-1 .. AD-5 — the CLI: the single execution point for adoption.
# Tests: tests/bin/feature-1305-adopt-session-state.sh
# Tags: scope:issue-specific

echo ""
echo "=== #1305 AD-1..AD-5: bin/workflow/adopt-session-state ==="

# --- AD-1: --list is the discovery surface that replaces automatic inheritance.
# A recent same-cwd+branch session that is still resumable must be offered.
AD1_D="ad1donor-$$"; AD1_H="ad1heir-$$"
write_state_v2 "$AD1_D" "$CWD" "$BRANCH" "$STEPS_INHERITABLE"
write_state_v2 "$AD1_H" "$CWD" "$BRANCH" "$STEPS_ALL_PENDING"
announce_donor "$AD1_D" "$CWD"
adopt "$AD1_H" "$REPO" --list
assert_eq_desc "AD-1a. --list exits 0" "0" "$ADOPT_RC"
assert_contains "AD-1b. --list names the resumable same-context session" "$AD1_D" "$ADOPT_OUT"
assert_list_row "AD-1c. the candidate's row carries its branch" "$AD1_D" "$BRANCH"

# --- AD-2: --list is a *filtered* view, not a raw directory dump. Offering a
# finished (S1) or plan-less (S3) session would invite the user to adopt state
# that resolveInheritanceDonor itself would refuse.
AD2_S1="ad2s1-$$"; AD2_S3="ad2s3-$$"; AD2_OK="ad2ok-$$"; AD2_H="ad2heir-$$"
write_state_v2 "$AD2_S1" "$CWD" "$BRANCH" "$STEPS_DELIVERED"
write_state_v2 "$AD2_S3" "$CWD" "$BRANCH" "$STEPS_INTENT_DONE"
write_state_v2 "$AD2_OK" "$CWD" "$BRANCH" "$STEPS_INHERITABLE"
write_state_v2 "$AD2_H" "$CWD" "$BRANCH" "$STEPS_ALL_PENDING"
announce_donor "$AD2_S1" "$CWD"; announce_donor "$AD2_S3" "$CWD"; announce_donor "$AD2_OK" "$CWD"
adopt "$AD2_H" "$REPO" --list
assert_contains "AD-2a. positive control: the eligible candidate IS listed" "$AD2_OK" "$ADOPT_OUT"
assert_not_contains_guarded cli_ran "AD-2b. a delivered (deliver complete, S1) session is not offered" "$AD2_S1" "$ADOPT_OUT"
assert_not_contains_guarded cli_ran "AD-2c. clarify_intent complete without intent.md (S3) is not offered" "$AD2_S3" "$ADOPT_OUT"

# AD-2d: approval alone does not finish a session — deliver (the merge) is the
# step after it, so user_verification complete + deliver pending stays offered.
AD2D_AP="ad2dap-$$"; AD2D_H="ad2dheir-$$"
write_state_v2 "$AD2D_AP" "$CWD" "$BRANCH" "$STEPS_APPROVED_NOT_DELIVERED"
write_state_v2 "$AD2D_H" "$CWD" "$BRANCH" "$STEPS_ALL_PENDING"
announce_donor "$AD2D_AP" "$CWD"
adopt "$AD2D_H" "$REPO" --list
assert_eq_desc "AD-2d-rc. --list exits 0" "0" "$ADOPT_RC"
assert_list_row "AD-2d. an approved-but-not-delivered session IS still offered" "$AD2D_AP" "$BRANCH"

# AD-2e: deliver alone decides S1 — deliver complete without user_verification
# complete is still a finished session and must not be offered.
AD2E_DO="ad2edo-$$"; AD2E_H="ad2eheir-$$"
write_state_v2 "$AD2E_DO" "$CWD" "$BRANCH" "$STEPS_DELIVERED_ONLY"
write_state_v2 "$AD2E_H" "$CWD" "$BRANCH" "$STEPS_ALL_PENDING"
announce_donor "$AD2E_DO" "$CWD"
adopt "$AD2E_H" "$REPO" --list
assert_eq_desc "AD-2e-rc. --list exits 0" "0" "$ADOPT_RC"
assert_not_contains_guarded cli_ran "AD-2e. deliver complete without approval is not offered (deliver alone decides S1)" "$AD2E_DO" "$ADOPT_OUT"

# --- AD-3: --from performs the adoption through the SAME applyInheritance the
# hook uses, so the appended events must carry the append-only provenance
# markers (#1733) rather than masquerading as steps this session performed.
AD3_D="ad3donor-$$"; AD3_H="ad3heir-$$"
write_state_v2 "$AD3_D" "$CWD" "$BRANCH" "$STEPS_INHERITABLE"
write_state_v2 "$AD3_H" "$CWD" "$BRANCH" "$STEPS_ALL_PENDING"
announce_donor "$AD3_D" "$CWD"
adopt "$AD3_H" "$REPO" --from "$AD3_D"
assert_eq_desc "AD-3a. --from exits 0 on a valid donor" "0" "$ADOPT_RC"
assert_eq_desc "AD-3b. the heir now has the donor's outline completion" "complete" "$(step_status "$AD3_H" outline)"
SIG3="$(event_signature "$AD3_H")"
assert_contains "AD-3c. adopted events are marked provenance=backfilled" ":backfilled:" "$SIG3"
assert_contains "AD-3d. adopted events are marked origin=session-inherit" ":session-inherit:" "$SIG3"
assert_eq_desc "AD-3e. adopted events record inherited_from=<donor>" "$AD3_D" "$(inherited_from_of "$AD3_H")"

# --- AD-4: the misfire guard. The CLI is user-invokable, so a stray --from must
# not be able to bulldoze a session that has already done real work.
AD4_D="ad4donor-$$"; AD4_H="ad4heir-$$"
write_state_v2 "$AD4_D" "$CWD" "$BRANCH" "$STEPS_INHERITABLE"
write_state_v2 "$AD4_H" "$CWD" "$BRANCH" '{"research":"complete"}'
announce_donor "$AD4_D" "$CWD"
BEFORE4="$(state_cksum "$AD4_H")"
adopt "$AD4_H" "$REPO" --from "$AD4_D"
assert_rc_nonzero "AD-4a. adopting into a non-all-pending heir is refused" "$ADOPT_RC" "$ADOPT_OUT"
assert_eq_guarded cli_ran "AD-4b. the refused heir's state file is byte-identical" "$BEFORE4" "$(state_cksum "$AD4_H")"

# --- AD-5: --from re-validates; being named on the command line is not enough.
# Otherwise the CLI would be a way to launder exactly the mis-inheritance #1305
# is about.
REPO2="$(setup_repo other)"
CWD2="$(resolve_path "$REPO2")"
AD5_MIS="ad5mismatch-$$"; AD5_S1="ad5s1-$$"; AD5_H="ad5heir-$$"
write_state_v2 "$AD5_MIS" "$CWD2" "other-branch" "$STEPS_INHERITABLE"
write_state_v2 "$AD5_S1" "$CWD" "$BRANCH" "$STEPS_DELIVERED"
write_state_v2 "$AD5_H" "$CWD" "$BRANCH" "$STEPS_ALL_PENDING"
announce_donor "$AD5_MIS" "$CWD2"; announce_donor "$AD5_S1" "$CWD"
adopt "$AD5_H" "$REPO" --from "$AD5_MIS"
assert_rc_nonzero "AD-5a. a context-mismatched donor is refused" "$ADOPT_RC" "$ADOPT_OUT"
assert_eq_guarded cli_ran "AD-5b. the heir stays untouched after the mismatch refusal" "pending" "$(step_status "$AD5_H" outline)"
adopt "$AD5_H" "$REPO" --from "$AD5_S1"
assert_rc_nonzero "AD-5c. a non-resumable delivered (S1) donor is refused" "$ADOPT_RC" "$ADOPT_OUT"
assert_eq_guarded cli_ran "AD-5d. the heir stays untouched after the resumability refusal" "pending" "$(step_status "$AD5_H" outline)"

# AD-5e: an approved-but-undelivered donor is adoptable, and the heir can then
# continue to deliver (approval carried over, deliver not already complete).
AD5E_D="ad5edonor-$$"; AD5E_H="ad5eheir-$$"
write_state_v2 "$AD5E_D" "$CWD" "$BRANCH" "$STEPS_APPROVED_NOT_DELIVERED"
write_state_v2 "$AD5E_H" "$CWD" "$BRANCH" "$STEPS_ALL_PENDING"
announce_donor "$AD5E_D" "$CWD"
adopt "$AD5E_H" "$REPO" --from "$AD5E_D"
assert_eq_desc "AD-5e-rc. adopting an approved-but-undelivered donor exits 0" "0" "$ADOPT_RC"
assert_eq_guarded cli_ran "AD-5e-uv. the heir carries the donor's user_verification completion" "complete" "$(step_status "$AD5E_H" user_verification)"
assert_eq_guarded cli_ran "AD-5e-dl. the heir's deliver step is still pending (it can still deliver)" "pending" "$(step_status "$AD5E_H" deliver)"
