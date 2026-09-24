# tests/feature-2068-round-counter-ssot/counter-ownership.sh
# Tests: bin/run-codex-review-loop, skills/make-detail-plan/scripts/run-codex-review-loop.sh
# Tags: codex-review-loop, round-counter, ssot, TL2, scope:issue-specific
# Sourced by tests/feature-2068-round-counter-ssot.sh, whose ROOT fixture,
# reviewer stub and rcs_* helpers are reused.
#
# Ownership is only observable over a whole loop — one call cannot show whether
# the number was allocated once or twice. Each case drives the real stage wrapper
# repeatedly and reads the counter, the rounds the reviewer was handed, and the
# delta names together: three views that must agree.

echo ""
echo "--- ssot-A: who owns the round number, over a whole loop ---"

rcs_entries() { grep -cE '^C[0-9]+\|' "$1" 2>/dev/null || printf '0'; }
rcs_ids()     { grep -oE '^C[0-9]+' "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }

# ---------------------------------------------------------------------------
# A1. Three real rounds through the stage wrapper. The stage wrapper is the path
#     a skill takes, so running it (rather than the shared wrapper directly)
#     also proves the delegation still works once the counter moved out of it.
# ---------------------------------------------------------------------------
{
    rcs_env own
    LEDGER="$(clf_ledger_path "$RCS_P" "$RCS_SID" "$FORMAT")"

    rcs_stage 0
    assert_eq "A1: round 1 continues" "1" "$RCS_RC"
    assert_eq "A1: and the shared wrapper records the round it allocated" \
        "1" "$(clf_read "$(rcs_counter)")"

    rcs_stage 0
    assert_eq "A1: round 2 exhausts the cap and asks for the extension" "5" "$RCS_RC"
    assert_eq "A1: the counter advances by exactly one round" \
        "2" "$(clf_read "$(rcs_counter)")"
    assert_eq "A1: an AUTO_EXTEND keeps the counter — the loop is not over" \
        "present" "$(clf_file_state "$(rcs_counter)")"

    rcs_stage 1
    assert_eq "A1: the extended round ends with the HIGH concern unresolved" "6" "$RCS_RC"

    # The three views of the same allocation.
    assert_eq "A1: the reviewer saw each round exactly once, in order" \
        "1 2 3" "$(rcs_rounds_seen)"
    assert_eq "A1: and every round left a delta of its own, none overwritten" \
        "1 2 3" "$(rcs_delta_rounds)"
    assert_eq "A1: the concern kept its identity across all three rounds" \
        "1" "$(rcs_entries "$LEDGER")"
    assert_eq "A1: and was never renumbered off C1" "C1" "$(rcs_ids "$LEDGER")"
}

# ---------------------------------------------------------------------------
# A2. What the terminal leaves behind. The counter is deleted so a stale number
#     cannot bleed into the next cycle, and the final round survives in
#     last-round.txt because the orchestrator names the terminal RAW from it.
# ---------------------------------------------------------------------------
{
    assert_eq "A2: the terminal retires the counter" "missing" "$(clf_file_state "$(rcs_counter)")"
    assert_eq "A2: and records the round the loop ended on" "3" "$(clf_read "$(rcs_last)")"

    : > "$RCS_LOG"
    rcs_stage 0
    assert_eq "A2: a fresh cycle after the terminal starts the reviewer at round 1" \
        "1" "$(rcs_rounds_seen)"
    assert_eq "A2: so the cap is judged against real rounds, not a carried-over count" \
        "1" "$(clf_read "$(rcs_counter)")"
}

# ---------------------------------------------------------------------------
# A3. Auto-numbering is the default. --round is optional now: with no counter on
#     disk the first round is 1, and the wrapper — not its caller — decides.
# ---------------------------------------------------------------------------
{
    rcs_env auto
    rcs_direct
    assert_eq "A3: the wrapper allocates round 1 with no --round given at all" \
        "1" "$(rcs_rounds_seen)"
    assert_eq "A3: and publishes it as the recorded counter" "1" "$(clf_read "$(rcs_counter)")"
    assert_eq "A3: the round it allocated is the round the delta is named for" \
        "1" "$(rcs_delta_rounds)"
    assert_eq "A3: with no complaint about a missing argument" "1" "$RCS_RC"
}
