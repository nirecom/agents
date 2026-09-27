# tests/bin/bin-codex-review-loop-security-code/prior-producers.sh
# Tests: bin/run-codex-review-loop, bin/concern-ledger, agents/security-scanner.md
# Tags: concern-ledger, review-code, prior-concerns, shared-ledger, TL2, scope:common
# Sourced by tests/bin/bin-codex-review-loop-security-code.sh.
# Prior-concern injection, the two-producer join into one ledger, the artifact
# naming, and the ABSENT treatment of a report with no Concern Delta section.
#
# The injection is observed at the reviewer prompt captured by the codex mock:
# that is where the prior has to arrive for the reviewer to see it, and asserting
# there keeps the real bin/review-code-codex inside the tested chain.

echo ""
echo "--- N: prior injection, producer join, naming, ABSENT reports ---"

CPATH="bin/run-codex-review-loop"
CANCHOR="stage_delta"
CCAT="correctness"
CTEXT="the loop must not swallow the reviewer's execution label"

SPATH="skills/review-code-security/scripts/run-codex-review-loop.sh"
SANCHOR="_run_loop"
SCAT="security"
STEXT="the scanner report re-enters the loop instead of touching the ledger itself"

pwork() { mktemp -d "$TMPDIR_BASE/pri-XXXXXX"; }

# stage_scanner <round> <report> — the scanner half of a round, as the fallback
# performs it: the SAME loop, re-entered with the report already produced.
stage_scanner() {
    RL_EXTRA=(--prestaged-report "$2" --prestaged-producer security-scanner
              --prestaged-exec "${3:-PERFORMED}")
    run_loop --round "$1"
    RL_EXTRA=()
}

# ---------------------------------------------------------------------------
# N1. Prior injection symmetry.
# ---------------------------------------------------------------------------
{
    PW=$(pwork)
    new_env
    LEDGER="$(ledger_file "$PLANS" "$SID")"

    mk_body "$PW/b1.txt" "$(anchored HIGH - "$CPATH" "$CANCHOR" "$CCAT" "$CTEXT")"
    RL_CODEX_BODY="$PW/b1.txt"
    run_loop --round 1
    P1_FILE="$LAST_PROMPT"

    ID1="$(id_for_text "$LEDGER" "$CTEXT")"
    assert_match "N1: round 1 mints an ID for the reported concern (precondition)" \
        '^C[0-9]+$' "$ID1"

    PRIOR="$(run_cli render-prior --plans-dir "$PLANS" --session-id "$SID" \
        --format "$LEDGER_FORMAT" 2>/dev/null || true)"
    LIB_PRIOR="$(cl cl_render_prior "$LEDGER" 2>/dev/null || true)"
    assert_eq_nz "N1: render-prior CLI and cl_render_prior are one implementation" \
        "$LIB_PRIOR" "$PRIOR"
    assert_match "N1: the rendered prior carries the C<N> the reviewer binds on" 'C[0-9]+' "$PRIOR"
    assert_contains "N1: the rendered prior carries the concern text" "$CTEXT" "$PRIOR"

    mk_body "$PW/b2.txt" "$(anchored HIGH "$ID1" "$CPATH" "$CANCHOR" "$CCAT" "$CTEXT")"
    RL_CODEX_BODY="$PW/b2.txt"
    run_loop --round 2
    PROMPT2="$(cat "$LAST_PROMPT" 2>/dev/null || true)"
    assert_contains_block "N1: round 2 injects the rendered prior into the reviewer prompt" \
        "$PRIOR" "$PROMPT2"

    PROMPT1="$(cat "$P1_FILE" 2>/dev/null || true)"
    R1_BUILT=empty
    [ -n "$(trim "$PROMPT1")" ] && R1_BUILT=present
    R1_PRIOR=absent
    printf '%s' "$PROMPT1" | grep -Fq -- "$CTEXT" && R1_PRIOR=injected
    assert_eq "N1: round 1 builds a prompt and injects no prior into it" \
        "prompt=present prior=absent" "prompt=$R1_BUILT prior=$R1_PRIOR"
}

# ---------------------------------------------------------------------------
# N2. Two producers, one ledger — and a round missing a producer must not
#     resolve that producer's concerns.
# ---------------------------------------------------------------------------
{
    PW=$(pwork)
    new_env
    LEDGER="$(ledger_file "$PLANS" "$SID")"

    mk_body "$PW/b1.txt" "$(anchored HIGH - "$CPATH" "$CANCHOR" "$CCAT" "$CTEXT")"
    RL_CODEX_BODY="$PW/b1.txt"
    run_loop --round 1

    mk_report "$PW/scan1.txt" "$(anchored MEDIUM - "$SPATH" "$SANCHOR" "$SCAT" "$STEXT")"
    stage_scanner 1 "$PW/scan1.txt"

    ID_C="$(id_for_text "$LEDGER" "$CTEXT")"
    ID_S="$(id_for_text "$LEDGER" "$STEXT")"
    assert_eq "N2: both producers' concerns land in one ledger" "2" "$(entry_count "$LEDGER")"
    assert_eq "N2: the codex concern and the scanner concern get distinct IDs" \
        "new" "$(id_class "$ID_S" "$ID_C")"
    assert_eq "N2: the scanner entry records its own origin" \
        "security-scanner" "$(entry_field "$LEDGER" "$ID_S" $F_ORIGIN)"
    assert_eq "N2: the codex entry records its own origin" \
        "review-code-codex" "$(entry_field "$LEDGER" "$ID_C" $F_ORIGIN)"
    assert_eq "N2: exactly one ledger file serves both producers" \
        "1" "$(ls "$PLANS" 2>/dev/null | grep -c 'concern-ledger\.txt$' || true)"

    # Round 2: only the reviewer reports. The scanner's concern is absent from
    # this round's delta, but absence under a producer that never ran cannot
    # resolve anything.
    mk_body "$PW/b2.txt" "$(anchored HIGH "$ID_C" "$CPATH" "$CANCHOR" "$CCAT" "$CTEXT")"
    RL_CODEX_BODY="$PW/b2.txt"
    run_loop --round 2
    assert_eq "N2: a round without the scanner cannot resolve the scanner's concern" \
        "open" "$(entry_field "$LEDGER" "$ID_S" $F_STATE)"
    assert_eq "N2: the unreported entry is flagged stale, not silently carried" \
        "has" "$(flag_state "$LEDGER" "$ID_S" stale)"
    assert_eq "N2: the reporting producer's own entry stays open" \
        "open" "$(entry_field "$LEDGER" "$ID_C" $F_STATE)"
}

# ---------------------------------------------------------------------------
# N3. Naming — the shared ledger is addressed by the ledger format while the
#     round counter is addressed by the loop format, and neither name collides
#     with the security-plan review that runs in the same session.
# ---------------------------------------------------------------------------
{
    PW=$(pwork)
    new_env
    mk_body "$PW/b1.txt" "$(anchored HIGH - "$CPATH" "$CANCHOR" "$CCAT" "$CTEXT")"
    RL_CODEX_BODY="$PW/b1.txt"
    run_loop --round 1

    assert_eq "N3: the shared token is used and no security-plan artifact appears" \
        "shared=present security-plan=0" \
        "shared=$(file_state "$(ledger_file "$PLANS" "$SID")") security-plan=$(ls "$PLANS" 2>/dev/null | grep -c 'security-plan' || true)"
    assert_eq "N3: the round counter is filed under the loop format" \
        "present" "$(file_state "$(round_file "$PLANS" "$SID")")"
    assert_eq "N3: and not under the ledger format" \
        "missing" "$(file_state "$PLANS/$SID-$LEDGER_FORMAT-round-number.txt")"
    assert_eq "N3: the staging file uses the ledger token and the producer name" \
        "present" "$(file_state "$(delta_file "$PLANS" "$SID" 1 review-code-codex)")"
    assert_eq "N3: exactly one round-number file exists for the review" \
        "1" "$(ls "$PLANS" 2>/dev/null | grep -c 'round-number\.txt$' || true)"
}

# ---------------------------------------------------------------------------
# N4. A producer report with no '## Concern Delta' section is ABSENT — absence
#     then cannot resolve anything.
# ---------------------------------------------------------------------------
{
    PW=$(pwork)
    new_env
    LEDGER="$(ledger_file "$PLANS" "$SID")"

    mk_body "$PW/b1.txt" "$(anchored HIGH - "$CPATH" "$CANCHOR" "$CCAT" "$CTEXT")"
    RL_CODEX_BODY="$PW/b1.txt"
    run_loop --round 1
    ID_C="$(id_for_text "$LEDGER" "$CTEXT")"
    assert_match "N4: round 1 mints the entry that round 2 must not resolve" \
        '^C[0-9]+$' "$ID_C"

    printf '# Security Scan Report\n\nNothing structured here.\n' > "$PW/nodelta.txt"
    RL_CODEX_BODY="$NONE_BODY"
    stage_scanner 2 "$PW/nodelta.txt"
    SDF="$(delta_file "$PLANS" "$SID" 2 security-scanner)"
    assert_eq "N4: a report without a Concern Delta section parses as ABSENT" \
        "ABSENT" "$(staging_field "$SDF" 6)"
    assert_eq "N4: its completeness is ABSENT too" "ABSENT" "$(staging_field "$SDF" 3)"

    run_loop --round 2
    assert_eq "N4: absence under an ABSENT producer does not resolve the entry" \
        "open" "$(entry_field "$LEDGER" "$ID_C" $F_STATE)"
    assert_eq "N4: the blocked entry is flagged stale" \
        "has" "$(flag_state "$LEDGER" "$ID_C" stale)"
}
