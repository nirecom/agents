# tests/bin-codex-review-loop-security-code/full-chain-integration.sh
# Tests: bin/run-codex-review-loop, bin/concern-ledger, skills/review-code-security/SKILL.md
# Tags: concern-ledger, review-code-security, full-chain, integration, TL2, scope:common
# Sourced by tests/bin-codex-review-loop-security-code.sh.
# Each link can be correct while the chain is not: the round both producers
# share is now decided by the loop itself, so a drifting counter or a second
# ledger splits one review into two. Two rounds end to end, then a re-entry.

echo ""
echo "--- X: the security-code chain end to end, twice, then re-entered ---"

FCH_CODEX="the retry path swallows the error it was meant to surface"
FCH_SCAN="the token is written to the log in cleartext"

fch_ledgers() {
    find "$PLANS" -maxdepth 1 -name '*concern-ledger.txt' -type f 2>/dev/null | wc -l | tr -d ' '
}
fch_check() {
    bash "$CLI" check-finalized --plans-dir "$PLANS" --session-id "$SID" \
        --format "$LEDGER_FORMAT" --round "$1" >/dev/null 2>&1
    printf '%s' "$?"
}
# fch_scan <round> <report> — the scanner half of the round, replayed as the
# report file the subagent is contracted to hand back.
fch_scan() {
    RL_EXTRA=(--prestaged-report "$2" --prestaged-producer security-scanner
              --prestaged-exec PERFORMED)
    run_loop --round "$1"
    RL_EXTRA=()
}

# ---------------------------------------------------------------------------
# X1. Round 1 of a review, end to end.
# ---------------------------------------------------------------------------
new_env
RL_CAP=4
RL_MAXEXT=0
X_LED="$(ledger_file "$PLANS" "$SID")"
X_JSONF="$(json_file "$PLANS" "$SID")"

{
    X_BODY="$TMPDIR_BASE/fch-body-1.txt"
    mk_body "$X_BODY" "$(anchored HIGH - "bin/retry.sh" "retry_once" "correctness" "$FCH_CODEX")"
    RL_CODEX_BODY="$X_BODY"
    run_loop

    assert_eq "X1: the first round of a fresh review opens as round 1" \
        "1" "$(trim "$(cat "$(round_file "$PLANS" "$SID")" 2>/dev/null || true)")"
    assert_contains "X1: the review step ran the codex reviewer" \
        "## Codex Review: PERFORMED" "$LAST_OUT"
    assert_not_contains "X1: round 1 offers no prior-concerns block, having nothing to report" \
        "[PRIOR CONCERNS START]" "$(cat "$LAST_PROMPT" 2>/dev/null || true)"

    assert_eq "X1: the reviewer's concern reached the shared ledger" "1" "$(entry_count "$X_LED")"
    X_ID="$(id_for_text "$X_LED" "$FCH_CODEX")"
    assert_eq_nz "X1: it was minted as the first id of the cycle" "C1" "$X_ID"
    assert_eq "X1: and it is attributed to the codex producer" \
        "review-code-codex" "$(entry_field "$X_LED" "$X_ID" "$F_PRODUCERS")"
    assert_eq "X1: an unresolved round-1 HIGH asks for a revision" "1" "$LAST_RC"

    X_REPORT="$TMPDIR_BASE/fch-report-1.txt"
    mk_report "$X_REPORT" "$(anchored HIGH - "bin/auth.sh" "issue_token" "security" "$FCH_SCAN")"
    fch_scan 1 "$X_REPORT"

    assert_eq "X1: the scanner half re-enters the loop and is answered, not rejected" \
        "not-4" "$(if [ "$LAST_RC" -eq 4 ]; then printf '4'; else printf 'not-4'; fi)"
    assert_eq "X1: the whole chain wrote exactly one ledger" "1" "$(fch_ledgers)"
    assert_eq "X1: holding both producers' concerns, not one review each" \
        "2" "$(entry_count "$X_LED")"
    X_SID2="$(id_for_text "$X_LED" "$FCH_SCAN")"
    assert_eq_nz "X1: the scanner's concern was numbered after the reviewer's" "C2" "$X_SID2"
    assert_eq "X1: and attributed to the scanner" \
        "security-scanner" "$(entry_field "$X_LED" "$X_SID2" "$F_PRODUCERS")"
    assert_eq "X1: both producers staged into the same round" \
        "codex=present scanner=present" \
        "codex=$(file_state "$(delta_file "$PLANS" "$SID" 1 review-code-codex)") scanner=$(file_state "$(delta_file "$PLANS" "$SID" 1 security-scanner)")"
    assert_eq "X1: and the round the counter names is still round 1" \
        "1" "$(trim "$(cat "$(round_file "$PLANS" "$SID")" 2>/dev/null || true)")"

    X_JSON="$(cat "$X_JSONF" 2>/dev/null || true)"
    assert_eq "X1: the chain finalized an artifact for the round" "present" "$(file_state "$X_JSONF")"
    assert_eq "X1: check-finalized accepts the artifact for the round just closed" "0" "$(fch_check 1)"
    assert_eq "X1: and refuses it for a round the chain has not reached" "1" "$(fch_check 2)"
    assert_contains "X1: the artifact names both producers of the round" \
        '"name": "review-code-codex"' "$X_JSON"
    assert_contains "X1: including the second one" '"name": "security-scanner"' "$X_JSON"
    assert_contains "X1: and carries the reviewer's concern" "$FCH_CODEX" "$X_JSON"
    assert_contains "X1: and the scanner's" "$FCH_SCAN" "$X_JSON"
    assert_contains "X1: the round is recorded as unconverged, which is what it was" \
        '"converged": false' "$X_JSON"
}

# ---------------------------------------------------------------------------
# X2. Round 2 over the same session. The round both producers must agree on is
#     decided by the loop's own counter, so the second pass is where a drift or
#     a re-minted id would show.
# ---------------------------------------------------------------------------
{
    X2_BODY="$TMPDIR_BASE/fch-body-2.txt"
    mk_body "$X2_BODY" "$(anchored HIGH C1 "bin/retry.sh" "retry_once" "correctness" "$FCH_CODEX")"
    RL_CODEX_BODY="$X2_BODY"
    run_loop

    assert_eq "X2: the next round of a live review opens as round 2" \
        "2" "$(trim "$(cat "$(round_file "$PLANS" "$SID")" 2>/dev/null || true)")"
    X2_PROMPT="$(cat "$LAST_PROMPT" 2>/dev/null || true)"
    assert_contains "X2: and hands the reviewer the concerns still open" \
        "[PRIOR CONCERNS START]" "$X2_PROMPT"
    assert_contains "X2: naming the reviewer's concern by the id it already has" "C1" "$X2_PROMPT"
    assert_contains "X2: and the scanner's alongside it" "C2" "$X2_PROMPT"
    assert_contains "X2: the round the loop staged into is round 2" \
        "$LEDGER_FORMAT-round-2-delta-review-code-codex" \
        "$(find "$PLANS" -maxdepth 1 -name '*round-2-delta-*' 2>/dev/null | tr '\n' ' ')"
    assert_eq "X2: the re-raised concern keeps its original id" \
        "C1" "$(id_for_text "$X_LED" "$FCH_CODEX")"
    assert_eq "X2: still one ledger for the whole review" "1" "$(fch_ledgers)"

    # The scanner reports its round-1 finding as fixed by saying nothing about it.
    X2_REPORT="$TMPDIR_BASE/fch-report-2.txt"
    mk_report "$X2_REPORT"
    fch_scan 2 "$X2_REPORT"

    assert_eq "X2: the artifact now answers for round 2" "0" "$(fch_check 2)"
    assert_eq "X2: and no longer for round 1, so a stale copy cannot be reused" "1" "$(fch_check 1)"
    X2_JSON="$(cat "$X_JSONF" 2>/dev/null || true)"
    assert_contains "X2: the re-raised concern is still open in the artifact" "$FCH_CODEX" "$X2_JSON"
    assert_eq "X2: the scanner's silence resolved its own concern" \
        "resolved" "$(entry_field "$X_LED" "C2" "$F_STATE")"
    assert_eq "X2: the ledger still holds both entries, one per producer" \
        "2" "$(entry_count "$X_LED")"
    assert_eq "X2: and the ids were never re-minted across the two rounds" \
        "C1 C2" "$(grep -oE '^C[0-9]+' "$X_LED" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
    assert_eq "X2: the second round is the cap-adjacent one, so it is not an approval" \
        "nonzero" "$(nonzero_word "$LAST_RC")"
}

# ---------------------------------------------------------------------------
# X3. Re-entering the same round. The prestaged path is the one a caller
#     re-runs after a rollback, so re-entry must not double-count the round's
#     concerns or move the artifact off the round it describes.
# ---------------------------------------------------------------------------
{
    X3_BEFORE="$(digest "$X_JSONF")"
    X3_LED_BEFORE="$(digest "$X_LED")"
    fch_scan 2 "$X2_REPORT"

    assert_eq_nz "X3: the ledger is unchanged by the repeat" "$X3_LED_BEFORE" "$(digest "$X_LED")"
    assert_eq_nz "X3: and so is the artifact, byte for byte" "$X3_BEFORE" "$(digest "$X_JSONF")"
    assert_eq "X3: no concern was duplicated by the second pass" "2" "$(entry_count "$X_LED")"
    assert_eq "X3: and the artifact still answers only for the round it closed" \
        "round2=0 round1=1" "round2=$(fch_check 2) round1=$(fch_check 1)"
    assert_eq "X3: the round counter did not advance on a re-entry" \
        "2" "$(trim "$(cat "$(round_file "$PLANS" "$SID")" 2>/dev/null || true)")"
    assert_eq "X3: and no round-3 delta appeared" \
        "missing" "$(file_state "$(delta_file "$PLANS" "$SID" 3 security-scanner)")"
}
