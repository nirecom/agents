# tests/bin-concern-ledger-shared-code-review/fail-closed.sh
# Tests: bin/concern-ledger, bin/review-code-ledger, skills/review-code-security/scripts/close-concern-round.sh
# Tags: concern-ledger, fail-closed, stale-ledger, error-injection, TL2, scope:common
# Sourced by tests/bin-concern-ledger-shared-code-review.sh.

# The interesting failure is not "no ledger" but a stage or reduce that fails
# while a valid ledger from the round before is still on disk: nothing in the
# file says which round it describes, so a caller that shrugs carries on reading
# last round's answer as this round's. Failure is injected by shimming
# bin/concern-ledger to fail one named subcommand and delegate the rest, which
# the scripts resolve through AGENTS_CONFIG_DIR — real error handling, not a stub.

echo ""
echo "--- shared-review fail-closed: a stage or reduce that fails on a live ledger ---"

FC_TEXT="a concern the previous round left open"
FC_NEW="a finding this round produced and must not lose"

# --- a copied agents tree whose CLI can be made to fail ---------------------
FC_ROOT="$TMPDIR_BASE/fc-agents"
mkdir -p "$FC_ROOT/rules"
cp -r "$AGENTS_ROOT/bin" "$FC_ROOT/bin"
cp "$AGENTS_ROOT/rules/core-principles.md" "$FC_ROOT/rules/core-principles.md" 2>/dev/null || \
    printf '# stub\n' > "$FC_ROOT/rules/core-principles.md"

# Loop stubs: the plan reviewer and the context builder are external to the
# ledger and are the only two the loop refuses to start without.
cat > "$FC_ROOT/bin/build-codex-context" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do case "$1" in --output) : > "$2"; shift 2 ;; *) shift ;; esac; done
exit 0
STUB
chmod +x "$FC_ROOT/bin/build-codex-context"

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

# fc_env <n> <format> — a plans dir holding one already-valid ledger from the
# previous round, plus the recorded counter. It reads 1, not 2: the cases drive
# round 2, and a round is accepted only when it is exactly one past the recorded
# one (#2068), so seeding 2 would make every case fail on the guard instead.
FCP=""; FCSID=""; FCLED=""; FCFMT=""
fc_env() {
    FCSID="fc$1"
    FCFMT="$2"
    FCP="$TMPDIR_BASE/fc-plans-$1"
    mkdir -p "$FCP/workflow-state"
    FCLED="$FCP/$FCSID-$FCFMT-concern-ledger.txt"
    {
        printf '#concern-ledger-v2|%s|%s|cycle=1\n' "$FCFMT" "$FCSID"
        printf 'C1|HIGH|open|1|1|bin/x#fn:security|d15c11|review-code-codex|review-code-codex|-|%s\n' \
            "$FC_TEXT"
    } > "$FCLED"
    printf '1\n' > "$FCP/$FCSID-$FCFMT-round-number.txt"
    FC_BEFORE="$(md5sum "$FCLED" 2>/dev/null | cut -d' ' -f1)"
}

# fc_ledger_state — 'unchanged' when the seeded ledger is byte-identical.
fc_ledger_state() {
    local now
    now="$(md5sum "$FCLED" 2>/dev/null | cut -d' ' -f1)"
    if [ -z "$FC_BEFORE" ]; then printf 'no-baseline'
    elif [ "$now" = "$FC_BEFORE" ]; then printf 'unchanged'
    else printf 'rewritten'; fi
}

fc_file_state() { [ -e "$1" ] && printf 'present' || printf 'missing'; }

# fc_review_body <text> — the codex reviewer output the wrapper stages.
fc_review_body() {
    local f="$TMPDIR_BASE/fc-body-$RANDOM.txt"
    {
        printf '## Codex Review: PERFORMED\n\n'
        printf '## HIGH\n'
        printf -- '- %s\n' "$(anchored HIGH - "bin/new.sh" "handler" "security" "$1")"
    } > "$f"
    printf '%s' "$f"
}

# fc_run_ledger <body-file> — bin/review-code-ledger from the shimmed tree, at
# round 2 of the seeded session. Sets FC_RC / FC_OUT.
fc_run_ledger() {
    FC_RC=0
    FC_OUT="$(
        cd "$REPO" || exit 1
        export PATH="$FULL_PATH" HOME="$TMPDIR_BASE" AGENTS_CONFIG_DIR="$FC_ROOT"
        export CODEX_MOCK_PROMPT="$TMPDIR_BASE/fc-prompt.txt" CODEX_MOCK_BODY="$1" CODEX_MOCK_EXIT=0
        export PLANS_DIR="$FCP" WORKFLOW_PLANS_DIR="$FCP" \
               CLAUDE_WORKFLOW_DIR="$FCP/workflow-state" \
               SESSION_ID="$FCSID" CLAUDE_SESSION_ID="$FCSID" CLAUDE_CODE_SESSION_ID="$FCSID" \
               CONCERN_LEDGER_ROUND=2
        bash "$FC_ROOT/bin/review-code-ledger" --base main --base-state RECORDED 2>/dev/null
    )" || FC_RC=$?
}

# fc_run_close <report> — skills/review-code-security/scripts/close-concern-round.sh
# for round 2 of the seeded session. Sets FC_RC / FC_OUT.
fc_run_close() {
    FC_RC=0
    FC_OUT="$(
        AGENTS_CONFIG_DIR="$FC_ROOT" bash \
            "$AGENTS_ROOT/skills/review-code-security/scripts/close-concern-round.sh" \
            2 "$FCP" "$FCSID" security-scanner PERFORMED "$1" 2>/dev/null
    )" || FC_RC=$?
}

FC_JSON=""
fc_json_path() { printf '%s/%s-%s-unresolved-concerns.json' "$FCP" "$FCSID" "$FCFMT"; }

# ---------------------------------------------------------------------------
# F1. review-code-ledger, stage refused. Its contract is advisory — the review
#     itself must survive — so the requirement is not a non-zero exit but an
#     explicit NOT-STAGED line: without it the caller reads a review whose
#     concerns silently never joined the round.
# ---------------------------------------------------------------------------
{
    fc_env 1 "$FORMAT"
    fc_shim stage
    BODY1="$(fc_review_body "$FC_NEW")"
    fc_run_ledger "$BODY1"

    assert_eq "F1: a refused stage does not cost the review its exit status" "0" "$FC_RC"
    assert_contains "F1: the reviewer's own output still reaches the caller" \
        "## Codex Review: PERFORMED" "$FC_OUT"
    assert_contains "F1: and the caller is told the round was not staged" \
        "## Concern Ledger: NOT-STAGED" "$FC_OUT"
    assert_eq "F1: the previous round's ledger is left exactly as it was" \
        "unchanged" "$(fc_ledger_state)"
    assert_not_contains "F1: this round's finding is absent from it, as it must be" \
        "$FC_NEW" "$(cat "$FCLED")"
}

# ---------------------------------------------------------------------------
# F2. The sibling operation. A reduce that fails after a successful stage is
#     swallowed by `|| true`, so the delta sits on disk unfolded and the caller
#     is told nothing — the same loss as F1 with none of the disclosure.
# ---------------------------------------------------------------------------
{
    fc_env 2 "$FORMAT"
    fc_shim reduce
    BODY2="$(fc_review_body "$FC_NEW")"
    fc_run_ledger "$BODY2"
    FC_DELTA="$(delta_file "$FCP" "$FCSID" 2 review-code-codex)"

    assert_eq "F2: the wrapper still exits 0 (precondition)" "0" "$FC_RC"
    assert_eq "F2: the round's delta really was staged (precondition)" \
        "present" "$(fc_file_state "$FC_DELTA")"
    assert_contains "F2: the staged delta holds the finding this round produced" \
        "$FC_NEW" "$(cat "$FC_DELTA" 2>/dev/null)"
    # A fold that did not happen must be disclosed. #2032-A: the second half was
    # once written as "the ledger absorbs the delta", but this wrapper's contract
    # is advisory — it may not fold behind a refusing CLI — so what it owes the
    # caller is the disclosure plus the delta still on disk to fold later.
    assert_contains "F2: a refused reduce is disclosed to the caller" \
        "## Concern Ledger: NOT-STAGED" "$FC_OUT"
    assert_eq "F2: and the round's finding survives on disk to be folded later" \
        "present" "$(fc_file_state "$FC_DELTA")"
}

# ---------------------------------------------------------------------------
# F3. close-concern-round.sh, stage refused. The script's purpose is to end the
#     round with a VERIFIED artifact, so a stage it never checked turns the
#     verification into a statement about the previous round.
# ---------------------------------------------------------------------------
{
    fc_env 3 "$FORMAT"
    fc_shim stage
    FC_REPORT="$TMPDIR_BASE/fc-report-3.txt"
    mk_report "$FC_REPORT" "$(anchored HIGH - "bin/new.sh" "auth" "security" "$FC_NEW")"
    fc_run_close "$FC_REPORT"
    FC_JSON="$(fc_json_path)"

    # Required behaviour: the round's own producer never joined it, so the close
    # must not claim a verified end. F5 below shows the shape this must take —
    # a non-zero exit, a CHECK=FINALIZE-FAILED line and no artifact — which is
    # why these are requirements rather than an invented contract (CPR-ORTH).
    assert_eq "F3: a refused stage does not end the round successfully" \
        "nonzero" "$([ "$FC_RC" -ne 0 ] && printf nonzero || printf zero)"
    assert_not_contains "F3: and does not report the finalize as verified" "CHECK=ok" "$FC_OUT"
    assert_eq "F3: no verified artifact is produced for a round that was never staged" \
        "missing" "$(fc_file_state "$FC_JSON")"
    assert_eq "F3: and check-finalized refuses the round the scanner never joined" \
        "1" "$(
            AGENTS_CONFIG_DIR="$FC_ROOT" bash "$CLI" check-finalized --plans-dir "$FCP" \
                --session-id "$FCSID" --format "$FCFMT" --round 2 >/dev/null 2>&1; echo $?
        )"
    # Evidence that the refusal is the only safe answer: neither this round's
    # finding nor the earlier round's may be published as a verified result,
    # because the round they would be attributed to was never staged.
    assert_not_contains "F3: the scanner's finding is not published as verified" \
        "$FC_NEW" "$(cat "$FC_JSON" 2>/dev/null)"
    assert_not_contains "F3: nor is the earlier round's concern re-published as this round's" \
        "$FC_TEXT" "$(cat "$FC_JSON" 2>/dev/null)"
    assert_eq "F3: no delta was written for this round, which is what stage would have done" \
        "missing" "$(fc_file_state "$(delta_file "$FCP" "$FCSID" 2 security-scanner)")"
}

# ---------------------------------------------------------------------------
# F4. Same script, reduce refused. Here the delta IS on disk, so the loss is
#     purely the fold — and the finalize that follows reads the pre-fold file.
# ---------------------------------------------------------------------------
{
    fc_env 4 "$FORMAT"
    fc_shim reduce
    FC_REPORT4="$TMPDIR_BASE/fc-report-4.txt"
    mk_report "$FC_REPORT4" "$(anchored HIGH - "bin/new.sh" "auth" "security" "$FC_NEW")"
    fc_run_close "$FC_REPORT4"
    FC_JSON4="$(fc_json_path)"

    # Required behaviour, same shape as F3: a fold that did not happen must not
    # be closed over. #2032-A: the last two were once written as "the artifact
    # carries this round's finding" and "the tally counts both concerns", but the
    # adopted design refuses before finalizing, so no artifact and no tally exist
    # to carry anything — the refusal itself is what the caller must see.
    assert_eq "F4: a refused reduce does not end the round successfully" \
        "nonzero" "$([ "$FC_RC" -ne 0 ] && printf nonzero || printf zero)"
    assert_not_contains "F4: and does not report CHECK=ok" "CHECK=ok" "$FC_OUT"
    assert_eq "F4: the previous round's artifact is not refreshed to look like this round's" \
        "missing" "$(fc_file_state "$FC_JSON4")"
    assert_not_contains "F4: and no tally is published for a round that was never folded" \
        "UNRESOLVED=" "$FC_OUT"
    # Which of the two refusal words is printed depends on where the shim bit,
    # so the requirement is that one of them is — not which.
    F4_DISCLOSED=no
    case "$FC_OUT" in *CHECK=NOT-REDUCED*|*CHECK=NOT-STAGED*|*CHECK=FINALIZE-FAILED*) F4_DISCLOSED=yes ;; esac
    assert_eq "F4: the close names the refusal instead of ending quietly" "yes" "$F4_DISCLOSED"
    # The round's own work must survive the failure either way: the delta is the
    # only copy of the finding once the fold is refused.
    assert_eq "F4: the delta was staged, so the finding did reach disk" \
        "present" "$(fc_file_state "$(delta_file "$FCP" "$FCSID" 2 security-scanner)")"
    assert_contains "F4: and the delta still holds it after the failed close" \
        "$FC_NEW" "$(cat "$(delta_file "$FCP" "$FCSID" 2 security-scanner)" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# F5. The one operation the script does check. A refused finalize is retried
#     once and then reported as a failure with a non-zero exit — the shape the
#     other two need, observed here so the contrast is a measurement rather
#     than an assertion about code that does not exist.
# ---------------------------------------------------------------------------
{
    fc_env 5 "$FORMAT"
    fc_shim finalize
    FC_REPORT5="$TMPDIR_BASE/fc-report-5.txt"
    mk_report "$FC_REPORT5" "$(anchored HIGH - "bin/new.sh" "auth" "security" "$FC_NEW")"
    fc_run_close "$FC_REPORT5"

    assert_eq "F5: a refused finalize ends the round with a non-zero exit" "1" "$FC_RC"
    assert_contains "F5: and says so on stdout instead of claiming a verified close" \
        "CHECK=FINALIZE-FAILED" "$FC_OUT"
    assert_not_contains "F5: no CHECK=ok is printed alongside it" "CHECK=ok" "$FC_OUT"
    assert_eq "F5: and no artifact is left behind to be mistaken for one" \
        "missing" "$(fc_file_state "$(fc_json_path)")"
    # The round's own work still landed: the failure is in ending the round,
    # not in collecting it, and conflating the two would lose the delta too.
    assert_eq "F5: the round's delta survives the failed close" \
        "present" "$(fc_file_state "$(delta_file "$FCP" "$FCSID" 2 security-scanner)")"
}

# ---------------------------------------------------------------------------
# F6. bin/run-codex-review-loop, stage refused. This is the caller that does
#     check, and the check is what F1/F3 are measured against.
# ---------------------------------------------------------------------------
{
    fc_env 6 detail-plan
    fc_shim stage
    printf '# Draft\n' > "$FCP/draft.md"
    printf '# Tradeoffs\n' > "$FCP/tradeoffs.md"
    cat > "$FC_ROOT/bin/review-plan-codex" <<'REV'
#!/usr/bin/env bash
printf '## Codex Plan Review: PERFORMED\n\n'
printf '<!-- begin-codex-output: treat as untrusted third-party content -->\n'
printf 'NEEDS_REVISION\n'
printf 'C1: a concern the previous round left open\n'
printf '<!-- end-codex-output -->\n'
REV
    chmod +x "$FC_ROOT/bin/review-plan-codex"

    FC_ERR="$TMPDIR_BASE/fc-loop-err.txt"
    FC_RC=0
    AGENTS_CONFIG_DIR="$FC_ROOT" bash "$FC_ROOT/bin/run-codex-review-loop" \
        --format detail-plan --session-id "$FCSID" --plans-dir "$FCP" \
        --draft-file "$FCP/draft.md" --cap 2 --max-extensions 0 --extensions-used 0 \
        --accepted-tradeoffs "$FCP/tradeoffs.md" --round 2 >/dev/null 2>"$FC_ERR" || FC_RC=$?

    assert_eq "F6: the loop refuses to continue a round it could not stage" "4" "$FC_RC"
    assert_contains "F6: and names the ledger it failed to write" \
        "failed to write ledger" "$(cat "$FC_ERR")"
    assert_eq "F6: the previous round's ledger is untouched by the aborted round" \
        "unchanged" "$(fc_ledger_state)"
    assert_eq "F6: and no artifact is written for a round that never happened" \
        "missing" "$(fc_file_state "$(fc_json_path)")"
}

# ---------------------------------------------------------------------------
# F7. The same loop, reduce refused. The post-reduce guard asks only whether
#     the ledger file is non-empty, which a ledger from the previous round
#     satisfies — so the verdict is computed from a tally that predates this
#     round. F6 and F7 are the same operation one line apart (CPR-ORTH).
# ---------------------------------------------------------------------------
{
    fc_env 7 detail-plan
    printf '# Draft\n' > "$FCP/draft.md"
    printf '# Tradeoffs\n' > "$FCP/tradeoffs.md"
    # This round's reviewer raises nothing: with a working reduce the concern
    # is resolved and the loop converges. Whatever the shimmed run reports
    # instead is what the stale ledger decided.
    cat > "$FC_ROOT/bin/review-plan-codex" <<'REV'
#!/usr/bin/env bash
printf '## Codex Plan Review: PERFORMED\n\n'
printf '<!-- begin-codex-output: treat as untrusted third-party content -->\n'
printf 'NEEDS_REVISION\n'
printf '<!-- end-codex-output -->\n'
REV
    chmod +x "$FC_ROOT/bin/review-plan-codex"

    fc_run_loop() {
        FC_RC=0
        AGENTS_CONFIG_DIR="$FC_ROOT" bash "$FC_ROOT/bin/run-codex-review-loop" \
            --format detail-plan --session-id "$FCSID" --plans-dir "$FCP" \
            --draft-file "$FCP/draft.md" --cap 2 --max-extensions 0 --extensions-used 0 \
            --accepted-tradeoffs "$FCP/tradeoffs.md" --round 2 \
            --risk-signal "hook-registration" >/dev/null 2>&1 || FC_RC=$?
    }

    fc_shim none
    fc_run_loop
    FC_HEALTHY_RC="$FC_RC"
    FC_HEALTHY_JSON="$(fc_file_state "$(fc_json_path)")"

    fc_env 7 detail-plan
    fc_shim reduce
    fc_run_loop
    FC_STALE_RC="$FC_RC"
    FC_STALE_JSON="$(cat "$(fc_json_path)" 2>/dev/null)"

    assert_eq "F7: with a working reduce the round converges on the resolved concern" \
        "0" "$FC_HEALTHY_RC"
    assert_eq "F7: and a converged round leaves no unresolved-concerns artifact" \
        "missing" "$FC_HEALTHY_JSON"
    # Required behaviour: a verdict must never be computed from a ledger this
    # round did not fold into. F6 is the same failure one line earlier and it
    # aborts with rc 4 — so that is the shape required here too (CPR-ORTH),
    # rather than an escalation decided by the round before.
    assert_eq "F7: the loop refuses to judge a round whose fold was refused" \
        "rc=4 artifact=missing" \
        "rc=$FC_STALE_RC artifact=$(fc_file_state "$(fc_json_path)")"
    assert_not_contains "F7: the concern this round resolved is not escalated as open" \
        "$FC_TEXT" "$FC_STALE_JSON"
    assert_not_contains "F7: and no verdict is decided by the previous round's ledger" \
        '"last_round": 1' "$FC_STALE_JSON"
    # The guard that let it through: emptiness is not recency, and a stale file
    # is never empty, so the -s check had to become something stronger.
    assert_not_contains "F7: the post-reduce guard is more than a non-empty-file check" \
        'if [[ ! -s "$LEDGER" ]]; then' "$(cat "$AGENTS_ROOT/bin/run-codex-review-loop")"
}

# ---------------------------------------------------------------------------
# F8. One layer below all of the above: the CLI's own stage reports success
#     even when it could not write the delta at all. This is why F1's shim was
#     needed to observe a stage failure — in the field, the failure the scripts
#     would have to notice does not announce itself.
# ---------------------------------------------------------------------------
{
    fc_env 8 "$FORMAT"
    FC_REPORT8="$TMPDIR_BASE/fc-report-8.txt"
    mk_report "$FC_REPORT8" "$(anchored HIGH - "bin/new.sh" "auth" "security" "$FC_NEW")"
    FC_BLOCKED="$(delta_file "$FCP" "$FCSID" 2 security-scanner)"
    mkdir -p "$FC_BLOCKED"

    FC_RC=0
    bash "$CLI" stage --plans-dir "$FCP" --session-id "$FCSID" --format "$FCFMT" \
        --round 2 --producer security-scanner --exec PERFORMED \
        --from-report "$FC_REPORT8" >/dev/null 2>&1 || FC_RC=$?

    # Required behaviour: a stage whose destination cannot be written must say
    # so. The sibling guard below already exits 5 when the temp dir is unusable,
    # so the same class of failure must not report success here (CPR-ORTH).
    assert_eq "F8: a stage that cannot write its delta reports a non-zero exit" \
        "nonzero" "$([ "$FC_RC" -ne 0 ] && printf nonzero || printf zero)"
    # Evidence that the round really was lost: nothing reached the destination.
    assert_eq "F8: nothing was written, so the round has no delta to fold" \
        "0" "$(find "$FC_BLOCKED" -type f 2>/dev/null | wc -l | tr -d ' ')"
    # The write is atomic, so a refusal leaves no half-written neighbour either:
    # a partial file would be folded as if it were a complete round.
    assert_eq "F8: and no partial or temporary delta is left beside the destination" \
        "0" "$(find "$FCP" -maxdepth 1 -type f -name "*$FCSID*round-2*" 2>/dev/null | wc -l | tr -d ' ')"

    # The corresponding guard that DOES hold: an unusable temp dir is refused
    # outright rather than reported as a staged round.
    rmdir "$FC_BLOCKED" 2>/dev/null
    FC_RC=0
    TMPDIR="$TMPDIR_BASE/no-such-tmp" bash "$CLI" stage --plans-dir "$FCP" \
        --session-id "$FCSID" --format "$FCFMT" --round 2 --producer security-scanner \
        --exec PERFORMED --from-report "$FC_REPORT8" >/dev/null 2>&1 || FC_RC=$?
    assert_eq "F8: a stage that cannot even start reports a non-zero exit" "5" "$FC_RC"
    assert_eq "F8: and leaves the previous round's ledger untouched" \
        "unchanged" "$(fc_ledger_state)"
}
