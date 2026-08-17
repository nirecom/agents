# tests/bin-concern-ledger-shared-code-review/prior-producers.sh
# Tests: bin/review-code-ledger, bin/concern-ledger, agents/security-scanner.md
# Tags: concern-ledger, review-code, prior-concerns, shared-ledger, TL2, scope:common

# Sourced by tests/bin-concern-ledger-shared-code-review.sh.
# Detail-plan Test plan (shared TL2) cases 4, 5, 6, 9 — prior-concern injection,
# the two-producer join into a single ledger, the artifact naming, and the
# ABSENT treatment of a report that carries no Concern Delta section.
#
# Case 4 observes the injection at the reviewer prompt (captured by the codex
# mock) rather than at review-code-codex's argv: the prompt is where
# --concerns-file has to end up for the reviewer to see it, and asserting there
# keeps the real bin/review-code-codex inside the tested chain.

echo ""
echo "--- shared 4/5/6/9: prior injection, producer join, naming, ABSENT reports ---"

CPATH="bin/review-code-ledger"
CANCHOR="stage_delta"
CCAT="correctness"
CTEXT="the wrapper must not swallow the reviewer's execution label"

SPATH="skills/review-code-security/scripts/run-quality-gates.sh"
SANCHOR="_run_gate"
SCAT="security"
STEXT="the scanner report is staged by the Completion close-out, never by the scanner itself"

pwork() { mktemp -d "$TMPDIR_BASE/pri-XXXXXX"; }

# ---------------------------------------------------------------------------
# 4. Prior injection symmetry.
# ---------------------------------------------------------------------------
{
    PW=$(pwork)
    new_env
    LEDGER="$(ledger_file "$PLANS" "$SID")"

    mk_body "$PW/b1.txt" "$(anchored HIGH - "$CPATH" "$CANCHOR" "$CCAT" "$CTEXT")"
    RL_CODEX_BODY="$PW/b1.txt"
    RL_ROUND=1
    run_ledger
    P1_FILE="$LAST_PROMPT"

    ID1="$(id_for_text "$LEDGER" "$CTEXT")"
    assert_match "4: round 1 mints an ID for the reported concern (precondition)" \
        '^C[0-9]+$' "$ID1"

    PRIOR="$(run_cli render-prior --plans-dir "$PLANS" --session-id "$SID" \
        --format "$FORMAT" 2>/dev/null || true)"
    LIB_PRIOR="$(cl cl_render_prior "$LEDGER" 2>/dev/null || true)"
    assert_eq_nz "4: render-prior CLI and cl_render_prior are one implementation" \
        "$LIB_PRIOR" "$PRIOR"
    assert_match "4: the rendered prior carries the C<N> that B1 binds on" \
        'C[0-9]+' "$PRIOR"
    assert_contains "4: the rendered prior carries the concern text" "$CTEXT" "$PRIOR"

    mk_body "$PW/b2.txt" "$(anchored HIGH "$ID1" "$CPATH" "$CANCHOR" "$CCAT" "$CTEXT")"
    RL_CODEX_BODY="$PW/b2.txt"
    RL_ROUND=2
    run_ledger
    PROMPT2="$(cat "$LAST_PROMPT" 2>/dev/null || true)"
    assert_contains_block "4: round 2 injects the rendered prior into the reviewer prompt" \
        "$PRIOR" "$PROMPT2"

    # Round 1 has no prior: the reviewer prompt must have been built, and must
    # carry no concern block. The composite value keeps an empty prompt (i.e. a
    # wrapper that never ran) from passing as "no prior injected".
    PROMPT1="$(cat "$P1_FILE" 2>/dev/null || true)"
    R1_BUILT=empty
    [ -n "$(trim "$PROMPT1")" ] && R1_BUILT=present
    R1_PRIOR=absent
    printf '%s' "$PROMPT1" | grep -Fq -- "$CTEXT" && R1_PRIOR=injected
    assert_eq "4: round 1 builds a prompt and injects no prior into it" \
        "prompt=present prior=absent" "prompt=$R1_BUILT prior=$R1_PRIOR"
}

# ---------------------------------------------------------------------------
# 5. Two producers, one ledger — and a round missing a producer must not
#    resolve that producer's concerns (detail plan decision c's core failure mode).
# ---------------------------------------------------------------------------
{
    PW=$(pwork)
    new_env
    LEDGER="$(ledger_file "$PLANS" "$SID")"

    mk_body "$PW/b1.txt" "$(anchored HIGH - "$CPATH" "$CANCHOR" "$CCAT" "$CTEXT")"
    RL_CODEX_BODY="$PW/b1.txt"
    RL_ROUND=1
    run_ledger

    mk_report "$PW/scan1.txt" "$(anchored MEDIUM - "$SPATH" "$SANCHOR" "$SCAT" "$STEXT")"
    run_cli stage --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" \
        --round 1 --producer security-scanner --from-report "$PW/scan1.txt" >/dev/null 2>&1
    run_cli reduce --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" \
        --round 1 >/dev/null 2>&1

    ID_C="$(id_for_text "$LEDGER" "$CTEXT")"
    ID_S="$(id_for_text "$LEDGER" "$STEXT")"
    assert_eq "5: both producers' concerns land in one ledger" "2" "$(entry_count "$LEDGER")"
    assert_eq "5: the codex concern and the scanner concern get distinct IDs" \
        "new" "$(id_class "$ID_S" "$ID_C")"
    assert_eq "5: the scanner entry records its own origin" \
        "security-scanner" "$(entry_field "$LEDGER" "$ID_S" $F_ORIGIN)"
    assert_eq "5: the codex entry records its own origin" \
        "review-code-codex" "$(entry_field "$LEDGER" "$ID_C" $F_ORIGIN)"
    assert_eq "5: exactly one ledger file serves both producers" \
        "1" "$(ls "$PLANS" 2>/dev/null | grep -c 'concern-ledger\.txt$' || true)"

    # Round 2: only review-code-codex reports. The scanner's concern is absent
    # from this round's delta, but the round is incomplete, so it cannot resolve.
    mk_body "$PW/b2.txt" "$(anchored HIGH "$ID_C" "$CPATH" "$CANCHOR" "$CCAT" "$CTEXT")"
    RL_CODEX_BODY="$PW/b2.txt"
    RL_ROUND=2
    run_ledger
    assert_eq "5: a round without the scanner cannot resolve the scanner's concern" \
        "open" "$(entry_field "$LEDGER" "$ID_S" $F_STATE)"
    assert_eq "5: the unreported entry is flagged stale, not silently carried" \
        "has" "$(flag_state "$LEDGER" "$ID_S" stale)"
    assert_eq "5: the reporting producer's own entry stays open" \
        "open" "$(entry_field "$LEDGER" "$ID_C" $F_STATE)"
}

# ---------------------------------------------------------------------------
# 6. Naming — the shared ledger must be distinguishable from the security-plan
#    ledger by machine as well as by eye (completion criterion 5).
# ---------------------------------------------------------------------------
{
    PW=$(pwork)
    new_env
    mk_body "$PW/b1.txt" "$(anchored HIGH - "$CPATH" "$CANCHOR" "$CCAT" "$CTEXT")"
    RL_CODEX_BODY="$PW/b1.txt"
    RL_ROUND=1
    run_ledger

    # Composite: an empty plans dir must not read as "the confusing name was avoided".
    assert_eq "6: the shared token is used and no security-plan artifact appears" \
        "shared=present security-plan=0" \
        "shared=$(file_state "$(ledger_file "$PLANS" "$SID")") security-plan=$(ls "$PLANS" 2>/dev/null | grep -c 'security-plan' || true)"
    assert_eq "6: the round counter uses the same token" \
        "present" "$(file_state "$(round_file "$PLANS" "$SID")")"
    assert_eq "6: the staging file uses the same token and the producer name" \
        "present" "$(file_state "$(delta_file "$PLANS" "$SID" 1 review-code-codex)")"
}

# ---------------------------------------------------------------------------
# 9. A producer report with no '## Concern Delta' section is ABSENT — absence
#    then cannot resolve anything.
# ---------------------------------------------------------------------------
{
    PW=$(pwork)
    new_env
    LEDGER="$(ledger_file "$PLANS" "$SID")"

    mk_body "$PW/b1.txt" "$(anchored HIGH - "$CPATH" "$CANCHOR" "$CCAT" "$CTEXT")"
    RL_CODEX_BODY="$PW/b1.txt"
    RL_ROUND=1
    run_ledger
    ID_C="$(id_for_text "$LEDGER" "$CTEXT")"
    assert_match "9: round 1 mints the entry that round 2 must not resolve" \
        '^C[0-9]+$' "$ID_C"

    printf '# Security Scan Report\n\nNothing structured here.\n' > "$PW/nodelta.txt"
    run_cli stage --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" \
        --round 2 --producer security-scanner --from-report "$PW/nodelta.txt" >/dev/null 2>&1
    SDF="$(delta_file "$PLANS" "$SID" 2 security-scanner)"
    assert_eq "9: a report without a Concern Delta section parses as ABSENT" \
        "ABSENT" "$(staging_field "$SDF" 5)"
    assert_eq "9: its completeness is ABSENT too" \
        "ABSENT" "$(staging_field "$SDF" 3)"

    RL_CODEX_BODY="$NONE_BODY"
    RL_ROUND=2
    run_ledger
    run_cli reduce --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" \
        --round 2 >/dev/null 2>&1
    assert_eq "9: absence under an ABSENT producer does not resolve the entry" \
        "open" "$(entry_field "$LEDGER" "$ID_C" $F_STATE)"
    assert_eq "9: the blocked entry is flagged stale" \
        "has" "$(flag_state "$LEDGER" "$ID_C" stale)"
}
