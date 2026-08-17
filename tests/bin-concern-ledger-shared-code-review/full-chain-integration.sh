# tests/bin-concern-ledger-shared-code-review/full-chain-integration.sh
# Tests: skills/review-code-security/scripts/open-concern-round.sh, skills/review-code-security/scripts/run-quality-gates.sh, skills/review-code-security/scripts/close-concern-round.sh
# Tags: concern-ledger, review-code-security, full-chain, integration, TL2, scope:common
# Sourced by tests/bin-concern-ledger-shared-code-review.sh.

# Why this case exists. Everything else in this suite replays one link of the
# review at a time: a stage here, a reduce there, the wrapper on its own. Each
# link can be correct while the chain is not, because the thing the chain has
# to get right is an agreement between three scripts that never call each
# other — open-concern-round.sh decides the round, run-quality-gates.sh reaches
# the codex producer, close-concern-round.sh brings the scanner in and ends the
# round. A round number that drifts between them, or a second ledger opened by
# one of them, splits the two producers into two reviews the author is asked to
# reconcile by hand.

# So this file runs the three scripts in the order the SKILL runs them, with
# only the external `codex` binary mocked and the security-scanner subagent
# replayed as the report file it is contracted to produce. What is asserted is
# the agreement itself: one ledger, one round, both producers inside it, and a
# final artifact that check-finalized accepts for that round.

echo ""
echo "--- shared-review full chain: open -> gates -> close, twice ---"

FCH_CODEX="the retry path swallows the error it was meant to surface"
FCH_SCAN="the token is written to the log in cleartext"

# fch_env <n> — a plans dir with nothing in it, the state the first round of a
# real review starts from.
FCH_P=""; FCH_SID=""
fch_env() {
    FCH_SID="fch$1"
    FCH_P="$TMPDIR_BASE/fch-plans-$1"
    mkdir -p "$FCH_P/workflow-state"
}

# fch_open — skills/review-code-security/scripts/open-concern-round.sh, the
# step that decides the round both producers will share. Sets FCH_OPEN.
fch_open() {
    FCH_OPEN="$(
        SESSION_ID="$FCH_SID" PLANS_DIR="$FCH_P" AGENTS_CONFIG_DIR="$AGENTS_ROOT" \
            bash "$AGENTS_ROOT/skills/review-code-security/scripts/open-concern-round.sh" 2>/dev/null
    )"
}

# fch_kv <key> — a value from the open-concern-round key=value contract.
fch_kv() { printf '%s\n' "$FCH_OPEN" | grep -m1 "^$1=" | cut -d'=' -f2-; }

# fch_gates <round> <codex-body> — run-quality-gates.sh with the CWD set to the
# reviewed tree, exactly as the SKILL invokes it. The codex CLI is the only
# mocked boundary; the wrapper, the ledger CLI and the other seven gates are
# the real ones. Sets FCH_GATES.
fch_gates() {
    FCH_GATES="$(
        cd "$REPO" || exit 1
        export PATH="$FULL_PATH" HOME="$TMPDIR_BASE" AGENTS_CONFIG_DIR="$AGENTS_ROOT"
        export CODEX_MOCK_PROMPT="$TMPDIR_BASE/fch-prompt-$1.txt" \
               CODEX_MOCK_BODY="$2" CODEX_MOCK_EXIT=0
        export PLANS_DIR="$FCH_P" WORKFLOW_PLANS_DIR="$FCH_P" \
               CLAUDE_WORKFLOW_DIR="$FCH_P/workflow-state" \
               SESSION_ID="$FCH_SID" CLAUDE_SESSION_ID="$FCH_SID" \
               CLAUDE_CODE_SESSION_ID="$FCH_SID" CONCERN_LEDGER_ROUND="$1"
        bash "$AGENTS_ROOT/skills/review-code-security/scripts/run-quality-gates.sh" 2>/dev/null
    )"
}

# fch_close <round> <report> — the Completion-section close-out. Sets
# FCH_CLOSE / FCH_CLOSE_RC.
fch_close() {
    FCH_CLOSE_RC=0
    FCH_CLOSE="$(
        AGENTS_CONFIG_DIR="$AGENTS_ROOT" bash \
            "$AGENTS_ROOT/skills/review-code-security/scripts/close-concern-round.sh" \
            "$1" "$FCH_P" "$FCH_SID" security-scanner PERFORMED "$2" 2>/dev/null
    )" || FCH_CLOSE_RC=$?
}

fch_json() { printf '%s/%s-%s-unresolved-concerns.json' "$FCH_P" "$FCH_SID" "$FORMAT"; }
fch_check() {
    bash "$CLI" check-finalized --plans-dir "$FCH_P" --session-id "$FCH_SID" \
        --format "$FORMAT" --round "$1" >/dev/null 2>&1
    printf '%s' "$?"
}

# fch_ledgers — how many ledger files the whole chain created. More than one
# means the producers were never in the same review.
fch_ledgers() {
    find "$FCH_P" -maxdepth 1 -name '*concern-ledger.txt' -type f 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# X1. Round 1 of a review, end to end.
# ---------------------------------------------------------------------------
{
    fch_env 1
    fch_open
    X_ROUND="$(fch_kv ROUND)"

    assert_eq "X1: the first round of a fresh review opens as round 1" "1" "$X_ROUND"
    assert_eq "X1: and reports back the session the producers will share" \
        "$FCH_SID" "$(fch_kv SESSION_ID)"
    assert_not_contains "X1: round 1 offers no prior-concerns block, having nothing to report" \
        "[PRIOR CONCERNS START]" "$FCH_OPEN"

    X_BODY="$TMPDIR_BASE/fch-body-1.txt"
    mk_body "$X_BODY" "$(anchored HIGH - "bin/retry.sh" "retry_once" "correctness" "$FCH_CODEX")"
    fch_gates "$X_ROUND" "$X_BODY"

    assert_contains "X1: the review gate ran the codex reviewer" \
        "## Codex Review: PERFORMED" "$FCH_GATES"
    assert_contains "X1: and the gate runner accounted for every gate it owns" \
        "## gates: " "$FCH_GATES"

    X_LED="$(ledger_file "$FCH_P" "$FCH_SID")"
    assert_eq "X1: the reviewer's concern reached the shared ledger" \
        "1" "$(entry_count "$X_LED")"
    X_ID="$(id_for_text "$X_LED" "$FCH_CODEX")"
    assert_eq_nz "X1: it was minted as the first id of the cycle" "C1" "$X_ID"
    assert_eq "X1: and it is attributed to the codex producer" \
        "review-code-codex" "$(entry_field "$X_LED" "$X_ID" "$F_PRODUCERS")"

    # The scanner's half of the same round: the subagent is replayed as the
    # report file it is contracted to hand back, and close-concern-round.sh is
    # what brings it into the round the gates already wrote to.
    X_REPORT="$TMPDIR_BASE/fch-report-1.txt"
    mk_report "$X_REPORT" "$(anchored HIGH - "bin/auth.sh" "issue_token" "security" "$FCH_SCAN")"
    fch_close "$X_ROUND" "$X_REPORT"

    assert_eq "X1: the close-out ends the round successfully" "0" "$FCH_CLOSE_RC"
    assert_contains "X1: and reports the finalize it verified" "CHECK=ok" "$FCH_CLOSE"
    assert_contains "X1: with the tally of what the round left open" \
        "UNRESOLVED=open_high=2" "$FCH_CLOSE"

    assert_eq "X1: the whole chain wrote exactly one ledger" "1" "$(fch_ledgers)"
    assert_eq "X1: holding both producers' concerns, not one review each" \
        "2" "$(entry_count "$X_LED")"
    X_SID2="$(id_for_text "$X_LED" "$FCH_SCAN")"
    assert_eq_nz "X1: the scanner's concern was numbered after the reviewer's" "C2" "$X_SID2"
    assert_eq "X1: and attributed to the scanner" \
        "security-scanner" "$(entry_field "$X_LED" "$X_SID2" "$F_PRODUCERS")"
    assert_eq "X1: both producers staged into the same round" \
        "codex=present scanner=present" \
        "codex=$([ -f "$(delta_file "$FCH_P" "$FCH_SID" 1 review-code-codex)" ] && echo present || echo missing) scanner=$([ -f "$(delta_file "$FCH_P" "$FCH_SID" 1 security-scanner)" ] && echo present || echo missing)"

    # The chain's product: an artifact the caller can verify by round.
    X_JSON="$(cat "$(fch_json)" 2>/dev/null)"
    assert_eq "X1: check-finalized accepts the artifact for the round just closed" \
        "0" "$(fch_check 1)"
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
# X2. Round 2 over the same session. The round is what both producers must
#     agree on, and it is decided by a script neither of them calls — so the
#     second pass is where a drifting counter or a re-minted id would show.
# ---------------------------------------------------------------------------
{
    fch_open
    X2_ROUND="$(fch_kv ROUND)"

    assert_eq "X2: the next round of a live review opens as round 2" "2" "$X2_ROUND"
    assert_contains "X2: and hands the scanner the concerns still open" \
        "[PRIOR CONCERNS START]" "$FCH_OPEN"
    assert_contains "X2: naming the reviewer's concern by the id it already has" \
        "- C1 [HIGH]" "$FCH_OPEN"
    assert_contains "X2: and the scanner's alongside it" "- C2 [HIGH]" "$FCH_OPEN"

    # The reviewer re-raises its own concern by id and drops nothing new; the
    # scanner reports the finding it raised in round 1 as fixed by saying
    # nothing about it.
    X2_BODY="$TMPDIR_BASE/fch-body-2.txt"
    mk_body "$X2_BODY" "$(anchored HIGH C1 "bin/retry.sh" "retry_once" "correctness" "$FCH_CODEX")"
    fch_gates "$X2_ROUND" "$X2_BODY"

    X_LED="$(ledger_file "$FCH_P" "$FCH_SID")"
    assert_contains "X2: the round the wrapper joined is the one open-concern-round decided" \
        "$FORMAT-round-2-delta-review-code-codex" \
        "$(find "$FCH_P" -maxdepth 1 -name '*round-2-delta-*' 2>/dev/null | tr '\n' ' ')"
    assert_eq "X2: the re-raised concern keeps its original id" \
        "C1" "$(id_for_text "$X_LED" "$FCH_CODEX")"
    assert_eq "X2: still one ledger for the whole review" "1" "$(fch_ledgers)"

    X2_REPORT="$TMPDIR_BASE/fch-report-2.txt"
    mk_report "$X2_REPORT"
    fch_close "$X2_ROUND" "$X2_REPORT"

    assert_eq "X2: the second close-out also ends the round successfully" "0" "$FCH_CLOSE_RC"
    assert_contains "X2: and verifies its own finalize" "CHECK=ok" "$FCH_CLOSE"
    assert_eq "X2: the artifact now answers for round 2" "0" "$(fch_check 2)"
    assert_eq "X2: and no longer for round 1, so a stale copy cannot be reused" \
        "1" "$(fch_check 1)"

    X2_JSON="$(cat "$(fch_json)" 2>/dev/null)"
    assert_contains "X2: the re-raised concern is still open in the artifact" \
        "$FCH_CODEX" "$X2_JSON"
    assert_eq "X2: the ledger still holds both entries, one per producer" \
        "2" "$(entry_count "$X_LED")"
    assert_eq "X2: and the ids were never re-minted across the two rounds" \
        "C1 C2" "$(grep -oE '^C[0-9]+' "$X_LED" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
}

# ---------------------------------------------------------------------------
# X3. Closing the same round twice. The close-out is the step a caller re-runs
#     — it is the one that reports a failure worth retrying — so re-entry must
#     not double-count the round's concerns or move the artifact off the round
#     it describes.
# ---------------------------------------------------------------------------
{
    X3_BEFORE="$(md5sum "$(fch_json)" 2>/dev/null | cut -d' ' -f1)"
    X3_LED_BEFORE="$(md5sum "$(ledger_file "$FCH_P" "$FCH_SID")" 2>/dev/null | cut -d' ' -f1)"
    fch_close 2 "$X2_REPORT"

    assert_eq "X3: closing the same round a second time still succeeds" "0" "$FCH_CLOSE_RC"
    assert_contains "X3: and still reports a verified finalize" "CHECK=ok" "$FCH_CLOSE"
    assert_eq_nz "X3: the ledger is unchanged by the repeat" \
        "$X3_LED_BEFORE" "$(md5sum "$(ledger_file "$FCH_P" "$FCH_SID")" 2>/dev/null | cut -d' ' -f1)"
    assert_eq_nz "X3: and so is the artifact, byte for byte" \
        "$X3_BEFORE" "$(md5sum "$(fch_json)" 2>/dev/null | cut -d' ' -f1)"
    assert_eq "X3: no concern was duplicated by the second pass" \
        "2" "$(entry_count "$(ledger_file "$FCH_P" "$FCH_SID")")"
    assert_eq "X3: and the artifact still answers only for the round it closed" \
        "round2=0 round1=1" "round2=$(fch_check 2) round1=$(fch_check 1)"
}
