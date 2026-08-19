# tests/feature-2068-round-counter-ssot/round-argument-guards.sh
# Tests: bin/run-codex-review-loop, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh
# Tags: codex-review-loop, round-counter, fail-closed, table-driven, TL2, scope:issue-specific
# Sourced by tests/feature-2068-round-counter-ssot.sh (ROOT fixture, rcs_* helpers).
#
# An owned counter is only authoritative while no caller can talk past it. A
# skipped or rewound --round would let a caller name any round it liked, which
# is what let a mid-loop round be judged as final. These cases pin the two
# refusals, the deliberate escape hatch, and that no shipped caller uses it.

echo ""
echo "--- ssot-B: the guards that keep the recorded counter authoritative ---"

# ---------------------------------------------------------------------------
# B1. Skipping ahead. Both a small jump and a large one are refused: "large
#     values win" would be exactly the loophole that makes the cap meaningless.
# ---------------------------------------------------------------------------
while IFS='|' read -r B1_N B1_WHY; do
    case "$B1_N" in ''|\#*) continue ;; esac

    rcs_env "skip$B1_N"
    rcs_seed 1
    rcs_direct --round "$B1_N"

    assert_eq "B1 (--round $B1_N): $B1_WHY is refused" "4" "$RCS_RC"
    assert_contains "B1 (--round $B1_N): and the refusal names the recorded counter" \
        "does not follow the recorded round counter" "$RCS_ERR"
    assert_eq "B1 (--round $B1_N): the recorded counter is left where it was" \
        "1" "$(clf_read "$(rcs_counter)")"
    assert_eq "B1 (--round $B1_N): and no delta is created for a round that never ran" \
        "" "$(rcs_delta_rounds)"
done <<'SKIPS'
3|a jump past the next round
999|a jump far past it, where a naive bound check would pass
SKIPS

# ---------------------------------------------------------------------------
# B2. Rewinding. A round number that has already been used addresses artifacts
#     that already exist, so accepting it would overwrite the audit trail rather
#     than merely mis-count.
# ---------------------------------------------------------------------------
{
    rcs_env rewind
    rcs_seed 3
    rcs_seed_delta 1
    rcs_seed_delta 2
    B2_D1="$(clf_digest "$(rcs_delta 1)")"
    B2_D2="$(clf_digest "$(rcs_delta 2)")"
    B2_S1="$(wc -c < "$(rcs_delta 1)" | tr -d ' ')"

    rcs_direct --round 2

    assert_eq "B2: a round number already spent is refused" "4" "$RCS_RC"
    assert_contains "B2: with the same recorded-counter explanation" \
        "does not follow the recorded round counter" "$RCS_ERR"
    assert_eq "B2: the counter still reads the round the loop really reached" \
        "3" "$(clf_read "$(rcs_counter)")"
    assert_eq "B2: and neither past round's delta was touched" \
        "$B2_D1 $B2_D2" "$(clf_digest "$(rcs_delta 1)") $(clf_digest "$(rcs_delta 2)")"
    assert_eq "B2: down to the byte count, so no partial rewrite slipped through" \
        "$B2_S1" "$(wc -c < "$(rcs_delta 1)" | tr -d ' ')"
}

# ---------------------------------------------------------------------------
# B3. The escape hatch. Recovery from a corrupt counter and tests that need to
#     start mid-loop are real needs, so they get their own flag — one that
#     announces itself, and still cannot reach a round that already happened.
# ---------------------------------------------------------------------------
{
    rcs_env force
    rcs_seed 1
    rcs_seed_delta 1
    printf 'C1|HIGH|OPEN|1|test concern\n' > "$(clf_ledger_path "$RCS_P" "$RCS_SID" "$FORMAT")"

    rcs_direct --force-round 5
    assert_ne "B3: --force-round is accepted where --round would be refused" "4" "$RCS_RC"
    assert_contains "B3: but never silently — it says what it is for" \
        "recovery/test use only" "$RCS_ERR"
    assert_eq "B3: and the forced round becomes the new recorded counter" \
        "5" "$(clf_read "$(rcs_counter)")"

    # Below the highest delta on disk it would overwrite history, so it stops.
    rcs_env forceback
    rcs_seed 3
    rcs_seed_delta 1
    rcs_seed_delta 2
    B3_D2="$(clf_digest "$(rcs_delta 2)")"
    rcs_direct --force-round 2
    assert_eq "B3: forcing back onto a round that already has a delta is refused" \
        "4" "$RCS_RC"
    assert_eq "B3: so the escape hatch cannot overwrite a past round's delta" \
        "$B3_D2" "$(clf_digest "$(rcs_delta 2)")"

    # Two ways to name the round at once is an ambiguity, not a preference order.
    rcs_env forceboth
    rcs_direct --round 1 --force-round 1
    assert_eq "B3: --round and --force-round together are rejected as ambiguous" \
        "4" "$RCS_RC"
    assert_eq "B3: and nothing is recorded from the ambiguous call" \
        "missing" "$(clf_file_state "$(rcs_counter)")"
}

# ---------------------------------------------------------------------------
# B4. No shipped caller uses the escape hatch, and none of them keeps a counter
#     of its own any more (CPR-ORTH: all four stages, checked as one table).
# ---------------------------------------------------------------------------
while IFS='|' read -r B4_KIND B4_PATH; do
    case "$B4_KIND" in ''|\#*) continue ;; esac

    B4_FULL="$AGENTS_ROOT/$B4_PATH"
    B4_BODY="$(cat "$B4_FULL" 2>/dev/null)"
    assert_eq "B4 ($B4_PATH): the file is present to check" \
        "present" "$(clf_file_state "$B4_FULL")"
    assert_not_contains "B4 ($B4_PATH): does not reach for the recovery-only flag" \
        "--force-round" "$B4_BODY"
    if [ "$B4_KIND" = "wrapper" ]; then
        assert_not_contains "B4 ($B4_PATH): and no longer manages a round counter of its own" \
            "round-number" "$B4_BODY"
    fi
done <<'CALLERS'
wrapper|skills/make-detail-plan/scripts/run-codex-review-loop.sh
wrapper|skills/make-outline-plan/scripts/run-codex-review-loop.sh
wrapper|skills/review-plan-security/scripts/run-codex-review-loop.sh
wrapper|skills/review-tests/scripts/run-codex-review-loop.sh
skill|skills/make-detail-plan/SKILL.md
skill|skills/make-outline-plan/SKILL.md
skill|skills/review-plan-security/SKILL.md
skill|skills/review-tests/SKILL.md
CALLERS
