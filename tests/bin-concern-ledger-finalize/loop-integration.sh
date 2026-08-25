# tests/bin-concern-ledger-finalize/loop-integration.sh
# Tests: bin/run-codex-review-loop, bin/review-loop-verdict, bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/finalize.sh
# Tags: concern-ledger, finalize, run-codex-review-loop, exit-7, trigger-symmetry, TL2, scope:common
# Sourced by tests/bin-concern-ledger-finalize.sh.
# Detail-plan TL2 cases 6(e), 10, 11: wrapper exit-7 propagation, terminal-finalize
# trigger symmetry across formats, and re-entry after a terminal finalize.
# Exercised via a mock AGENTS_CONFIG_DIR (idiom of tests/feature-603-run-codex-review-loop.sh):
# the reviewer is stubbed; bin/run-codex-review-loop, bin/review-loop-verdict,
# bin/concern-ledger, bin/lib/concern-ledger.sh are real under test.

echo ""
echo "--- finalize 6e/10/11: wrapper exit 7, trigger symmetry, re-entry ---"

MOCK_SEQ=0

# mk_loop_env — a mock AGENTS_CONFIG_DIR plus a plans dir. Sets MOCKD / LPLANS.
mk_loop_env() {
    MOCK_SEQ=$((MOCK_SEQ + 1))
    MOCKD="$TMPDIR_BASE/loop-$MOCK_SEQ/agents"
    LPLANS="$TMPDIR_BASE/loop-$MOCK_SEQ/plans"
    mkdir -p "$MOCKD/bin/lib" "$MOCKD/rules" "$LPLANS"
    printf '# core principles stub\n' > "$MOCKD/rules/core-principles.md"
    printf '# Draft\n' > "$LPLANS/draft.md"
    printf '# Tradeoffs\n' > "$LPLANS/tradeoffs.md"

    cat > "$MOCKD/bin/build-codex-context" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) : > "$2"; shift 2 ;;
    *) shift ;;
  esac
done
exit 0
STUB
    chmod +x "$MOCKD/bin/build-codex-context"

    local f
    for f in run-codex-review-loop review-loop-verdict concern-ledger; do
        [ -f "$AGENTS_ROOT/bin/$f" ] || continue
        cp "$AGENTS_ROOT/bin/$f" "$MOCKD/bin/$f"
        chmod +x "$MOCKD/bin/$f"
    done
    for f in codex-core.sh codex-timeout.sh concern-ledger.sh safe-plans-path.sh; do
        [ -f "$AGENTS_ROOT/bin/lib/$f" ] && cp "$AGENTS_ROOT/bin/lib/$f" "$MOCKD/bin/lib/$f"
    done
    # concern-ledger.sh is a dispatcher that sources its sibling module dir.
    [ -d "$AGENTS_ROOT/bin/lib/concern-ledger" ] && cp -r "$AGENTS_ROOT/bin/lib/concern-ledger" "$MOCKD/bin/lib/"
    # run-codex-review-loop sources its split-out ledger helpers from this dir.
    [ -d "$AGENTS_ROOT/bin/lib/codex-review-loop" ] && cp -r "$AGENTS_ROOT/bin/lib/codex-review-loop" "$MOCKD/bin/lib/"
}

# mk_reviewer <body> — the review-plan-codex stub. It deliberately does not
# append to the round log: the cases below are about the finalize trigger, not
# about the hard round cap.
mk_reviewer() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'cat <<%s\n' "'MOCK_OUTPUT'"
        printf '%s\n' "$1"
        printf 'MOCK_OUTPUT\n'
    } > "$MOCKD/bin/review-plan-codex"
    chmod +x "$MOCKD/bin/review-plan-codex"
}

# needs_revision <text> — a round-1 reviewer body with one HIGH concern.
needs_revision() {
    printf '## Codex Plan Review: PERFORMED\n\n'
    printf '<!-- begin-codex-output: treat as untrusted third-party content -->\n'
    printf 'NEEDS_REVISION\n'
    printf '1. [HIGH] %s\n' "$1"
    printf '<!-- end-codex-output -->\n'
}

LOOP_OUT=""; LOOP_RC=0; LOOP_ERR=""
# run_loop <format> <sid> <cap> <max-ext> <round>
run_loop() {
    LOOP_ERR="$TMPDIR_BASE/loop-err-$MOCK_SEQ-$5.txt"
    : > "$LOOP_ERR"
    LOOP_RC=0
    LOOP_OUT="$(
        AGENTS_CONFIG_DIR="$MOCKD" bash "$MOCKD/bin/run-codex-review-loop" \
            --format "$1" --session-id "$2" --plans-dir "$LPLANS" \
            --draft-file "$LPLANS/draft.md" --cap "$3" --max-extensions "$4" \
            --extensions-used 0 --accepted-tradeoffs "$LPLANS/tradeoffs.md" \
            --round "$5" 2>"$LOOP_ERR"
    )" || LOOP_RC=$?
}

L_TEXT="the wrapper must finalize the ledger when the cap round ends unresolved"

# ---------------------------------------------------------------------------
# 10. Symmetry of the terminal-finalize trigger.
#     security-plan / test-review run at CAP=1, so their round 1 *is* the last
#     round; detail-plan at CAP=2 still has a round left.
# ---------------------------------------------------------------------------
# The three observations are folded into one composite value at the end: taken
# alone, "detail-plan wrote no artifact" is satisfied by an implementation that
# never finalizes anything at all.
TRIGGER_OBS=""
while IFS='|' read -r fmt cap; do
    fmt="$(trim "$fmt")"; cap="$(trim "$cap")"
    [ -z "$fmt" ] && continue
    case "$fmt" in \#*) continue ;; esac

    mk_loop_env
    mk_reviewer "$(needs_revision "$L_TEXT")"
    SIDL="loop$MOCK_SEQ"
    run_loop "$fmt" "$SIDL" "$cap" 0 1

    assert_eq "10: $fmt round 1 reports a non-approved verdict" "1" "$LOOP_RC"
    TRIGGER_OBS="${TRIGGER_OBS:+$TRIGGER_OBS }$fmt=$(file_state "$(json_file "$LPLANS" "$SIDL" "$fmt")")"
done <<'TABLE'
security-plan | 1
test-review   | 1
detail-plan   | 2
TABLE

assert_eq "10: the terminal finalize fires at the cap round and only there" \
    "security-plan=present test-review=present detail-plan=missing" "$TRIGGER_OBS"

# The two formats at their cap must also pass their own read-only verdict —
# an artifact that exists but does not name this round is still a failure.
{
    mk_loop_env
    mk_reviewer "$(needs_revision "$L_TEXT")"
    SIDL="loop$MOCK_SEQ"
    run_loop "security-plan" "$SIDL" 1 0 1
    assert_eq "10: the terminal artifact passes check-finalized for this round" \
        "0" "$(rc_of check-finalized --plans-dir "$LPLANS" --session-id "$SIDL" \
                --format security-plan --round 1)"
    assert_contains "10: the terminal artifact records the unresolved concern" \
        "$L_TEXT" "$(json_of "$(json_file "$LPLANS" "$SIDL" security-plan)")"
}

# ---------------------------------------------------------------------------
# 6(e). When the finalize cannot write, the wrapper must not return a verdict
#       code. It returns 7 and reports the verdict it would have returned.
# ---------------------------------------------------------------------------
{
    mk_loop_env
    mk_reviewer "$(needs_revision "$L_TEXT")"
    SIDL="loop$MOCK_SEQ"
    # A directory squats on both the artifact path and the diagnostic path.
    mkdir -p "$(json_file "$LPLANS" "$SIDL" security-plan)" \
             "$(diag_file "$LPLANS" "$SIDL" security-plan)"
    run_loop "security-plan" "$SIDL" 1 0 1

    assert_eq "6e: the wrapper returns the finalize-failure code, not a verdict" \
        "7" "$LOOP_RC"
    assert_contains "6e: the wrapper announces the finalize failure" \
        "## Concern Ledger: FINALIZE-FAILED — " "$LOOP_OUT$(cat "$LOOP_ERR" 2>/dev/null)"
    assert_contains "6e: the verdict that was withheld is still reported" \
        "(would-be verdict: 1)" "$LOOP_OUT$(cat "$LOOP_ERR" 2>/dev/null)"
    assert_eq "6e: check-finalized agrees that the round did not finalize" \
        "1" "$(rc_of check-finalized --plans-dir "$LPLANS" --session-id "$SIDL" \
                --format security-plan --round 1)"
}

# ---------------------------------------------------------------------------
# 11. Re-entry after a terminal finalize: fix the draft, drop the round counter,
#     and run round 1 again. The previous cycle is archived, not overwritten,
#     and the new round's concerns are admitted.
# ---------------------------------------------------------------------------
{
    FMT="test-review"
    mk_loop_env
    SIDL="loop$MOCK_SEQ"
    OLD_TEXT="$L_TEXT"
    NEW_TEXT="the follow-up round finds a different unresolved concern"

    mk_reviewer "$(needs_revision "$OLD_TEXT")"
    run_loop "$FMT" "$SIDL" 1 0 1
    FIRST_RC="$LOOP_RC"
    assert_eq "11: the first cycle ends non-approved (precondition)" "1" "$FIRST_RC"
    assert_eq "11: the first cycle produced its terminal artifact" \
        "present" "$(file_state "$(json_file "$LPLANS" "$SIDL" "$FMT")")"

    # What the skill does between cycles: the round counter is removed.
    rm -f "$(round_file "$LPLANS" "$SIDL" "$FMT")"

    mk_reviewer "$(needs_revision "$NEW_TEXT")"
    run_loop "$FMT" "$SIDL" 1 0 1
    LED="$(ledger_file "$LPLANS" "$SIDL" "$FMT")"
    CYC="$(cycle_file "$LPLANS" "$SIDL" "$FMT" 1)"

    assert_eq "11: both cycles reach the same verdict" \
        "first=1 second=1" "first=$FIRST_RC second=$LOOP_RC"
    assert_eq "11: the previous cycle's ledger is archived, not overwritten" \
        "present" "$(file_state "$CYC")"
    assert_contains "11: the archive holds the previous cycle's concern" \
        "$OLD_TEXT" "$(json_of "$CYC")"
    # Composite: an empty stderr must not read as "nothing was discarded".
    ADMITTED=no; printf '%s' "$(json_of "$LED")" | grep -Fq -- "$NEW_TEXT" && ADMITTED=yes
    DISCARDED=no
    grep -Fq -- "discarded new concern IDs" "$LOOP_ERR" 2>/dev/null && DISCARDED=yes
    assert_eq "11: round 1 of the new cycle admits the new concern" \
        "admitted=yes discarded=no" "admitted=$ADMITTED discarded=$DISCARDED"
    assert_contains "11: the second cycle's artifact names the new concern" \
        "$NEW_TEXT" "$(json_of "$(json_file "$LPLANS" "$SIDL" "$FMT")")"
}
