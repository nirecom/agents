# tests/bin-concern-ledger-shared-code-review/labels-stdout.sh
# Tests: bin/review-code-ledger, bin/concern-ledger
# Tags: concern-ledger, review-code, exec-label, stdout-contract, TL2, scope:common
# Sourced by tests/bin-concern-ledger-shared-code-review.sh.
# Detail-plan Test plan (shared TL2) cases 1, 2, 3 — the execution-label mapping,
# the verbatim-stdout contract, and the standalone persistence path.

echo ""
echo "--- shared 1/2/3: exec labels, verbatim stdout, standalone persistence ---"

LPATH="bin/review-code-ledger"
LANCHOR="resolve_round"
LCAT="correctness"
LTEXT="the wrapper must stage the delta even when CONCERN_LEDGER_ROUND is unset"
LLINE="$(anchored HIGH - "$LPATH" "$LANCHOR" "$LCAT" "$LTEXT")"

lwork() { mktemp -d "$TMPDIR_BASE/lab-XXXXXX"; }

# ---------------------------------------------------------------------------
# 1. Execution label mapping (detail plan decision c):
#      PERFORMED                     -> COMPLETE
#      PERFORMED + Scope: TRUNCATED  -> PARTIAL
#      PERFORMED + Scope: BASE-*     -> PARTIAL
#      SKIPPED / FAILED              -> ABSENT
#    Every row also asserts the stdout marker that drives the mapping, so a
#    mis-built fixture can never be read as a mapping result.
# ---------------------------------------------------------------------------
while IFS='|' read -r name scenario want_exec want_marker; do
    name="$(trim "$name")"; scenario="$(trim "$scenario")"
    want_exec="$(trim "$want_exec")"; want_marker="$(trim "$want_marker")"
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac

    LW=$(lwork)
    new_env
    mk_body "$LW/body.txt" "$LLINE"
    RL_CODEX_BODY="$LW/body.txt"
    case "$scenario" in
        PERFORMED)    ;;
        TRUNCATED)    RL_REPO="$REPO_BIG" ;;
        BASE-SUSPECT) RL_BASE_STATE="SUSPECT" ;;
        SKIPPED)      RL_PATH="$NO_CODEX_PATH" ;;
        FAILED)       RL_CODEX_EXIT=3 ;;
        *) fail "1: unknown scenario token '$scenario' in row $name"; continue ;;
    esac
    run_ledger
    assert_contains "1: $name — the reviewer emitted the expected label" \
        "$want_marker" "$LAST_OUT"
    assert_eq "1: $name — staged exec label" \
        "$want_exec" "$(staging_field "$(delta_file "$PLANS" "$SID" 1 review-code-codex)" 4)"
done <<'TABLE'
performed-only     | PERFORMED    | COMPLETE | ## Codex Review: PERFORMED
truncated-scope    | TRUNCATED    | PARTIAL  | ## Codex Review Scope: TRUNCATED
base-suspect-scope | BASE-SUSPECT | PARTIAL  | ## Codex Review Scope: BASE-SUSPECT
codex-skipped      | SKIPPED      | ABSENT   | ## Codex Review: SKIPPED
codex-failed       | FAILED       | ABSENT   | ## Codex Review: FAILED
TABLE

# 1f. completeness = min(exec, parse): a TRUNCATED scope demotes the round even
#     though the delta itself parsed cleanly.
{
    LW=$(lwork)
    new_env
    mk_body "$LW/body.txt" "$LLINE"
    RL_CODEX_BODY="$LW/body.txt"
    RL_REPO="$REPO_BIG"
    run_ledger
    DF="$(delta_file "$PLANS" "$SID" 1 review-code-codex)"
    assert_eq "1f: a well-formed delta still parses COMPLETE" \
        "COMPLETE" "$(staging_field "$DF" 5)"
    assert_eq "1f: completeness is the min of exec and parse" \
        "PARTIAL" "$(staging_field "$DF" 3)"
    assert_eq "1f: the staging header records the producer name" \
        "review-code-codex" "$(staging_field "$DF" 2)"
    assert_eq "1f: the staging header records the round" \
        "1" "$(staging_field "$DF" 6)"
}

# ---------------------------------------------------------------------------
# 2. The wrapper's stdout is byte-for-byte what bin/review-code-codex prints —
#    run-quality-gates.sh and the user-visible contract must not change.
# ---------------------------------------------------------------------------
{
    LW=$(lwork)
    new_env
    mk_body "$LW/body.txt" "$LLINE"
    RL_CODEX_BODY="$LW/body.txt"
    run_ledger
    DIRECT_OUT="$(run_codex_direct)"

    assert_contains "2: the comparison baseline is a real review" \
        "## Codex Review: PERFORMED" "$DIRECT_OUT"
    assert_eq_nz "2: the wrapper reprints the reviewer output verbatim" \
        "$DIRECT_OUT" "$LAST_OUT"
    # Composite: an empty stdout must not read as "no notice was printed".
    NS_STATE=absent
    printf '%s' "$LAST_OUT" | grep -Fq -- "## Concern Ledger: NOT-STAGED" && NS_STATE=printed
    OUT_STATE=empty
    [ -n "$(trim "$LAST_OUT")" ] && OUT_STATE=present
    assert_eq "2: a resolvable session prints output and no NOT-STAGED notice" \
        "stdout=present notice=absent" "stdout=$OUT_STATE notice=$NS_STATE"
    assert_eq "2: the wrapper inherits the never-block contract (exit 0)" "0" "$LAST_RC"
}

# ---------------------------------------------------------------------------
# 3. Standalone execution path (/review-code-codex run by hand).
# ---------------------------------------------------------------------------
# (a) CONCERN_LEDGER_ROUND unset — staging is not skipped; round 1 is created.
{
    LW=$(lwork)
    new_env
    mk_body "$LW/body.txt" "$LLINE"
    RL_CODEX_BODY="$LW/body.txt"
    run_ledger
    assert_eq "3a: the ledger is persisted without CONCERN_LEDGER_ROUND" \
        "present" "$(file_state "$(ledger_file "$PLANS" "$SID")")"
    assert_eq "3a: the round-number file is created at 1" \
        "1" "$(trim "$(cat "$(round_file "$PLANS" "$SID")" 2>/dev/null || true)")"
    assert_eq "3a: the delta is staged under round 1" \
        "present" "$(file_state "$(delta_file "$PLANS" "$SID" 1 review-code-codex)")"
    NS_STATE=absent
    printf '%s' "$LAST_OUT" | grep -Fq -- "NOT-STAGED" && NS_STATE=printed
    OUT_STATE=empty
    [ -n "$(trim "$LAST_OUT")" ] && OUT_STATE=present
    assert_eq "3a: the review is printed and nothing is silently skipped" \
        "stdout=present notice=absent" "stdout=$OUT_STATE notice=$NS_STATE"
    assert_match "3a: the concern reached the ledger" \
        '^C[0-9]+$' "$(id_for_text "$(ledger_file "$PLANS" "$SID")" "$LTEXT")"
}

# (b) An in-flight round is joined, never incremented.
{
    LW=$(lwork)
    new_env
    mk_body "$LW/body.txt" "$LLINE"
    RL_CODEX_BODY="$LW/body.txt"
    printf '2\n' > "$(round_file "$PLANS" "$SID")"
    run_ledger
    # One composite value: the counter must be unchanged AND the wrapper must
    # have actually staged into the joined round (an untouched fixture fails).
    assert_eq "3b: the in-flight round is joined, not incremented" \
        "round=2 r2=present r3=missing" \
        "round=$(trim "$(cat "$(round_file "$PLANS" "$SID")" 2>/dev/null || true)") r2=$(file_state "$(delta_file "$PLANS" "$SID" 2 review-code-codex)") r3=$(file_state "$(delta_file "$PLANS" "$SID" 3 review-code-codex)")"
}

# (c) PLANS_DIR genuinely unresolvable — the only case where staging is skipped,
#     and it must say so out loud while still exiting 0.
{
    LW=$(lwork)
    new_env
    mk_body "$LW/body.txt" "$LLINE"
    RL_CODEX_BODY="$LW/body.txt"
    RL_PLANS=""            # no PLANS_DIR / SESSION_ID in the environment
    : > "$LW/nothome"      # a regular file, so $HOME/... can never be created
    RL_HOME="$LW/nothome/sub"
    run_ledger
    assert_contains "3c: an unresolvable plans dir is announced, not silent" \
        "## Concern Ledger: NOT-STAGED — " "$LAST_OUT"
    assert_eq "3c: the wrapper still exits 0" "0" "$LAST_RC"
    assert_contains "3c: the review itself still runs and is printed" \
        "## Codex Review:" "$LAST_OUT"
}
