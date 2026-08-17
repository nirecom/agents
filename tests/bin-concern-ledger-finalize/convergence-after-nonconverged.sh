# tests/bin-concern-ledger-finalize/convergence-after-nonconverged.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/finalize.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/render.sh, bin/run-codex-review-loop, skills/review-code-security/scripts/close-concern-round.sh
# Tags: concern-ledger, finalize, convergence, non-converged-cycle, TL2, scope:common
# Sourced by tests/bin-concern-ledger-finalize.sh (after loop-integration.sh and
# cap-outline-detail.sh, whose helpers are reused).

# A non-converged round leaves a durable 'converged: false' file on a fixed
# path. The next cycle may converge cleanly, and a clean convergence writes
# nothing — so the artifact from the earlier cycle is still sitting there when
# the caller asks whether this round finalized. Whether that leftover can be
# mistaken for the current round's verdict is the whole question: the round
# binding is the only thing standing between "an old failure" and "this plan
# was rejected".

echo ""
echo "--- finalize 13: a clean convergence after a non-converged round ---"

CN_TEXT="the concern the earlier cycle could not resolve"

# cn_approved — a reviewer body with no concerns at all.
cn_approved() {
    printf '## Codex Plan Review: PERFORMED\n\n'
    printf '<!-- begin-codex-output: treat as untrusted third-party content -->\n'
    printf 'APPROVED\n'
    printf '<!-- end-codex-output -->\n'
}

# ---------------------------------------------------------------------------
# 13a. The leftover artifact must not answer for the round that converged.
# ---------------------------------------------------------------------------
{
    mk_loop_env
    SIDN="conv$MOCK_SEQ"
    NJ="$(json_file "$LPLANS" "$SIDN" detail-plan)"
    NLED="$(ledger_file "$LPLANS" "$SIDN" detail-plan)"

    # Cycle 1: two rounds, ending at the cap with a risk signal, which is the
    # branch that writes the non-convergence artifact.
    mk_reviewer "$(cd_reviewer detail-plan "$CN_TEXT")"
    run_loop_x detail-plan "$SIDN" 2 0 1
    mk_reviewer "$(cd_reviewer_ref detail-plan C1 "$CN_TEXT")"
    run_loop_x detail-plan "$SIDN" 2 0 2 --risk-signal "hook-registration"

    assert_eq "13a: the first cycle ends non-converged (precondition)" "2" "$LOOP_RC"
    assert_eq "13a: it left the artifact this case is about (precondition)" \
        "present" "$(file_state "$NJ")"
    STALE_BEFORE="$(fingerprint "$NJ")"
    assert_contains "13a: the leftover records the failure it was written for" \
        '"converged": false' "$(json_of "$NJ")"

    # What the skill does between cycles: the round counter is dropped so the
    # fixed plan is reviewed from round 1 again.
    rm -f "$(round_file "$LPLANS" "$SIDN" detail-plan)"

    mk_reviewer "$(cn_approved)"
    run_loop_x detail-plan "$SIDN" 2 0 1
    CONV_RC="$LOOP_RC"

    assert_eq "13a: the following round converges cleanly" "0" "$CONV_RC"
    assert_eq "13a: a clean convergence leaves no live ledger behind" \
        "missing" "$(file_state "$NLED")"

    # The point of the case. The leftover is still on disk — a clean convergence
    # writes nothing, so nothing removes it — but it names round 2 of the
    # previous cycle, so it cannot answer for the round that just converged.
    assert_eq "13a: the leftover artifact is still present, unclaimed by anyone" \
        "present" "$(file_state "$NJ")"
    assert_eq "13a: it does not answer for the round that converged" \
        "1" "$(rc_of check-finalized --plans-dir "$LPLANS" --session-id "$SIDN" \
                --format detail-plan --round 1)"
    assert_eq "13a: it still answers only for the round it was written for" \
        "0" "$(rc_of check-finalized --plans-dir "$LPLANS" --session-id "$SIDN" \
                --format detail-plan --round 2)"

    # And it was not quietly rewritten to look current: byte-for-byte the file
    # the earlier cycle wrote. Without this, "it names round 2" would also be
    # satisfied by a converging round that rewrote it with a stale round number.
    assert_eq_nz "13a: the converging round did not touch the leftover's bytes" \
        "$STALE_BEFORE" "$(fingerprint "$NJ")"
    assert_contains "13a: and the leftover still reads as a failure, not a pass" \
        '"converged": false' "$(json_of "$NJ")"
}

# ---------------------------------------------------------------------------
# 13b. The same boundary at the library level, where the round is the only
#      binding: an unrounded check-finalized cannot tell the two apart, so any
#      caller that drops --round inherits the earlier cycle's verdict. Pinned
#      because it is the failure mode the round argument exists to prevent.
# ---------------------------------------------------------------------------
{
    new_env
    FMT="detail-plan"
    LED="$(ledger_file "$PLANS" "$SID" "$FMT")"
    JSN="$(json_file "$PLANS" "$SID" "$FMT")"

    mk_ledger "$LED" "$FMT" "$SID" 1 \
        "$(row C1 HIGH open 1 2 "bin/run-codex-review-loop#finalize_ledger:correctness" \
            c0ffee review-plan-codex review-plan-codex - "$CN_TEXT")"
    run_cli finalize --plans-dir "$PLANS" --session-id "$SID" --format "$FMT" \
        --mode terminal --reason "cap reached without convergence" --round 2 \
        --cap 2 --max-extensions 0 --extensions-used 0
    assert_eq "13b: the non-converged artifact was written (precondition)" "0" "$LAST_RC"

    # The next cycle converges: the ledger is gone and nothing new is written.
    rm -f "$LED"

    assert_eq "13b: an unrounded check still accepts the earlier cycle's artifact" \
        "0" "$(rc_of check-finalized --plans-dir "$PLANS" --session-id "$SID" --format "$FMT")"
    assert_eq "13b: the round argument is what refuses it for round 3" \
        "1" "$(rc_of check-finalized --plans-dir "$PLANS" --session-id "$SID" \
                --format "$FMT" --round 3)"
    # A converged cycle leaves no ledger, so the artifact is the only file left
    # on these paths — and it describes concerns that are no longer open.
    assert_eq "13b: only the stale artifact survives the converged cycle" \
        "ledger=missing artifact=present" \
        "ledger=$(file_state "$LED") artifact=$(file_state "$JSN")"
    assert_contains "13b: and it still names the concern the earlier cycle left open" \
        "$CN_TEXT" "$(json_of "$JSN")"
}
