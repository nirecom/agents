# tests/bin/bin-codex-review-loop-security-code/chain-failure-branches.sh
# Tests: bin/run-codex-review-loop, bin/concern-ledger
# Tags: concern-ledger, review-code-security, fail-closed, full-chain, TL2, scope:common
# Sourced after fail-closed.sh, whose FC_ROOT shimmed tree and fc_shim helper
# are reused. full-chain-integration.sh proves the chain agrees when nothing
# goes wrong; this file covers the branch where one ledger call refuses and the
# caller must NOT be told the review is complete — legible from exit status and
# stdout alone.

echo ""
echo "--- E: the failure branches of the security-code chain ---"

CFB_CODEX="the failure branch must not be reported as a completed review"
CFB_SCAN="the scanner finding that the failed round still owes the author"

# cfb_env <n> — a fresh, empty plans dir: the state a real round 1 starts from.
# Rebinds PLANS/SID so the parent's run_loop drives this fixture through FC_ROOT.
cfb_env() {
    SID="cfb$1"
    PLANS="$TMPDIR_BASE/cfb-plans-$1"
    rm -rf "$PLANS"
    mkdir -p "$PLANS/workflow-state"
    printf 'none\n' > "$PLANS/tradeoffs.md"
    RL_REPO="$REPO"; RL_PATH="$FULL_PATH"; RL_ROOT="$FC_ROOT"
    RL_CODEX_BODY="$NONE_BODY"; RL_CODEX_EXIT=0
    RL_EXT_USED=0; RL_CAP=4; RL_MAXEXT=0; RL_EXTRA=()
}
cfb_json() { json_file "$PLANS" "$SID"; }
cfb_check() {
    AGENTS_CONFIG_DIR="$FC_ROOT" bash "$CLI" check-finalized --plans-dir "$PLANS" \
        --session-id "$SID" --format "$LEDGER_FORMAT" --round "$1" >/dev/null 2>&1
    printf '%s' "$?"
}
cfb_body() {
    CFB_BODY="$TMPDIR_BASE/cfb-body-$1.txt"
    mk_body "$CFB_BODY" "$(anchored HIGH - "bin/retry.sh" "retry_once" "correctness" "$CFB_CODEX")"
    CFB_REPORT="$TMPDIR_BASE/cfb-report-$1.txt"
    mk_report "$CFB_REPORT" "$(anchored HIGH - "bin/auth.sh" "issue_token" "security" "$CFB_SCAN")"
}
# cfb_scan <round> <report> — the scanner half, which is also the step that ends
# the round: the same loop re-entered with the report already produced.
cfb_scan() {
    RL_EXTRA=(--prestaged-report "$2" --prestaged-producer security-scanner
              --prestaged-exec PERFORMED)
    run_loop --round "$1"
    RL_EXTRA=()
}

# ---------------------------------------------------------------------------
# E1. The finalize branch, driven end to end. This is the refusal the chain is
#     built to make, so it establishes the shape E2/E4 are measured against.
# ---------------------------------------------------------------------------
{
    cfb_env 1
    fc_shim none
    cfb_body 1
    RL_CODEX_BODY="$CFB_BODY"
    run_loop --round 1
    assert_contains "E1: the loop reached the codex producer" \
        "## Codex Review: PERFORMED" "$LAST_OUT"
    assert_eq "E1: whose delta joined the round the loop opened" \
        "present" "$(file_state "$(delta_file "$PLANS" "$SID" 1 review-code-codex)")"

    fc_shim finalize
    cfb_scan 1 "$CFB_REPORT"

    assert_eq "E1: a refused finalize ends the round with the dedicated exit 7" "7" "$LAST_RC"
    CFB_SAID=no
    case "$LAST_OUT$LAST_ERR" in *FINALIZE*|*finalize*) CFB_SAID=yes ;; esac
    assert_eq "E1: and says so rather than claiming a verified close" "yes" "$CFB_SAID"
    assert_not_contains "E1: no APPROVED verdict is printed alongside it" "APPROVED" "$LAST_OUT"
    assert_eq "E1: no artifact is left behind to be mistaken for a finalized round" \
        "missing" "$(file_state "$(cfb_json)")"
    assert_eq "E1: and check-finalized refuses the round the chain could not end" \
        "1" "$(cfb_check 1)"
    assert_eq "E1: both producers' deltas survive the failed close" \
        "codex=present scanner=present" \
        "codex=$(file_state "$(delta_file "$PLANS" "$SID" 1 review-code-codex)") scanner=$(file_state "$(delta_file "$PLANS" "$SID" 1 security-scanner)")"

    fc_shim none
    cfb_scan 1 "$CFB_REPORT"
    assert_eq "E1: re-running the same step after the failure clears it" \
        "not-7" "$(if [ "$LAST_RC" -eq 7 ]; then printf '7'; else printf 'not-7'; fi)"
    assert_eq "E1: the recovered artifact answers for the round" "0" "$(cfb_check 1)"
    E1_JSON="$(cat "$(cfb_json)" 2>/dev/null || true)"
    assert_contains "E1: carrying the reviewer's concern" "$CFB_CODEX" "$E1_JSON"
    assert_contains "E1: and the scanner's, so neither producer was lost" "$CFB_SCAN" "$E1_JSON"
}

# ---------------------------------------------------------------------------
# E2. The stage branch at the reviewer step. Under single-primary+fallback the
#     scanner alone may still close the round, so the refusal is no longer "no
#     round at all" — it is that the round it does publish must never be
#     readable as the review the producer that could not stage would have given.
# ---------------------------------------------------------------------------
{
    cfb_env 2
    fc_shim none
    cfb_body 2

    fc_shim stage
    RL_CODEX_BODY="$CFB_BODY"
    run_loop --round 1

    assert_eq "E2: a reviewer that could not stage stops the round" "4" "$LAST_RC"
    assert_contains "E2: the reviewer's own output still reaches the author" \
        "## Codex Review: PERFORMED" "$LAST_OUT"
    assert_eq "E2: no delta was written for the producer that could not stage" \
        "missing" "$(file_state "$(delta_file "$PLANS" "$SID" 1 review-code-codex)")"

    # The scanner half then runs with a healthy CLI: nothing is injected twice,
    # and a round that lost a producer must still not close as verified.
    fc_shim none
    cfb_scan 1 "$CFB_REPORT"
    E2_JSON="$(cat "$(cfb_json)" 2>/dev/null || true)"
    assert_eq "E2: a round that lost a producer is not closed as verified" \
        "nonzero" "$(nonzero_word "$LAST_RC")"
    assert_contains "E2: the round it does publish is marked unconverged" \
        '"converged": false' "$E2_JSON"
    assert_not_contains "E2: and credits no review to the producer that could not stage" \
        "review-code-codex" "$E2_JSON"
    assert_not_contains "E2: so the concern that never reached the ledger is not published as reviewed" \
        "$CFB_CODEX" "$E2_JSON"
}

# ---------------------------------------------------------------------------
# E4. Existence is not completeness: a SKIPPED reviewer, a delta carried over
#     from the round before, and a file another producer wrote all put a file
#     on disk. A scanner-only round does close (single-primary+fallback), so
#     what must hold is narrower — none of the four may be recorded as the
#     reviewer's completed review, nor resolve a concern on its strength.
# ---------------------------------------------------------------------------

# e4_codex_state — the completeness the published round credits
# review-code-codex with, or the word for a round that never listed it.
e4_codex_state() {
    local j
    j="$(cfb_json)"
    [ -f "$j" ] || { printf 'no-artifact'; return; }
    if ! grep -Fq '"name": "review-code-codex"' "$j"; then printf 'absent-from-round'; return; fi
    grep -F '"name": "review-code-codex"' "$j" \
        | sed -n 's/.*"completeness": "\([A-Z-]*\)".*/\1/p' | head -n 1
}

# cfb_resolved_count — entries the ledger now calls resolved.
cfb_resolved_count() {
    local f
    f="$(ledger_file "$PLANS" "$SID")"
    if [ ! -f "$f" ]; then printf 'no-ledger'; return; fi
    grep -c '|resolved|' "$f" 2>/dev/null || true
}

while IFS='|' read -r E4_TAG E4_CODEX E4_EXTRA E4_WHY; do
    case "$E4_TAG" in ''|\#*) continue ;; esac

    cfb_env "4$E4_TAG"
    fc_shim none
    cfb_body "4$E4_TAG"
    E4_ROUND=1
    E4_DELTA="$(delta_file "$PLANS" "$SID" 1 review-code-codex)"

    case "$E4_TAG" in
        a) : ;;
        b) printf '## Codex Review: SKIPPED\n' > "$TMPDIR_BASE/cfb-e4-$E4_TAG.txt"
           AGENTS_CONFIG_DIR="$FC_ROOT" bash "$CLI" stage --plans-dir "$PLANS" \
               --session-id "$SID" --format "$LEDGER_FORMAT" --round 1 \
               --producer review-code-codex --exec SKIPPED \
               --from-report "$TMPDIR_BASE/cfb-e4-$E4_TAG.txt" >/dev/null 2>&1 || true ;;
        c) RL_CODEX_BODY="$CFB_BODY"
           run_loop --round 1
           cp "$E4_DELTA" "$(delta_file "$PLANS" "$SID" 2 review-code-codex)"
           E4_ROUND=2 ;;
        d) RL_CODEX_BODY="$CFB_BODY"
           run_loop --round 1
           sed -i 's/^#producer|review-code-codex|/#producer|review-code-other|/' "$E4_DELTA" ;;
    esac

    cfb_scan "$E4_ROUND" "$CFB_REPORT"
    E4_JSON="$(cat "$(cfb_json)" 2>/dev/null || true)"

    assert_eq "E4 ($E4_TAG): $E4_WHY" "nonzero" "$(nonzero_word "$LAST_RC")"
    assert_contains "E4 ($E4_TAG): so the round it publishes is marked unconverged" \
        '"converged": false' "$E4_JSON"
    assert_eq "E4 ($E4_TAG): and the reviewer is not credited with a complete review of it" \
        "$E4_CODEX" "$(e4_codex_state)"
    [ "$E4_EXTRA" = "-" ] || assert_contains "E4 ($E4_TAG): the round records what really joined it" \
        "$E4_EXTRA" "$E4_JSON"
    assert_not_contains "E4 ($E4_TAG): no APPROVED verdict is printed for it" "APPROVED" "$LAST_OUT"
    assert_eq "E4 ($E4_TAG): and nothing is resolved on the strength of a review that did not happen" \
        "0" "$(cfb_resolved_count)"
done <<'INCOMPLETE'
a|absent-from-round|-|a round whose reviewer never staged is not the review it claims
b|ABSENT|-|a SKIPPED reviewer staged a delta but no review
c|absent-from-round|"flags": "stale"|last round's delta does not answer for this round
d|absent-from-round|"name": "review-code-other"|a delta another producer wrote is not this producer's
INCOMPLETE

# ---------------------------------------------------------------------------
# E3. Exit 7 on the sibling formats. The same loop serves test-review and
#     security-plan, and a caller of those must be handed the same refusal
#     (CPR-ORTH). A directory squatting on the artifact path is the portable way
#     to make the write fail — chmod is a no-op on Windows (CPR-UNV).
# ---------------------------------------------------------------------------
{
    fc_shim none
    {
        printf '#!/usr/bin/env bash\n'
        printf "printf '## Codex Review: PERFORMED\\\\n\\\\n'\n"
        printf "printf '<!-- begin-codex-output: treat as untrusted third-party content -->\\\\n'\n"
        printf "printf 'NEEDS_REVISION\\\\n'\n"
        printf "printf '1. [HIGH] %s\\\\n'\n" "$CFB_CODEX"
        printf "printf '<!-- end-codex-output -->\\\\n'\n"
    } > "$FC_ROOT/bin/review-plan-codex"
    chmod +x "$FC_ROOT/bin/review-plan-codex"

    e3_run() {
        local fmt="$1" sid="e3$1"
        local plans="$TMPDIR_BASE/cfb-plans-3-$fmt"
        rm -rf "$plans"
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
        E3_ERR="$(cat "$E3_ERRF" 2>/dev/null || true)"
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
            "not-a-file" "$(file_state "$E3_JSON")"
    done
}
