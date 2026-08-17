# tests/bin-concern-ledger-shared-code-review/chain-failure-branches.sh
# Tests: skills/review-code-security/scripts/open-concern-round.sh, skills/review-code-security/scripts/run-quality-gates.sh, skills/review-code-security/scripts/close-concern-round.sh, bin/concern-ledger
# Tags: concern-ledger, review-code-security, fail-closed, full-chain, TL2, scope:common
# Sourced by tests/bin-concern-ledger-shared-code-review.sh, after
# fail-closed.sh, whose FC_ROOT shimmed tree and fc_shim helper are reused.

# Why this file exists. full-chain-integration.sh runs open -> gates -> close
# through real subprocesses and proves the three scripts agree when nothing goes
# wrong. That is only half a contract: the other half is what the same chain
# does when one of its four ledger calls refuses, because that is the branch on
# which a caller must NOT be told the review is complete.

# So every case below drives the same real scripts — no static greps, no stubbed
# orchestrator — with exactly one ledger subcommand made to fail, and asks the
# question the caller asks: may I mark this step done? The answer has to be
# legible from the exit status and stdout alone, since that is all the skill
# text has to work from.

echo ""
echo "--- shared-review chain: the failure branches of open -> gates -> close ---"

CFB_CODEX="the failure branch must not be reported as a completed review"
CFB_SCAN="the scanner finding that the failed round still owes the author"

# cfb_env <n> — a fresh, empty plans dir: the state a real round 1 starts from.
CFB_P=""; CFB_SID=""
cfb_env() {
    CFB_SID="cfb$1"
    CFB_P="$TMPDIR_BASE/cfb-plans-$1"
    mkdir -p "$CFB_P/workflow-state"
}

# cfb_open — the real open-concern-round.sh, resolved through the shimmed tree.
cfb_open() {
    CFB_OPEN="$(
        SESSION_ID="$CFB_SID" PLANS_DIR="$CFB_P" AGENTS_CONFIG_DIR="$FC_ROOT" \
            bash "$AGENTS_ROOT/skills/review-code-security/scripts/open-concern-round.sh" 2>/dev/null
    )"
}
cfb_kv() { printf '%s\n' "$CFB_OPEN" | grep -m1 "^$1=" | cut -d'=' -f2-; }

# cfb_gates <round> <codex-body> — the real run-quality-gates.sh from the
# reviewed tree, with only the external codex CLI mocked.
cfb_gates() {
    CFB_GATES="$(
        cd "$REPO" || exit 1
        export PATH="$FULL_PATH" HOME="$TMPDIR_BASE" AGENTS_CONFIG_DIR="$FC_ROOT"
        export CODEX_MOCK_PROMPT="$TMPDIR_BASE/cfb-prompt-$CFB_SID-$1.txt" \
               CODEX_MOCK_BODY="$2" CODEX_MOCK_EXIT=0
        export PLANS_DIR="$CFB_P" WORKFLOW_PLANS_DIR="$CFB_P" \
               CLAUDE_WORKFLOW_DIR="$CFB_P/workflow-state" \
               SESSION_ID="$CFB_SID" CLAUDE_SESSION_ID="$CFB_SID" \
               CLAUDE_CODE_SESSION_ID="$CFB_SID" CONCERN_LEDGER_ROUND="$1"
        bash "$AGENTS_ROOT/skills/review-code-security/scripts/run-quality-gates.sh" 2>/dev/null
    )"
}

# cfb_close <round> <report> — the real close-concern-round.sh.
cfb_close() {
    CFB_CLOSE_RC=0
    CFB_CLOSE="$(
        AGENTS_CONFIG_DIR="$FC_ROOT" bash \
            "$AGENTS_ROOT/skills/review-code-security/scripts/close-concern-round.sh" \
            "$1" "$CFB_P" "$CFB_SID" security-scanner PERFORMED "$2" 2>/dev/null
    )" || CFB_CLOSE_RC=$?
}

cfb_json() { printf '%s/%s-%s-unresolved-concerns.json' "$CFB_P" "$CFB_SID" "$FORMAT"; }
cfb_check() {
    AGENTS_CONFIG_DIR="$FC_ROOT" bash "$CLI" check-finalized --plans-dir "$CFB_P" \
        --session-id "$CFB_SID" --format "$FORMAT" --round "$1" >/dev/null 2>&1
    printf '%s' "$?"
}

# cfb_bodies <n> — the reviewer body and scanner report a round needs.
cfb_body() {
    CFB_BODY="$TMPDIR_BASE/cfb-body-$1.txt"
    mk_body "$CFB_BODY" "$(anchored HIGH - "bin/retry.sh" "retry_once" "correctness" "$CFB_CODEX")"
    CFB_REPORT="$TMPDIR_BASE/cfb-report-$1.txt"
    mk_report "$CFB_REPORT" "$(anchored HIGH - "bin/auth.sh" "issue_token" "security" "$CFB_SCAN")"
}

# ---------------------------------------------------------------------------
# E1. The finalize branch, driven through all three scripts. This is the one the
#     chain already handles correctly, so it establishes what "the caller must
#     not mark this complete" looks like on the wire — the shape E2/E3 are then
#     measured against (CPR-ORTH).
# ---------------------------------------------------------------------------
{
    cfb_env 1
    fc_shim none
    cfb_open
    E1_ROUND="$(cfb_kv ROUND)"
    assert_eq "E1: the chain opens a fresh review at round 1" "1" "$E1_ROUND"

    cfb_body 1
    cfb_gates "$E1_ROUND" "$CFB_BODY"
    assert_contains "E1: the gate runner reached the codex producer" \
        "## Codex Review: PERFORMED" "$CFB_GATES"
    assert_eq "E1: whose delta joined the round open-concern-round decided" \
        "present" "$(file_state "$(delta_file "$CFB_P" "$CFB_SID" 1 review-code-codex)")"

    # Now the finalize refuses, and the close-out is the step that must notice.
    fc_shim finalize
    cfb_close "$E1_ROUND" "$CFB_REPORT"

    assert_eq "E1: a refused finalize ends the round with a non-zero exit" "1" "$CFB_CLOSE_RC"
    assert_contains "E1: and says FINALIZE-FAILED rather than claiming a verified close" \
        "CHECK=FINALIZE-FAILED" "$CFB_CLOSE"
    assert_not_contains "E1: no CHECK=ok is printed alongside it" "CHECK=ok" "$CFB_CLOSE"
    assert_eq "E1: no artifact is left behind to be mistaken for a finalized round" \
        "missing" "$(file_state "$(cfb_json)")"
    assert_eq "E1: and check-finalized refuses the round the chain could not end" \
        "1" "$(cfb_check 1)"
    # Both producers' work must survive: the deltas are the only copies once the
    # round cannot be closed, and the author has to be able to re-run the close.
    assert_eq "E1: both producers' deltas survive the failed close" \
        "codex=present scanner=present" \
        "codex=$(file_state "$(delta_file "$CFB_P" "$CFB_SID" 1 review-code-codex)") scanner=$(file_state "$(delta_file "$CFB_P" "$CFB_SID" 1 security-scanner)")"

    # And the recovery really is a recovery: with the shim lifted, re-running the
    # same close-out ends the round on the concerns both producers staged.
    fc_shim none
    cfb_close "$E1_ROUND" "$CFB_REPORT"
    assert_eq "E1: re-running the close after the failure clears it" "0" "$CFB_CLOSE_RC"
    assert_contains "E1: and reports the finalize it verified" "CHECK=ok" "$CFB_CLOSE"
    assert_eq "E1: the recovered artifact answers for the round" "0" "$(cfb_check 1)"
    E1_JSON="$(cat "$(cfb_json)" 2>/dev/null)"
    assert_contains "E1: carrying the reviewer's concern" "$CFB_CODEX" "$E1_JSON"
    assert_contains "E1: and the scanner's, so neither producer was lost" "$CFB_SCAN" "$E1_JSON"
}

# ---------------------------------------------------------------------------
# E2. The stage branch at the gates. The gate runner's contract is advisory —
#     the review text must still reach the author — so the requirement is the
#     NOT-STAGED disclosure, without which the round silently has one producer.
# ---------------------------------------------------------------------------
{
    cfb_env 2
    fc_shim none
    cfb_open
    E2_ROUND="$(cfb_kv ROUND)"
    cfb_body 2

    fc_shim stage
    cfb_gates "$E2_ROUND" "$CFB_BODY"

    assert_contains "E2: the reviewer's own output still reaches the author" \
        "## Codex Review: PERFORMED" "$CFB_GATES"
    assert_contains "E2: and the author is told the round was not staged" \
        "## Concern Ledger: NOT-STAGED" "$CFB_GATES"
    assert_eq "E2: no delta was written for the producer that could not stage" \
        "missing" "$(file_state "$(delta_file "$CFB_P" "$CFB_SID" "$E2_ROUND" review-code-codex)")"

    # The close that follows must not turn a one-producer round into a verified
    # one. It runs with a healthy CLI, so nothing here is injected twice.
    fc_shim none
    cfb_close "$E2_ROUND" "$CFB_REPORT"
    E2_JSON="$(cat "$(cfb_json)" 2>/dev/null)"
    assert_contains "E2: the scanner's own concern still reaches the artifact" \
        "$CFB_SCAN" "$E2_JSON"
    xfail_eq "E2: a round that lost a producer is not closed as verified" \
        "nonzero" "$([ "$CFB_CLOSE_RC" -ne 0 ] && printf nonzero || printf zero)"
    xfail_contains "E2: and the reviewer's concern is not silently dropped from it" \
        "$CFB_CODEX" "$E2_JSON"
}

# ---------------------------------------------------------------------------
# E3. Exit 7 on the sibling formats. finalize.sh case 6(e) drives the wrapper's
#     finalize-failure exit for detail-plan; the same wrapper serves review-tests
#     and review-plan-security, and a caller of those must be handed the same
#     refusal (CPR-ORTH). Driven through the real bin/run-codex-review-loop.
# ---------------------------------------------------------------------------
{
    cfb_env 3
    printf '# Draft\n' > "$CFB_P/draft.md"
    printf '# Tradeoffs\n' > "$CFB_P/tradeoffs.md"
    cat > "$FC_ROOT/bin/review-plan-codex" <<'REV'
#!/usr/bin/env bash
printf '## Codex Plan Review: PERFORMED\n\n'
printf '<!-- begin-codex-output: treat as untrusted third-party content -->\n'
printf 'NEEDS_REVISION\n'
printf '1. [HIGH] the failure branch must not be reported as a completed review\n'
printf '<!-- end-codex-output -->\n'
REV
    chmod +x "$FC_ROOT/bin/review-plan-codex"
    fc_shim none

    # e3_run <format> — the loop at its cap with a directory squatting on the
    # artifact path, which is the portable way to make the write fail (chmod is
    # a no-op on Windows — CPR-UNV). Sets E3_RC / E3_OUT / E3_ERR.
    e3_run() {
        local fmt="$1" sid="e3$1"
        local plans="$TMPDIR_BASE/cfb-plans-3-$fmt"
        mkdir -p "$plans/workflow-state"
        printf '# Draft\n' > "$plans/draft.md"
        printf '# Tradeoffs\n' > "$plans/tradeoffs.md"
        E3_JSON="$plans/$sid-$fmt-unresolved-concerns.json"
        mkdir -p "$E3_JSON"
        E3_ERRF="$TMPDIR_BASE/cfb-e3-$fmt-err.txt"
        E3_RC=0
        E3_OUT="$(
            AGENTS_CONFIG_DIR="$FC_ROOT" bash "$FC_ROOT/bin/run-codex-review-loop" \
                --format "$fmt" --session-id "$sid" --plans-dir "$plans" \
                --draft-file "$plans/draft.md" --cap 1 --max-extensions 0 \
                --extensions-used 0 --accepted-tradeoffs "$plans/tradeoffs.md" \
                --round 1 2>"$E3_ERRF"
        )" || E3_RC=$?
        E3_ERR="$(cat "$E3_ERRF" 2>/dev/null)"
    }

    for E3_FMT in test-review security-plan; do
        e3_run "$E3_FMT"
        assert_eq "E3 ($E3_FMT): a finalize that cannot write returns the refusal code, not a verdict" \
            "7" "$E3_RC"
        assert_contains "E3 ($E3_FMT): the refusal is announced on stdout, where the caller reads it" \
            "## Concern Ledger: FINALIZE-FAILED" "$E3_OUT"
        assert_contains "E3 ($E3_FMT): and on stderr, so a caller that only logs one still sees it" \
            "## Concern Ledger: FINALIZE-FAILED" "$E3_ERR"
        assert_not_contains "E3 ($E3_FMT): no APPROVED verdict is emitted for the caller to complete on" \
            "APPROVED" "$E3_OUT"
        assert_eq "E3 ($E3_FMT): and no artifact file exists at the destination it failed to write" \
            "not-a-file" \
            "$([ -d "$E3_JSON" ] && printf 'not-a-file' || printf "$(file_state "$E3_JSON")")"
    done
}
