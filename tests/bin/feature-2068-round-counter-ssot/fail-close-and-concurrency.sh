# tests/feature-2068-round-counter-ssot/fail-close-and-concurrency.sh
# Tests: bin/run-codex-review-loop, bin/concern-ledger
# Tags: codex-review-loop, round-counter, fail-closed, concurrency, table-driven, TL2, scope:issue-specific
# Sourced by tests/feature-2068-round-counter-ssot.sh (ROOT fixture, rcs_* helpers).
#
# A counter that guesses is worse than one that stops: "1x2" read as 12 would
# jump the loop to a round nobody reviewed. So a damaged, contended, or
# half-written counter has to fail closed and leave the evidence untouched for
# whoever comes to look at it.

echo ""
echo "--- ssot-C: what happens when the counter cannot be trusted ---"

# ---------------------------------------------------------------------------
# C1. Damaged counter values. Each row is a shape a fail-soft parser would
#     "repair" into a plausible number; none of them may be.
# ---------------------------------------------------------------------------
while IFS='|' read -r C1_TAG C1_RAW C1_WHY; do
    case "$C1_TAG" in ''|\#*) continue ;; esac

    rcs_env "corrupt-$C1_TAG"
    printf '%b' "$C1_RAW" > "$(rcs_counter)"
    C1_BEFORE="$(clf_digest "$(rcs_counter)")"

    rcs_direct

    assert_eq "C1 ($C1_TAG): $C1_WHY" "4" "$RCS_RC"
    assert_contains "C1 ($C1_TAG): and the counter is named as corrupt, not silently reset" \
        "round counter is corrupt" "$RCS_ERR"
    assert_eq "C1 ($C1_TAG): the damaged file is left exactly as found, for inspection" \
        "$C1_BEFORE" "$(clf_digest "$(rcs_counter)")"
    assert_eq "C1 ($C1_TAG): and no round ran, so no delta appeared" "" "$(rcs_delta_rounds)"
    assert_eq "C1 ($C1_TAG): the reviewer was never invoked" "" "$(rcs_rounds_seen)"
done <<'CORRUPT'
digit-smudge|1x2|a value like 1x2 must never be read as round 12
empty||an empty counter is not a round 0 to continue from
two-lines|1\n2|two lines are two answers, so neither is the answer
letters|abc|a non-numeric counter has no salvageable round in it
spaced|1 2|digits separated by a space are not a single number
CORRUPT

# ---------------------------------------------------------------------------
# C2. Two rounds racing for the same number. Either the loser is turned away or
#     the two get different numbers — what must never happen is both being told
#     they are round N, because the second would overwrite the first's delta.
# ---------------------------------------------------------------------------
{
    rcs_env race
    rcs_seed 1
    rcs_seed_delta 1
    printf 'C1|HIGH|OPEN|1|concurrent test concern\n' > "$(clf_ledger_path "$RCS_P" "$RCS_SID" "$FORMAT")"
    C2_D1="$(clf_digest "$(rcs_delta 1)")"

    # c2_bg <tag> — one contender, its rc and stderr kept for the joint verdict.
    c2_bg() {
        (
            CLF_SLEEP=1 AGENTS_CONFIG_DIR="$ROOT" bash "$ROOT/bin/run-codex-review-loop" \
                --format "$FORMAT" --session-id "$RCS_SID" --plans-dir "$RCS_P" \
                --draft-file "$RCS_P/$RCS_SID-detail.md" \
                --accepted-tradeoffs "$RCS_P/$RCS_SID-outline.md" \
                --cap 2 --max-extensions 1 --extensions-used 0 \
                >/dev/null 2>"$TMPDIR_BASE/c2-$1-err.txt"
            printf '%s' "$?" > "$TMPDIR_BASE/c2-$1-rc.txt"
        ) &
    }
    c2_bg a
    c2_bg b
    wait

    C2_RC_A="$(cat "$TMPDIR_BASE/c2-a-rc.txt" 2>/dev/null)"
    C2_RC_B="$(cat "$TMPDIR_BASE/c2-b-rc.txt" 2>/dev/null)"
    C2_ERR="$(cat "$TMPDIR_BASE/c2-a-err.txt" "$TMPDIR_BASE/c2-b-err.txt" 2>/dev/null)"
    C2_SEEN="$(rcs_rounds_seen)"
    C2_UNIQ="$(printf '%s\n' $C2_SEEN | sort -u | tr '\n' ' ' | sed 's/ *$//')"

    # The one thing that is never acceptable, stated on its own.
    assert_eq "C2: no two concurrent rounds were handed the same round number" \
        "$C2_UNIQ" "$C2_SEEN"

    C2_TURNED_AWAY=no
    case "$C2_RC_A$C2_RC_B" in *4*) C2_TURNED_AWAY=yes ;; esac
    if [ "$C2_TURNED_AWAY" = "yes" ]; then
        assert_contains "C2: the contender that lost the lock is told a round is in flight" \
            "another review round is in flight" "$C2_ERR"
    else
        pass "C2: both contenders were serialized into rounds of their own"
    fi

    assert_eq "C2: the round-1 delta on disk before the race is untouched by it" \
        "$C2_D1" "$(clf_digest "$(rcs_delta 1)")"
    assert_eq "C2: and the lock is released, not left to block every later round" \
        "missing" "$(clf_file_state "$(rcs_lock)")"
}

# ---------------------------------------------------------------------------
# C3. A round that dies before it reviews anything has not been consumed, so the
#     counter must come back to where it was — deleting it would silently
#     restart at round 1 with a live ledger, which is unrecoverable.
# ---------------------------------------------------------------------------
{
    # Fail the context build: it happens after the counter is written, which is
    # the only window in which a rollback is observable.
    C3_BUILDER="$ROOT/bin/build-codex-context"
    C3_KEEP="$TMPDIR_BASE/build-codex-context.keep"
    cp "$C3_BUILDER" "$C3_KEEP"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$C3_BUILDER"

    rcs_env rollback
    rcs_seed 2
    rcs_direct
    assert_eq "C3: a round that failed mid-flight reports the wrapper failure" "4" "$RCS_RC"
    assert_eq "C3: and the counter is back at the round the loop had really reached" \
        "2" "$(clf_read "$(rcs_counter)")"

    rcs_env rollback-fresh
    rcs_direct
    assert_eq "C3: the same failure on a first round also reports 4" "4" "$RCS_RC"
    assert_eq "C3: and leaves no counter behind for a round that never happened" \
        "missing" "$(clf_file_state "$(rcs_counter)")"

    cp "$C3_KEEP" "$C3_BUILDER"
}

# ---------------------------------------------------------------------------
# C4. A round 2 or later without its ledger has lost every concern ID from the
#     rounds before it. Continuing would re-issue C1 for a different concern, so
#     the loop stops instead — including when the caller named the ledger itself.
# ---------------------------------------------------------------------------
{
    # Row (i) needs a real round 1 first, so the ledger it deletes is a real one.
    rcs_env ledger-default
    rcs_direct
    assert_eq "C4 (default path): round 1 leaves a ledger behind (precondition)" \
        "present" "$(clf_file_state "$(clf_ledger_path "$RCS_P" "$RCS_SID" "$FORMAT")")"
    rm -f "$(clf_ledger_path "$RCS_P" "$RCS_SID" "$FORMAT")"

    rcs_direct
    assert_eq "C4 (default path): round 2 without its ledger is a wrapper failure, not a fallback" \
        "4" "$RCS_RC"
    assert_contains "C4 (default path): and says which round lost its ledger" \
        "ledger missing for round" "$RCS_ERR"
    assert_eq "C4 (default path): the ledger is not quietly recreated from nothing" \
        "missing" "$(clf_file_state "$(clf_ledger_path "$RCS_P" "$RCS_SID" "$FORMAT")")"

    # Row (ii): an explicitly named ledger that does not exist is the same
    # failure — an override is not a licence to start the IDs over.
    rcs_env ledger-override
    rcs_seed 1
    rcs_direct --ledger "$RCS_P/nowhere-concern-ledger.txt"
    assert_eq "C4 (explicit --ledger): a named ledger that is absent fails the same way" \
        "4" "$RCS_RC"
    assert_contains "C4 (explicit --ledger): with the same round-scoped message" \
        "ledger missing for round" "$RCS_ERR"
    assert_eq "C4 (explicit --ledger): and the named path is not created on the way out" \
        "missing" "$(clf_file_state "$RCS_P/nowhere-concern-ledger.txt")"
}
