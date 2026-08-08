# shellcheck shell=bash
# AD-6 .. AD-11 — the /workflow-init `adopt-prior-state` phase: a ROUTE to the
# CLI, never a second implementation of it.

# Tests: tests/feature-1305-adopt-session-state.sh
# Tags: scope:issue-specific

echo ""
echo "=== #1305 AD-6..AD-11: workflow-init adopt-prior-state phase ==="

echo_driver_action() { get_kv "$DRIVER_OUT" ACTION; }

# --- AD-6: non-regression. The overwhelmingly common case is "no prior session
# here". The phase must then be a complete no-op — /workflow-init behaves today
# exactly as it did before SD-4 landed.
REPO6="$(setup_repo six)"
CWD6="$(resolve_path "$REPO6")"
BRANCH6="$(git -C "$REPO6" rev-parse --abbrev-ref HEAD)"
AD6_H="ad6heir-$$"
write_state_v2 "$AD6_H" "$CWD6" "$BRANCH6" "$STEPS_ALL_PENDING"
run_driver "$AD6_H" "$REPO6" --phase adopt-prior-state
assert_eq_desc "AD-6a. with no candidates the driver runs straight through" "done" "$(echo_driver_action)"
assert_eq_desc "AD-6b. no-candidate run exits 0" "0" "$DRIVER_RC"
assert_eq_guarded phase_ran "AD-6c. the heir's state is left all-pending" "pending" "$(step_status "$AD6_H" outline)"

# --- AD-7: with a candidate, the interactive route asks — and `fresh` (the
# default) must leave the session exactly as it was. Adoption is opt-IN.
AD7_D="ad7donor-$$"; AD7_H="ad7heir-$$"
write_state_v2 "$AD7_D" "$CWD" "$BRANCH" "$STEPS_INHERITABLE"
write_state_v2 "$AD7_H" "$CWD" "$BRANCH" "$STEPS_ALL_PENDING"
announce_donor "$AD7_D" "$CWD"
run_driver "$AD7_H" "$REPO" --phase adopt-prior-state
assert_eq_desc "AD-7a. a candidate raises an ask_user directive" "ask_user" "$(echo_driver_action)"
assert_contains "AD-7b. the question names the candidate session" "$AD7_D" "$(printf '%s' "$DRIVER_OUT" | tr '%' ' ')"
CKPT7="$(get_kv "$DRIVER_OUT" CHECKPOINT)"
run_driver "$AD7_H" "$REPO" --resume "$CKPT7" --answer fresh
assert_eq_desc "AD-7c. answering 'fresh' completes the pipeline" "done" "$(echo_driver_action)"
assert_eq_guarded phase_ran "AD-7d. answering 'fresh' leaves the state all-pending" "pending" "$(step_status "$AD7_H" outline)"

# --- AD-8: the opt-in half of the same gate.
AD8_D="ad8donor-$$"; AD8_H="ad8heir-$$"
write_state_v2 "$AD8_D" "$CWD" "$BRANCH" "$STEPS_INHERITABLE"
write_state_v2 "$AD8_H" "$CWD" "$BRANCH" "$STEPS_ALL_PENDING"
announce_donor "$AD8_D" "$CWD"
run_driver "$AD8_H" "$REPO" --phase adopt-prior-state
CKPT8="$(get_kv "$DRIVER_OUT" CHECKPOINT)"
run_driver "$AD8_H" "$REPO" --resume "$CKPT8" --answer adopt
assert_eq_desc "AD-8a. answering 'adopt' completes the pipeline" "done" "$(echo_driver_action)"
assert_eq_desc "AD-8b. answering 'adopt' inherits the donor's steps" "complete" "$(step_status "$AD8_H" outline)"
assert_eq_desc "AD-8c. the adoption is attributed to the chosen donor" "$AD8_D" "$(inherited_from_of "$AD8_H")"

# --- AD-9: non-interactive must not hard-fail. This phase's value is optional
# recovery and its default (`fresh`) is always safe, so blocking /workflow-init
# would be a plain regression for `/loop` and `claude -p`.
AD9_D="ad9donor-$$"; AD9_H="ad9heir-$$"
write_state_v2 "$AD9_D" "$CWD" "$BRANCH" "$STEPS_INHERITABLE"
write_state_v2 "$AD9_H" "$CWD" "$BRANCH" "$STEPS_ALL_PENDING"
announce_donor "$AD9_D" "$CWD"
# Exported and unset explicitly (not as a `VAR=x fn` prefix, which bash leaks
# past the call) so the next case cannot inherit it.
export CLAUDE_NON_INTERACTIVE=1
run_driver "$AD9_H" "$REPO" --phase adopt-prior-state
unset CLAUDE_NON_INTERACTIVE
assert_not_contains_guarded phase_ran "AD-9a. CLAUDE_NON_INTERACTIVE emits no ask_user" "ACTION=ask_user" "$DRIVER_OUT"
assert_eq_desc "AD-9b. non-interactive does NOT hard-fail workflow-init" "0" "$DRIVER_RC"
assert_eq_desc "AD-9c. the pipeline proceeds to the next phase" "done" "$(echo_driver_action)"
assert_eq_guarded phase_ran "AD-9d. nothing is adopted silently" "pending" "$(step_status "$AD9_H" outline)"

# --- AD-10: "not adopted" must never mean "not told". The printed recovery
# command has to be genuinely runnable — a NOTICE that does not work is worse
# than none (CPR-E2E), so the test runs the emitted command verbatim.
AD10_D="ad10donor-$$"; AD10_H="ad10heir-$$"
write_state_v2 "$AD10_D" "$CWD" "$BRANCH" "$STEPS_INHERITABLE"
write_state_v2 "$AD10_H" "$CWD" "$BRANCH" "$STEPS_ALL_PENDING"
announce_donor "$AD10_D" "$CWD"
export CI=1
run_driver "$AD10_H" "$REPO" --phase adopt-prior-state
unset CI
assert_not_contains_guarded phase_ran "AD-10a. CI=1 emits no ask_user either" "ACTION=ask_user" "$DRIVER_OUT"
assert_contains "AD-10b. a NOTICE announces the un-adopted prior session" "NOTICE" "$DRIVER_OUT"
assert_contains "AD-10c. the NOTICE spells out the adopt-session-state command" \
    "adopt-session-state --session $AD10_H --from $AD10_D" "$DRIVER_OUT"
NOTICE_CMD="$(printf '%s\n' "$DRIVER_OUT" | grep -o 'node .*adopt-session-state --session [^ ]* --from [^ ]*' | head -1 || true)"
if [ -z "$NOTICE_CMD" ]; then
    fail "AD-10d. the emitted NOTICE command could not be extracted (nothing to run)"
else
    set +e
    NOTICE_RUN="$( (cd "$AGENTS_DIR" && CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_NODE" \
        WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" CLAUDE_TRANSCRIPT_BASE_DIR="$TBASE_NODE" \
        CLAUDE_PROJECT_DIR="$REPO" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout bash -c "$NOTICE_CMD" 2>&1) )"
    NOTICE_RC=$?
    set -e
    assert_eq_desc "AD-10d. running the emitted command verbatim succeeds" "0" "$NOTICE_RC"
    assert_eq_desc "AD-10e. and it actually performs the adoption" "complete" "$(step_status "$AD10_H" outline)"
fi

# --- AD-11: one execution point (CPR-SSOT / CPR-ORTH). Interactive `adopt` and
# a direct non-interactive CLI call are two routes to the SAME function, so the
# streams they append must be indistinguishable.
AD11_D="ad11donor-$$"; AD11_CLI="ad11cli-$$"; AD11_UI="ad11ui-$$"
write_state_v2 "$AD11_D" "$CWD" "$BRANCH" "$STEPS_INHERITABLE"
write_state_v2 "$AD11_CLI" "$CWD" "$BRANCH" "$STEPS_ALL_PENDING"
write_state_v2 "$AD11_UI" "$CWD" "$BRANCH" "$STEPS_ALL_PENDING"
announce_donor "$AD11_D" "$CWD"
adopt "$AD11_CLI" "$REPO" --from "$AD11_D"
run_driver "$AD11_UI" "$REPO" --phase adopt-prior-state
CKPT11="$(get_kv "$DRIVER_OUT" CHECKPOINT)"
run_driver "$AD11_UI" "$REPO" --resume "$CKPT11" --answer adopt
SIG_CLI="$(event_signature "$AD11_CLI")"
SIG_UI="$(event_signature "$AD11_UI")"
if [ "$SIG_CLI" = "NO_STATE" ] || [ -z "$SIG_CLI" ]; then
    # Two empty streams compare equal, so the equality check below is only
    # meaningful once the CLI route has actually appended something.
    fail "AD-11a. the direct CLI route appended no events (nothing to compare)"
    fail "AD-11b. stream equivalence unproven — the CLI route produced no stream"
else
    pass "AD-11a. the direct CLI route appended an event stream"
    assert_eq_desc "AD-11b. the interactive route appends the identical stream shape" "$SIG_CLI" "$SIG_UI"
fi
