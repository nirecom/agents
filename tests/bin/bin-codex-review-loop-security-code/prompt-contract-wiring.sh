# tests/bin/bin-codex-review-loop-security-code/prompt-contract-wiring.sh
# Tests: agents/security-scanner.md, skills/review-code-security/SKILL.md, bin/run-codex-review-loop
# Tags: concern-ledger, security-scanner, prompt-contract, drift-guard, TL2, scope:common
# Sourced by tests/bin/bin-codex-review-loop-security-code.sh.
#
# Every other case retypes the scanner's report shape, so test and prompt file
# become two copies of one contract and a reworded marker leaves them green
# while the real subagent can no longer join the round. This file reads the REAL
# prompt file and derives every scanner-side string in the chain from it.

echo ""
echo "--- W: agents/security-scanner.md <-> the security-code loop ---"

PCW_AGENT="$AGENTS_ROOT/agents/security-scanner.md"
PCW_SKILL="$AGENTS_ROOT/skills/review-code-security/SKILL.md"

pcw_delims() { grep -oE '\[PRIOR[^]]*\]' "$PCW_AGENT" 2>/dev/null | sort -u; }
pcw_header() { grep -oE '`## [^`]+`' "$PCW_AGENT" 2>/dev/null | head -1 | tr -d '`'; }
pcw_line_fmt() { grep -oE '`\[<SEV>\][^`]*`' "$PCW_AGENT" 2>/dev/null | head -1 | tr -d '`'; }

PCW_START="$(pcw_delims | grep -F 'START' | head -1)"
PCW_END="$(pcw_delims | grep -F 'END' | head -1)"
PCW_HEADER="$(pcw_header)"
PCW_FMT="$(pcw_line_fmt)"

pcw_render() {
    printf '%s' "$PCW_FMT" | sed \
        -e "s|<SEV>|$1|" -e "s|<ref>|$2|" -e "s|<repo-relative-path>|$3|" \
        -e "s|<anchor>|$4|" -e "s|<category>|$5|" -e "s|<text>|$6|"
}
pcw_report() {
    local f="$1" l
    shift
    {
        printf '# Security Scan Report\n\n'
        printf '%s\n' "$PCW_HEADER"
        if [ "$#" -eq 0 ]; then printf '(none)\n'; fi
        for l in "$@"; do printf '%s\n' "$l"; done
        printf '\n'
    } > "$f"
}

# ---------------------------------------------------------------------------
# W1. The prompt file still declares the things the chain binds on. Asserted as
#     literals against the real file — this is the drift guard.
# ---------------------------------------------------------------------------
{
    W1_SRC="$(cat "$PCW_AGENT" 2>/dev/null || true)"

    assert_eq "W1: the security-scanner prompt file is readable at all" \
        "present" "$(file_state "$PCW_AGENT")"
    assert_contains "W1: it still accepts the prior_concerns input field" "prior_concerns" "$W1_SRC"
    assert_contains "W1: and names the opening delimiter the prior block uses" \
        "[PRIOR CONCERNS START]" "$W1_SRC"
    assert_contains "W1: and the closing one" "[PRIOR CONCERNS END]" "$W1_SRC"
    assert_contains "W1: it still composes the section the ledger parses" \
        "## Concern Delta" "$W1_SRC"
    assert_contains "W1: the delta line still carries a <ref> field" "<ref>" "$W1_SRC"
    assert_match "W1: and <ref> still means the prior C<N>, or '-' when the finding is new" \
        '`<ref>` is the `C<N>`.*`-` when it is new' "$W1_SRC"
    assert_contains "W1: the report still lands in artifact_dir for the caller to hand back" \
        'artifact_dir' "$W1_SRC"

    assert_eq "W1: the prompt file names exactly two prior-concern markers" \
        "2" "$(pcw_delims | grep -c .)"
    assert_eq "W1: the opening marker read out of the file is the one the chain emits" \
        "[PRIOR CONCERNS START]" "$PCW_START"
    assert_eq "W1: and so is the closing one" "[PRIOR CONCERNS END]" "$PCW_END"
    assert_eq "W1: the delta section header read out of the file is the parsed one" \
        "## Concern Delta" "$PCW_HEADER"
    assert_match "W1: and the delta line template was recovered whole" \
        '^\[<SEV>\] <ref> \| .*<category> \| <text>$' "$PCW_FMT"
    assert_eq "W1: a rendered line leaves no placeholder behind" \
        "[HIGH] C7 | bin/auth.sh#issue_token | security | leaked token" \
        "$(pcw_render HIGH C7 "bin/auth.sh" "issue_token" "security" "leaked token")"
}

# ---------------------------------------------------------------------------
# W2. The skill that drives the loop speaks the same vocabulary. The two round
#     scripts are gone, so the SKILL is the only place left that tells the
#     author how the scanner's report re-enters the loop.
# ---------------------------------------------------------------------------
{
    W2_SKILL="$(cat "$PCW_SKILL" 2>/dev/null || true)"
    assert_eq "W2: the review-code-security SKILL is readable" "present" "$(file_state "$PCW_SKILL")"
    assert_contains "W2: it drives the shared loop rather than a private chain" \
        "run-codex-review-loop" "$W2_SKILL"
    assert_contains "W2: and hands the scanner report back through the prestaged flag" \
        "--prestaged-report" "$W2_SKILL"
    assert_contains "W2: naming the producer the report is filed under" \
        "security-scanner" "$W2_SKILL"
    assert_not_contains "W2: the retired round opener is no longer instructed" \
        "open-concern-round.sh" "$W2_SKILL"
    assert_not_contains "W2: nor the retired close-out" "close-concern-round.sh" "$W2_SKILL"
    assert_not_contains "W2: nor the retired ledger wrapper" "review-code-ledger" "$W2_SKILL"
}

# ---------------------------------------------------------------------------
# W3. Round 1 driven by the prompt file's own strings: the reviewer runs inside
#     the loop, then the scanner's report re-enters the same loop.
# ---------------------------------------------------------------------------
PCW_CODEX_TEXT="the loop drops the reviewer exit code on the retry path"
PCW_SCAN_TEXT="the session token is written to the audit log in cleartext"

new_env
PCW_P="$PLANS"; PCW_SID="$SID"
PCW_LED="$(ledger_file "$PCW_P" "$PCW_SID")"

{
    PCW_BODY1="$TMPDIR_BASE/pcw-body-1.txt"
    mk_body "$PCW_BODY1" "$(anchored HIGH - "bin/retry.sh" "retry_once" "correctness" "$PCW_CODEX_TEXT")"
    RL_CODEX_BODY="$PCW_BODY1"
    run_loop --round 1
    assert_contains "W3: the codex producer ran for round 1" \
        "## Codex Review: PERFORMED" "$LAST_OUT"
    assert_eq "W3: the round the loop opened is round 1" \
        "present" "$(file_state "$(delta_file "$PCW_P" "$PCW_SID" 1 review-code-codex)")"

    PCW_REP1="$TMPDIR_BASE/pcw-report-1.txt"
    pcw_report "$PCW_REP1" \
        "$(pcw_render HIGH - "bin/auth.sh" "issue_token" "security" "$PCW_SCAN_TEXT")"
    RL_EXTRA=(--prestaged-report "$PCW_REP1" --prestaged-producer security-scanner
              --prestaged-exec PERFORMED)
    run_loop --round 1
    RL_EXTRA=()

    PCW_SDF="$(delta_file "$PCW_P" "$PCW_SID" 1 security-scanner)"
    assert_eq "W3: a report rendered from the prompt file parses as a real delta, not ABSENT" \
        "COMPLETE" "$(staging_field "$PCW_SDF" 6)"
    assert_eq "W3: both producers' concerns joined one ledger" "2" "$(entry_count "$PCW_LED")"

    PCW_ID_C="$(id_for_text "$PCW_LED" "$PCW_CODEX_TEXT")"
    PCW_ID_S="$(id_for_text "$PCW_LED" "$PCW_SCAN_TEXT")"
    assert_match "W3: the reviewer's concern was minted an id" '^C[0-9]+$' "$PCW_ID_C"
    assert_match "W3: and so was the scanner's, read back from its rendered line" \
        '^C[0-9]+$' "$PCW_ID_S"
    assert_eq "W3: the scanner entry is attributed to the scanner" \
        "security-scanner" "$(entry_field "$PCW_LED" "$PCW_ID_S" "$F_ORIGIN")"
    assert_eq "W3: an unresolved round-1 HIGH asks for a revision" "1" "$LAST_RC"
}

# ---------------------------------------------------------------------------
# W4. Round 2 — the prior block, in the delimiters read out of the prompt file,
#     so a rename the loop did not follow fails here instead of two files
#     quietly disagreeing.
# ---------------------------------------------------------------------------
{
    PCW_PRIOR="$(run_cli render-prior --plans-dir "$PCW_P" --session-id "$PCW_SID" \
        --format "$LEDGER_FORMAT" 2>/dev/null || true)"
    assert_contains "W4: the prior offered to the next round names the scanner's id" \
        "$PCW_ID_S" "$PCW_PRIOR"
    assert_contains "W4: with the text it was raised under" "$PCW_SCAN_TEXT" "$PCW_PRIOR"
    assert_contains "W4: and the reviewer's concern rides in the same prior" \
        "$PCW_ID_C" "$PCW_PRIOR"

    PCW_BODY2="$TMPDIR_BASE/pcw-body-2.txt"
    mk_body "$PCW_BODY2" \
        "$(anchored HIGH "$PCW_ID_C" "bin/retry.sh" "retry_once" "correctness" "$PCW_CODEX_TEXT")"
    RL_CODEX_BODY="$PCW_BODY2"
    run_loop --round 2
    PCW_PTEXT="$(cat "$LAST_PROMPT" 2>/dev/null || true)"

    assert_contains "W4: the reviewer prompt opens its prior block with the marker the scanner is given" \
        "$PCW_START" "$PCW_PTEXT"
    assert_contains "W4: and closes it with the same one" "$PCW_END" "$PCW_PTEXT"
    assert_contains "W4: the prior it carries names the ids the ledger minted" \
        "$PCW_ID_C" "$PCW_PTEXT"
    assert_contains "W4: including the scanner's, so one vocabulary serves both producers" \
        "$PCW_ID_S" "$PCW_PTEXT"

    PCW_BLOCK="$(printf '%s\n' "$PCW_PTEXT" | sed -n "/$(printf '%s' "$PCW_START" | sed 's/[][\\.*^$/]/\\&/g')/,/$(printf '%s' "$PCW_END" | sed 's/[][\\.*^$/]/\\&/g')/p")"
    assert_contains "W4: and the ids sit inside the marked block, not loose in the prompt" \
        "$PCW_ID_C" "$PCW_BLOCK"

    PCW_REP2="$TMPDIR_BASE/pcw-report-2.txt"
    pcw_report "$PCW_REP2" \
        "$(pcw_render HIGH "$PCW_ID_S" "bin/auth.sh" "issue_token" "security" "$PCW_SCAN_TEXT")"
    RL_EXTRA=(--prestaged-report "$PCW_REP2" --prestaged-producer security-scanner
              --prestaged-exec PERFORMED)
    run_loop --round 2
    RL_EXTRA=()

    assert_eq "W4: a finding re-reported under its prior <ref> keeps its id" \
        "same" "$(id_is "$PCW_LED" "$PCW_SCAN_TEXT" "$PCW_ID_S")"
    assert_eq "W4: and no id was re-minted across the two rounds" "2" "$(entry_count "$PCW_LED")"
    assert_eq "W4: the second round at the cap escalates rather than asking again" \
        "5" "$LAST_RC"
    assert_eq "W4: the reviewer's id is unchanged too" \
        "same" "$(id_is "$PCW_LED" "$PCW_CODEX_TEXT" "$PCW_ID_C")"
}
