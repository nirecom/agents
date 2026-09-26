# tests/bin/bin-codex-review-loop-security-code/exec-labels-stdout.sh
# Tests: bin/run-codex-review-loop, bin/review-code-codex
# Tags: concern-ledger, review-code, exec-label, stdout-contract, TL2, scope:common
# Sourced by tests/bin/bin-codex-review-loop-security-code.sh.
# The execution-label mapping, the verbatim-stdout contract, and the round the
# loop opens on its own now that no skill script opens one for it.

echo ""
echo "--- L: exec labels, verbatim stdout, loop-owned round ---"

LPATH="bin/run-codex-review-loop"
LANCHOR="resolve_round"
LCAT="correctness"
LTEXT="the loop must stage the delta for the round it opened itself"
LLINE="$(anchored HIGH - "$LPATH" "$LANCHOR" "$LCAT" "$LTEXT")"

lwork() { mktemp -d "$TMPDIR_BASE/lab-XXXXXX"; }

# ---------------------------------------------------------------------------
# L1. Execution label mapping. Every row also asserts the stdout marker that
#     drives the mapping, so a mis-built fixture cannot read as a mapping result.
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
        BASE-SUSPECT) RL_EXTRA=(--base-state SUSPECT) ;;
        *) fail "L1: unknown scenario token '$scenario' in row $name"; continue ;;
    esac
    run_loop
    assert_contains "L1: $name — the reviewer emitted the expected label" \
        "$want_marker" "$LAST_OUT"
    assert_eq "L1: $name — staged exec label" \
        "$want_exec" "$(staging_field "$(delta_file "$PLANS" "$SID" 1 review-code-codex)" 5)"
done <<'TABLE'
performed-only     | PERFORMED    | PERFORMED | ## Codex Review: PERFORMED
truncated-scope    | TRUNCATED    | PARTIAL   | ## Codex Review Scope: TRUNCATED
base-suspect-scope | BASE-SUSPECT | PARTIAL   | ## Codex Review Scope: BASE-SUSPECT
TABLE

# L2. The two statuses that end the round instead of labelling it. On the old
#     carrier they staged ABSENT; the loop owns the round now, so an execution
#     that produced no review must leave the round unconsumed instead.
while IFS='|' read -r name scenario want_marker; do
    name="$(trim "$name")"; scenario="$(trim "$scenario")"; want_marker="$(trim "$want_marker")"
    [ -z "$name" ] && continue
    LW=$(lwork)
    new_env
    mk_body "$LW/body.txt" "$LLINE"
    RL_CODEX_BODY="$LW/body.txt"
    case "$scenario" in
        SKIPPED) RL_PATH="$NO_CODEX_PATH"
                 printf '## Codex Review: SKIPPED — codex CLI unavailable\n' > "$LW/body.txt" ;;
        FAILED)  RL_CODEX_EXIT=3
                 printf '## Codex Review: FAILED — reviewer aborted\n' > "$LW/body.txt" ;;
    esac
    run_loop
    assert_contains "L2: $name — the reviewer says why it produced no review" \
        "$want_marker" "$LAST_OUT"
    assert_eq "L2: $name — the loop reports codex-unusable rather than a verdict" "3" "$LAST_RC"
    assert_eq "L2: $name — nothing is staged and the round is given back" \
        "delta=missing counter=missing" \
        "delta=$(file_state "$(delta_file "$PLANS" "$SID" 1 review-code-codex)") counter=$(file_state "$(round_file "$PLANS" "$SID")")"
done <<'TABLE2'
codex-skipped | SKIPPED | ## Codex Review: SKIPPED
codex-failed  | FAILED  | ## Codex Review: FAILED
TABLE2

# L3. completeness = min(exec, parse): a TRUNCATED scope demotes the round even
#     though the delta itself parsed cleanly.
{
    LW=$(lwork)
    new_env
    mk_body "$LW/body.txt" "$LLINE"
    RL_CODEX_BODY="$LW/body.txt"
    RL_REPO="$REPO_BIG"
    run_loop
    DF="$(delta_file "$PLANS" "$SID" 1 review-code-codex)"
    assert_eq "L3: a well-formed delta still parses COMPLETE" "COMPLETE" "$(staging_field "$DF" 6)"
    assert_eq "L3: completeness is the min of exec and parse" "PARTIAL" "$(staging_field "$DF" 3)"
    assert_eq "L3: the staging header records the producer name" \
        "review-code-codex" "$(staging_field "$DF" 2)"
    assert_eq "L3: the staging header records the round" "1" "$(staging_field "$DF" 7)"
}

# ---------------------------------------------------------------------------
# L4. The loop's stdout still carries the reviewer's own text. The loop adds a
#     verdict of its own, so the requirement is containment, not byte equality —
#     but nothing the reviewer said may be dropped on the way through.
# ---------------------------------------------------------------------------
{
    LW=$(lwork)
    new_env
    mk_body "$LW/body.txt" "$LLINE"
    RL_CODEX_BODY="$LW/body.txt"
    run_loop
    DIRECT_OUT="$(run_codex_direct)"

    assert_contains "L4: the comparison baseline is a real review" \
        "## Codex Review: PERFORMED" "$DIRECT_OUT"
    assert_contains_block "L4: every line the reviewer printed reaches the caller" \
        "$DIRECT_OUT" "$LAST_OUT"
    assert_contains "L4: including the concern it raised" "$LTEXT" "$LAST_OUT"
    NS_STATE=absent
    printf '%s' "$LAST_OUT" | grep -Fq -- "NOT-STAGED" && NS_STATE=printed
    OUT_STATE=empty
    [ -n "$(trim "$LAST_OUT")" ] && OUT_STATE=present
    assert_eq "L4: a resolvable session prints output and no NOT-STAGED notice" \
        "stdout=present notice=absent" "stdout=$OUT_STATE notice=$NS_STATE"
    assert_eq "L4: an unresolved HIGH at round 1 is a revision request, not an error" \
        "1" "$LAST_RC"
}

# ---------------------------------------------------------------------------
# L5. The round the loop opens. No open-concern-round.sh exists any more, so the
#     loop is the only thing that can decide the number both producers share.
# ---------------------------------------------------------------------------
{
    LW=$(lwork)
    new_env
    mk_body "$LW/body.txt" "$LLINE"
    RL_CODEX_BODY="$LW/body.txt"
    run_loop
    assert_eq "L5a: the ledger is persisted without any external round opener" \
        "present" "$(file_state "$(ledger_file "$PLANS" "$SID")")"
    assert_eq "L5a: the round-number file is created at 1" \
        "1" "$(trim "$(cat "$(round_file "$PLANS" "$SID")" 2>/dev/null || true)")"
    assert_eq "L5a: the delta is staged under round 1" \
        "present" "$(file_state "$(delta_file "$PLANS" "$SID" 1 review-code-codex)")"
    assert_match "L5a: the concern reached the ledger" \
        '^C[0-9]+$' "$(id_for_text "$(ledger_file "$PLANS" "$SID")" "$LTEXT")"
}

# (b) A counter left behind by a previous skill invocation is resumed, not reset.
{
    LW=$(lwork)
    new_env
    mk_body "$LW/body.txt" "$LLINE"
    RL_CODEX_BODY="$LW/body.txt"
    printf '1\n' > "$(round_file "$PLANS" "$SID")"
    run_loop
    assert_eq "L5b: a recorded round is resumed as the next one, and staged into" \
        "round=2 r2=present r3=missing" \
        "round=$(trim "$(cat "$(round_file "$PLANS" "$SID")" 2>/dev/null || true)") r2=$(file_state "$(delta_file "$PLANS" "$SID" 2 review-code-codex)") r3=$(file_state "$(delta_file "$PLANS" "$SID" 3 review-code-codex)")"
}

# (c) An explicit --round pins the round instead of reading the counter.
{
    LW=$(lwork)
    new_env
    mk_body "$LW/body.txt" "$LLINE"
    RL_CODEX_BODY="$LW/body.txt"
    run_loop --round 1
    assert_eq "L5c: an explicit --round is the round staged into" \
        "present" "$(file_state "$(delta_file "$PLANS" "$SID" 1 review-code-codex)")"
    assert_eq "L5c: and no neighbouring round is written" \
        "missing" "$(file_state "$(delta_file "$PLANS" "$SID" 2 review-code-codex)")"
}

# (d) An unwritable plans dir is announced, never silently skipped.
{
    LW=$(lwork)
    new_env
    mk_body "$LW/body.txt" "$LLINE"
    RL_CODEX_BODY="$LW/body.txt"
    : > "$LW/notadir"
    PLANS="$LW/notadir/sub"
    run_loop
    assert_eq "L5d: an unusable plans dir fails closed instead of reviewing silently" \
        "nonzero" "$(nonzero_word "$LAST_RC")"
    LD_SAID=no
    case "$LAST_OUT$LAST_ERR" in *plans*|*NOT-STAGED*|*ledger*) LD_SAID=yes ;; esac
    assert_eq "L5d: and says which resource it could not use" "yes" "$LD_SAID"
}
