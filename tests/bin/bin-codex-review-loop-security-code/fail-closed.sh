# tests/bin-codex-review-loop-security-code/fail-closed.sh
# Tests: bin/run-codex-review-loop, bin/concern-ledger, bin/lib/concern-ledger.sh
# Tags: concern-ledger, fail-closed, stale-ledger, error-injection, TL2, scope:common
# Sourced by tests/bin-codex-review-loop-security-code.sh.
#
# The interesting failure is not "no ledger" but a stage or reduce that fails
# while a valid ledger from the round before is still on disk: nothing in the
# file says which round it describes. Failure is injected by shimming
# bin/concern-ledger inside a copied agents tree the loop resolves through
# AGENTS_CONFIG_DIR — real error handling, not a stub.

echo ""
echo "--- F: a stage, reduce or finalize that fails on a live ledger ---"

FC_TEXT="a concern the previous round left open"
FC_NEW="a finding this round produced and must not lose"

# --- a copied agents tree whose CLI can be made to fail ---------------------
FC_ROOT="$TMPDIR_BASE/fc-agents"
mkdir -p "$FC_ROOT/rules"
cp -r "$AGENTS_ROOT/bin" "$FC_ROOT/bin"
# bin/resolve-session-id resolves its bridge module at "$SELF_DIR/../hooks/...",
# so a copied tree that omits hooks/ makes every real resolution fail with rc 3 —
# indistinguishable here from the failures these cases inject.
cp -r "$AGENTS_ROOT/hooks" "$FC_ROOT/hooks"
cp "$AGENTS_ROOT/rules/core-principles.md" "$FC_ROOT/rules/core-principles.md" 2>/dev/null || \
    printf '# stub\n' > "$FC_ROOT/rules/core-principles.md"

# fc_shim <subcommand|none> — install a CLI that fails exactly one subcommand.
fc_shim() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'if [ "${1:-}" = "%s" ]; then\n' "$1"
        printf '  echo "concern-ledger: injected failure on %s" >&2\n' "$1"
        printf '  exit 5\n'
        printf 'fi\n'
        printf 'exec bash "%s" "$@"\n' "$CLI"
    } > "$FC_ROOT/bin/concern-ledger"
    chmod +x "$FC_ROOT/bin/concern-ledger"
}

# fc_env <n> — a plans dir holding one already-valid ledger from the previous
# round plus the recorded counter. The counter reads 1, not 2: a round is
# accepted only when it is exactly one past the recorded one, so the cases below
# drive round 2. Rebinds PLANS/SID so the parent's run_loop targets this fixture.
FCLED=""; FC_BEFORE=""
fc_env() {
    SID="fc$1"
    PLANS="$TMPDIR_BASE/fc-plans-$1"
    rm -rf "$PLANS"
    mkdir -p "$PLANS/workflow-state"
    printf 'none\n' > "$PLANS/tradeoffs.md"
    FCLED="$(ledger_file "$PLANS" "$SID")"
    {
        printf '#concern-ledger-v2|%s|%s|cycle=1\n' "$LEDGER_FORMAT" "$SID"
        printf 'C1|HIGH|open|1|1|bin/x#fn:security|d15c11|review-code-codex|review-code-codex|-|%s\n' \
            "$FC_TEXT"
    } > "$FCLED"
    printf '1\n' > "$(round_file "$PLANS" "$SID")"
    FC_BEFORE="$(digest "$FCLED")"
    RL_REPO="$REPO"
    RL_PATH="$FULL_PATH"
    RL_ROOT="$FC_ROOT"
    RL_CODEX_BODY="$NONE_BODY"
    RL_CODEX_EXIT=0
    RL_EXT_USED=0
    RL_CAP=4
    RL_MAXEXT=0
    RL_EXTRA=()
}

fc_ledger_state() {
    local now
    now="$(digest "$FCLED")"
    if [ -z "$FC_BEFORE" ]; then printf 'no-baseline'
    elif [ "$now" = "$FC_BEFORE" ]; then printf 'unchanged'
    else printf 'rewritten'; fi
}
fc_body() {
    local f="$TMPDIR_BASE/fc-body-$1.txt"
    mk_body "$f" "$(anchored HIGH - "bin/new.sh" "handler" "security" "$FC_NEW")"
    printf '%s' "$f"
}
fc_report() {
    local f="$TMPDIR_BASE/fc-report-$1.txt"
    mk_report "$f" "$(anchored HIGH - "bin/new.sh" "auth" "security" "$FC_NEW")"
    printf '%s' "$f"
}
fc_scan_run() {
    RL_EXTRA=(--prestaged-report "$1" --prestaged-producer security-scanner
              --prestaged-exec PERFORMED)
    run_loop --round 2
    RL_EXTRA=()
}
fc_check2() {
    AGENTS_CONFIG_DIR="$FC_ROOT" bash "$CLI" check-finalized --plans-dir "$PLANS" \
        --session-id "$SID" --format "$LEDGER_FORMAT" --round 2 >/dev/null 2>&1
    printf '%s' "$?"
}

# ---------------------------------------------------------------------------
# F1. The reviewer half with stage refused. The loop is the caller that checks:
#     a round it could not stage may not be judged.
# ---------------------------------------------------------------------------
{
    fc_env 1
    fc_shim stage
    RL_CODEX_BODY="$(fc_body 1)"
    run_loop --round 2

    assert_eq "F1: the loop refuses to continue a round it could not stage" "4" "$LAST_RC"
    assert_contains "F1: and names the ledger it failed to write" \
        "ledger" "$LAST_ERR$LAST_OUT"
    assert_eq "F1: the previous round's ledger is left exactly as it was" \
        "unchanged" "$(fc_ledger_state)"
    assert_not_contains "F1: this round's finding is absent from it, as it must be" \
        "$FC_NEW" "$(cat "$FCLED" 2>/dev/null || true)"
    assert_eq "F1: and no artifact is written for a round that never happened" \
        "missing" "$(file_state "$(json_file "$PLANS" "$SID")")"
    assert_eq "F1: the round counter is not advanced past a round that failed" \
        "1" "$(trim "$(cat "$(round_file "$PLANS" "$SID")" 2>/dev/null || true)")"
}

# ---------------------------------------------------------------------------
# F2. The sibling operation, one line later: a reduce that fails after a
#     successful stage. The delta sits on disk unfolded (CPR-ORTH with F1).
# ---------------------------------------------------------------------------
{
    fc_env 2
    fc_shim reduce
    RL_CODEX_BODY="$(fc_body 2)"
    run_loop --round 2
    FC_DELTA="$(delta_file "$PLANS" "$SID" 2 review-code-codex)"

    assert_eq "F2: the round's delta really was staged (precondition)" \
        "present" "$(file_state "$FC_DELTA")"
    assert_contains "F2: the staged delta holds the finding this round produced" \
        "$FC_NEW" "$(cat "$FC_DELTA" 2>/dev/null || true)"
    assert_eq "F2: the loop refuses to judge a round whose fold was refused" "4" "$LAST_RC"
    assert_eq "F2: the previous round's ledger is not passed off as this round's" \
        "unchanged" "$(fc_ledger_state)"
    assert_eq "F2: and no artifact is produced from the unfolded round" \
        "missing" "$(file_state "$(json_file "$PLANS" "$SID")")"
    assert_eq "F2: the round's finding survives on disk to be folded later" \
        "present" "$(file_state "$FC_DELTA")"
}

# ---------------------------------------------------------------------------
# F3. The prestaged scanner half with stage refused. Its purpose is to end the
#     round with a verified artifact, so a stage it never checked would turn the
#     verification into a statement about the previous round.
# ---------------------------------------------------------------------------
{
    fc_env 3
    fc_shim stage
    fc_scan_run "$(fc_report 3)"
    FC_JSON="$(json_file "$PLANS" "$SID")"

    assert_eq "F3: a refused stage does not end the round successfully" \
        "nonzero" "$(nonzero_word "$LAST_RC")"
    assert_eq "F3: no verified artifact is produced for a round that was never staged" \
        "missing" "$(file_state "$FC_JSON")"
    assert_eq "F3: and check-finalized refuses the round the scanner never joined" \
        "1" "$(fc_check2)"
    assert_not_contains "F3: the scanner's finding is not published as verified" \
        "$FC_NEW" "$(cat "$FC_JSON" 2>/dev/null || true)"
    assert_not_contains "F3: nor is the earlier round's concern re-published as this round's" \
        "$FC_TEXT" "$(cat "$FC_JSON" 2>/dev/null || true)"
    assert_eq "F3: no delta was written for this round, which is what stage would have done" \
        "missing" "$(file_state "$(delta_file "$PLANS" "$SID" 2 security-scanner)")"
    assert_eq "F3: the seeded ledger is untouched" "unchanged" "$(fc_ledger_state)"
}

# ---------------------------------------------------------------------------
# F4. Same entry point, reduce refused. Here the delta IS on disk, so the loss
#     is purely the fold — and a finalize that followed would read the pre-fold
#     file.
# ---------------------------------------------------------------------------
{
    fc_env 4
    fc_shim reduce
    fc_scan_run "$(fc_report 4)"
    FC_JSON4="$(json_file "$PLANS" "$SID")"
    FC_SDELTA="$(delta_file "$PLANS" "$SID" 2 security-scanner)"

    assert_eq "F4: a refused reduce does not end the round successfully" \
        "nonzero" "$(nonzero_word "$LAST_RC")"
    assert_eq "F4: the previous round's artifact is not refreshed to look like this round's" \
        "missing" "$(file_state "$FC_JSON4")"
    assert_not_contains "F4: and no tally is published for a round that was never folded" \
        "UNRESOLVED=" "$LAST_OUT"
    FC_SAID=no
    case "$LAST_OUT$LAST_ERR" in *reduce*|*ledger*|*NOT-STAGED*) FC_SAID=yes ;; esac
    assert_eq "F4: the loop names the refusal instead of ending quietly" "yes" "$FC_SAID"
    assert_eq "F4: the delta was staged, so the finding did reach disk" \
        "present" "$(file_state "$FC_SDELTA")"
    assert_contains "F4: and the delta still holds it after the failed round" \
        "$FC_NEW" "$(cat "$FC_SDELTA" 2>/dev/null || true)"
    assert_eq "F4: check-finalized still refuses the unfolded round" "1" "$(fc_check2)"
}

# ---------------------------------------------------------------------------
# F5. The finalize itself refused. This is the operation the chain does check,
#     and the dedicated exit code is what makes the refusal legible.
# ---------------------------------------------------------------------------
{
    fc_env 5
    fc_shim none
    RL_CODEX_BODY="$(fc_body 5)"
    run_loop --round 2
    assert_eq "F5: with a working CLI the round is staged (precondition)" \
        "present" "$(file_state "$(delta_file "$PLANS" "$SID" 2 review-code-codex)")"

    fc_shim finalize
    fc_scan_run "$(fc_report 5)"

    assert_eq "F5: a refused finalize ends the round with the dedicated exit 7" "7" "$LAST_RC"
    assert_eq "F5: and no artifact is left behind to be mistaken for one" \
        "missing" "$(file_state "$(json_file "$PLANS" "$SID")")"
    FC_F5=no
    case "$LAST_OUT$LAST_ERR" in *finalize*|*FINALIZE*) FC_F5=yes ;; esac
    assert_eq "F5: the failure is named rather than implied by the exit code alone" "yes" "$FC_F5"
    assert_eq "F5: the round's delta survives the failed finalize" \
        "present" "$(file_state "$(delta_file "$PLANS" "$SID" 2 security-scanner)")"
    assert_eq "F5: and check-finalized refuses the round that was never finalized" \
        "1" "$(fc_check2)"
}

if [ -f "$SUITE_DIR/fail-closed-cli-and-resolver.sh" ]; then
    # shellcheck source=/dev/null
    . "$SUITE_DIR/fail-closed-cli-and-resolver.sh"
else
    fail "case file missing: bin-codex-review-loop-security-code/fail-closed-cli-and-resolver.sh"
fi
