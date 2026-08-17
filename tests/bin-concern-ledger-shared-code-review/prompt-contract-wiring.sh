# tests/bin-concern-ledger-shared-code-review/prompt-contract-wiring.sh
# Tests: agents/security-scanner.md, skills/review-code-security/scripts/open-concern-round.sh, bin/review-code-ledger
# Tags: concern-ledger, security-scanner, prompt-contract, drift-guard, TL2, scope:common
# Sourced by tests/bin-concern-ledger-shared-code-review.sh.

# Why this case exists. Every other case in this suite replays the security
# scanner as a handcrafted report body: the delimiters, the section header and
# the delta line shape are all typed out again inside the test. That makes the
# test and agents/security-scanner.md two independent copies of one contract.
# Rename `## Concern Delta`, drop the `prior_concerns` field, or reword the
# [PRIOR CONCERNS START]/[PRIOR CONCERNS END] markers in the prompt file, and
# every case here keeps passing while the real subagent stops being able to
# join the round.

# So this file pins the contract in the direction the other cases cannot. It
# reads the real agents/security-scanner.md — never a copy — asserts the four
# literals the chain depends on are still in it, and then drives the real
# open-concern-round.sh -> run-quality-gates.sh -> close-concern-round.sh chain
# with every scanner-side string *derived from that file* rather than typed
# here. If the prompt file drifts, the derived strings drift with it and the
# chain assertions fail, which is the whole point.

echo ""
echo "--- shared prompt contract: agents/security-scanner.md <-> the round chain ---"

PCW_AGENT="$AGENTS_ROOT/agents/security-scanner.md"

# --- literals read out of the real prompt file ------------------------------

# pcw_delims — every distinct '[PRIOR ...]' marker the prompt file names, one
# per line, deduplicated. Matched by shape, not by the words inside, so the
# extraction cannot silently agree with a marker this test invented.
pcw_delims() { grep -oE '\[PRIOR[^]]*\]' "$PCW_AGENT" 2>/dev/null | sort -u; }

# pcw_header — the first backticked '## ...' heading the prompt file tells the
# scanner to compose. This is the section bin/concern-ledger parses out of the
# report, so the report this test builds is titled with whatever the prompt
# file currently says.
pcw_header() { grep -oE '`## [^`]+`' "$PCW_AGENT" 2>/dev/null | head -1 | tr -d '`'; }

# pcw_line_fmt — the backticked delta-line template, '[<SEV>] <ref> | ...'.
pcw_line_fmt() { grep -oE '`\[<SEV>\][^`]*`' "$PCW_AGENT" 2>/dev/null | head -1 | tr -d '`'; }

PCW_START="$(pcw_delims | grep -F 'START' | head -1)"
PCW_END="$(pcw_delims | grep -F 'END' | head -1)"
PCW_HEADER="$(pcw_header)"
PCW_FMT="$(pcw_line_fmt)"

# pcw_render <sev> <ref> <path> <anchor> <category> <text> — one delta line
# built by filling the prompt file's own template. No '|' in any argument.
pcw_render() {
    printf '%s' "$PCW_FMT" | sed \
        -e "s|<SEV>|$1|" -e "s|<ref>|$2|" -e "s|<repo-relative-path>|$3|" \
        -e "s|<anchor>|$4|" -e "s|<category>|$5|" -e "s|<text>|$6|"
}

# pcw_report <file> <delta-line>... — a scanner report whose section header and
# whose lines both come from the prompt file, not from mk_report's hardcoded
# copy of them.
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
# W1. The prompt file still declares the four things the chain binds on.
#     Asserted against the real file as literals — this is the drift guard, so
#     here the strings are deliberately spelled out rather than derived.
# ---------------------------------------------------------------------------
{
    W1_SRC="$(cat "$PCW_AGENT" 2>/dev/null || true)"

    assert_eq "W1: the security-scanner prompt file is readable at all" \
        "present" "$(file_state "$PCW_AGENT")"
    assert_contains "W1: it still accepts the prior_concerns input field" \
        "prior_concerns" "$W1_SRC"
    assert_contains "W1: and names the opening delimiter open-concern-round.sh emits" \
        "[PRIOR CONCERNS START]" "$W1_SRC"
    assert_contains "W1: and the closing one" "[PRIOR CONCERNS END]" "$W1_SRC"
    assert_contains "W1: it still composes the section the ledger parses" \
        "## Concern Delta" "$W1_SRC"
    assert_contains "W1: the delta line still carries a <ref> field" \
        "<ref>" "$W1_SRC"
    assert_match "W1: and <ref> still means the prior C<N>, or '-' when the finding is new" \
        '`<ref>` is the `C<N>`.*`-` when it is new' "$W1_SRC"
    assert_contains "W1: the report still lands in artifact_dir for the caller to hand back" \
        'artifact_dir' "$W1_SRC"

    # The extraction the rest of this file runs on must have found exactly the
    # markers W1 just pinned; an empty or over-broad match would otherwise let
    # the chain cases below pass vacuously.
    assert_eq "W1: the prompt file names exactly two prior-concern markers" \
        "2" "$(pcw_delims | grep -c .)"
    assert_eq "W1: the opening marker read out of the file is the one the scripts emit" \
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
# W2. The chain, driven by the prompt file's own strings. Round 1 opens, both
#     producers report, the round closes. Nothing scanner-shaped in here is
#     typed by the test: the report is titled and formatted from the file read
#     in W1.
# ---------------------------------------------------------------------------
PCW_SID="pcw1"
PCW_P="$TMPDIR_BASE/pcw-plans-1"
mkdir -p "$PCW_P/workflow-state"

PCW_CODEX_TEXT="the wrapper drops the reviewer exit code on the retry path"
PCW_SCAN_TEXT="the session token is written to the audit log in cleartext"

pcw_open() {
    PCW_OPEN="$(
        SESSION_ID="$PCW_SID" PLANS_DIR="$PCW_P" AGENTS_CONFIG_DIR="$AGENTS_ROOT" \
            bash "$AGENTS_ROOT/skills/review-code-security/scripts/open-concern-round.sh" 2>/dev/null
    )"
}
pcw_kv() { printf '%s\n' "$PCW_OPEN" | grep -m1 "^$1=" | cut -d'=' -f2-; }

# pcw_gates <round> <codex-body> <prompt-capture> — run-quality-gates.sh with
# the codex CLI mocked; the mock writes the prompt it received to <capture>.
pcw_gates() {
    PCW_GATES="$(
        cd "$REPO" || exit 1
        export PATH="$FULL_PATH" HOME="$TMPDIR_BASE" AGENTS_CONFIG_DIR="$AGENTS_ROOT"
        export CODEX_MOCK_PROMPT="$3" CODEX_MOCK_BODY="$2" CODEX_MOCK_EXIT=0
        export PLANS_DIR="$PCW_P" WORKFLOW_PLANS_DIR="$PCW_P" \
               CLAUDE_WORKFLOW_DIR="$PCW_P/workflow-state" \
               SESSION_ID="$PCW_SID" CLAUDE_SESSION_ID="$PCW_SID" \
               CLAUDE_CODE_SESSION_ID="$PCW_SID" CONCERN_LEDGER_ROUND="$1"
        bash "$AGENTS_ROOT/skills/review-code-security/scripts/run-quality-gates.sh" 2>/dev/null
    )"
}

pcw_close() {
    PCW_CLOSE_RC=0
    PCW_CLOSE="$(
        AGENTS_CONFIG_DIR="$AGENTS_ROOT" bash \
            "$AGENTS_ROOT/skills/review-code-security/scripts/close-concern-round.sh" \
            "$1" "$PCW_P" "$PCW_SID" security-scanner PERFORMED "$2" 2>/dev/null
    )" || PCW_CLOSE_RC=$?
}

{
    pcw_open
    PCW_R1="$(pcw_kv ROUND)"
    assert_eq "W2: the fresh review opens at round 1" "1" "$PCW_R1"

    PCW_BODY1="$TMPDIR_BASE/pcw-body-1.txt"
    mk_body "$PCW_BODY1" "$(anchored HIGH - "bin/retry.sh" "retry_once" "correctness" "$PCW_CODEX_TEXT")"
    pcw_gates "$PCW_R1" "$PCW_BODY1" "$TMPDIR_BASE/pcw-prompt-1.txt"
    assert_contains "W2: the codex producer ran for round 1" \
        "## Codex Review: PERFORMED" "$PCW_GATES"

    # The scanner half, rendered from agents/security-scanner.md. `-` is the
    # ref the prompt file reserves for a new finding.
    PCW_REP1="$TMPDIR_BASE/pcw-report-1.txt"
    pcw_report "$PCW_REP1" \
        "$(pcw_render HIGH - "bin/auth.sh" "issue_token" "security" "$PCW_SCAN_TEXT")"
    pcw_close "$PCW_R1" "$PCW_REP1"

    assert_eq "W2: the round closes successfully" "0" "$PCW_CLOSE_RC"
    PCW_LED="$(ledger_file "$PCW_P" "$PCW_SID")"

    # This is the cross-check: a report whose header and line shape came out of
    # the prompt file parsed as a real report. A renamed section, or a reworded
    # line template, lands here as ABSENT and this assertion fails.
    PCW_SDF="$(delta_file "$PCW_P" "$PCW_SID" 1 security-scanner)"
    assert_eq "W2: a report rendered from the prompt file parses as a real delta, not ABSENT" \
        "COMPLETE" "$(staging_field "$PCW_SDF" 5)"
    assert_eq "W2: both producers' concerns joined one ledger" "2" "$(entry_count "$PCW_LED")"

    PCW_ID_C="$(id_for_text "$PCW_LED" "$PCW_CODEX_TEXT")"
    PCW_ID_S="$(id_for_text "$PCW_LED" "$PCW_SCAN_TEXT")"
    assert_match "W2: the reviewer's concern was minted an id" '^C[0-9]+$' "$PCW_ID_C"
    assert_match "W2: and so was the scanner's, read back from its rendered line" \
        '^C[0-9]+$' "$PCW_ID_S"
    assert_eq "W2: the scanner entry is attributed to the scanner" \
        "security-scanner" "$(entry_field "$PCW_LED" "$PCW_ID_S" "$F_ORIGIN")"
}

# ---------------------------------------------------------------------------
# W3. Round 2 — the prior block. The delimiters asserted here are the ones read
#     out of the prompt file, so a rename in agents/security-scanner.md that
#     open-concern-round.sh (and bin/review-code-codex) did not follow shows up
#     as a failure instead of as two files quietly disagreeing.
# ---------------------------------------------------------------------------
{
    pcw_open
    PCW_R2="$(pcw_kv ROUND)"
    assert_eq "W3: the second round of the live review opens as round 2" "2" "$PCW_R2"

    assert_contains "W3: the round opener wraps the prior concerns in the marker the prompt file declares" \
        "$PCW_START" "$PCW_OPEN"
    assert_contains "W3: and closes them with the marker the prompt file declares" \
        "$PCW_END" "$PCW_OPEN"

    # The IDs the scanner is expected to reuse must sit *inside* that block —
    # a prior list emitted outside the markers is data the subagent is
    # contracted to ignore.
    PCW_BLOCK="$(printf '%s\n' "$PCW_OPEN" | sed -n "/^$(printf '%s' "$PCW_START" | sed 's/[][\\.*^$/]/\\&/g')\$/,/^$(printf '%s' "$PCW_END" | sed 's/[][\\.*^$/]/\\&/g')\$/p")"
    assert_contains "W3: the scanner's own concern is offered back to it by id" \
        "$PCW_ID_S" "$PCW_BLOCK"
    assert_contains "W3: with the text it was raised under" "$PCW_SCAN_TEXT" "$PCW_BLOCK"
    assert_contains "W3: and the reviewer's concern rides in the same block" \
        "$PCW_ID_C" "$PCW_BLOCK"

    # The codex producer receives the same markers. Asserting it against the
    # strings read from the scanner's prompt file is what keeps the two
    # producers on one vocabulary (CPR-ORTH).
    PCW_BODY2="$TMPDIR_BASE/pcw-body-2.txt"
    mk_body "$PCW_BODY2" "$(anchored HIGH "$PCW_ID_C" "bin/retry.sh" "retry_once" "correctness" "$PCW_CODEX_TEXT")"
    PCW_PROMPT2="$TMPDIR_BASE/pcw-prompt-2.txt"
    pcw_gates "$PCW_R2" "$PCW_BODY2" "$PCW_PROMPT2"
    PCW_PTEXT="$(cat "$PCW_PROMPT2" 2>/dev/null || true)"

    assert_contains "W3: the reviewer prompt opens its prior block with the same marker the scanner is given" \
        "$PCW_START" "$PCW_PTEXT"
    assert_contains "W3: and closes it with the same one" "$PCW_END" "$PCW_PTEXT"
    assert_contains "W3: and the prior it carries names the ids by the numbering the ledger minted" \
        "$PCW_ID_C" "$PCW_PTEXT"

    # The <ref> semantics, end to end: the scanner re-reports its round-1
    # finding under the id the prior block just handed it, using the prompt
    # file's own line template. The ledger must recognise it as the same
    # concern rather than mint a second one.
    PCW_LED="$(ledger_file "$PCW_P" "$PCW_SID")"
    PCW_REP2="$TMPDIR_BASE/pcw-report-2.txt"
    pcw_report "$PCW_REP2" \
        "$(pcw_render HIGH "$PCW_ID_S" "bin/auth.sh" "issue_token" "security" "$PCW_SCAN_TEXT")"
    pcw_close "$PCW_R2" "$PCW_REP2"

    assert_eq "W3: the second round closes successfully" "0" "$PCW_CLOSE_RC"
    assert_contains "W3: and reports a verified finalize" "CHECK=ok" "$PCW_CLOSE"
    assert_eq "W3: a finding re-reported under its prior <ref> keeps its id" \
        "same" "$(id_is "$PCW_LED" "$PCW_SCAN_TEXT" "$PCW_ID_S")"
    assert_eq "W3: and no id was re-minted across the two rounds" \
        "2" "$(entry_count "$PCW_LED")"
}
