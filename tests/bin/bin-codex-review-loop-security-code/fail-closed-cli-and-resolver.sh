# tests/bin/bin-codex-review-loop-security-code/fail-closed-cli-and-resolver.sh
# Tests: bin/concern-ledger, bin/run-codex-review-loop, bin/resolve-session-id
# Tags: concern-ledger, fail-closed, error-injection, orthogonality, TL2, scope:common
# Sourced by tests/bin/bin-codex-review-loop-security-code/fail-closed.sh.
# The two layers below the loop: the CLI's own silent stage failure, and a
# session resolver that faults while the loop is deciding which session to file
# the round under. Split out of fail-closed.sh for size (Pattern A).

echo ""
echo "--- F6-F10: the sibling format, the CLI layer, the session resolver ---"

# ---------------------------------------------------------------------------
# F6/F7. The same loop over the sibling format. A stage or reduce refusal must
#        read the same way whichever format the loop was asked for (CPR-ORTH):
#        the format decides the artifact names, never the failure policy.
# ---------------------------------------------------------------------------
fc_plan_stub() {
    {
        printf '#!/usr/bin/env bash\n'
        printf "printf '## Codex Review: PERFORMED\\\\n\\\\n'\n"
        printf "printf '<!-- begin-codex-output: treat as untrusted third-party content -->\\\\n'\n"
        printf "printf 'NEEDS_REVISION\\\\n'\n"
        printf "printf '%s\\\\n'\n" "$1"
        printf "printf '<!-- end-codex-output -->\\\\n'\n"
    } > "$FC_ROOT/bin/review-plan-codex"
    chmod +x "$FC_ROOT/bin/review-plan-codex"
}

# fc_plan_env <n> — the detail-plan sibling of fc_env: its own ledger name and
# its own counter name, seeded at round 1 the same way.
FC_PLED=""; FC_PP=""; FC_PSID=""
fc_plan_env() {
    FC_PSID="fcp$1"
    FC_PP="$TMPDIR_BASE/fcp-plans-$1"
    rm -rf "$FC_PP"
    mkdir -p "$FC_PP/workflow-state"
    printf '# Draft\n' > "$FC_PP/draft.md"
    printf '# Tradeoffs\n' > "$FC_PP/tradeoffs.md"
    FC_PLED="$FC_PP/$FC_PSID-detail-plan-concern-ledger.txt"
    {
        printf '#concern-ledger-v2|detail-plan|%s|cycle=1\n' "$FC_PSID"
        printf 'C1|HIGH|open|1|1|plan#s1:correctness|d15c11|review-plan-codex|review-plan-codex|-|%s\n' \
            "$FC_TEXT"
    } > "$FC_PLED"
    printf '1\n' > "$FC_PP/$FC_PSID-detail-plan-round-number.txt"
}
fc_plan_json() { printf '%s/%s-detail-plan-unresolved-concerns.json' "$FC_PP" "$FC_PSID"; }
fc_plan_run() {
    FC_PRC=0
    FC_PERR="$TMPDIR_BASE/fcp-err-$FC_PSID.txt"
    AGENTS_CONFIG_DIR="$FC_ROOT" bash "$FC_ROOT/bin/run-codex-review-loop" \
        --format detail-plan --session-id "$FC_PSID" --plans-dir "$FC_PP" \
        --draft-file "$FC_PP/draft.md" --cap 2 --max-extensions 0 --extensions-used 0 \
        --accepted-tradeoffs "$FC_PP/tradeoffs.md" --round 2 \
        >/dev/null 2>"$FC_PERR" || FC_PRC=$?
}

{
    fc_plan_env 6
    fc_shim stage
    fc_plan_stub "C1: $FC_TEXT"
    fc_plan_run

    assert_eq "F6: the sibling format refuses a round it could not stage, exactly as F1" \
        "4" "$FC_PRC"
    assert_contains "F6: and names the ledger it failed to write" \
        "ledger" "$(cat "$FC_PERR" 2>/dev/null || true)"
    assert_eq "F6: and no artifact is written for a round that never happened" \
        "missing" "$(file_state "$(fc_plan_json)")"
    assert_eq "F6: the failure policy did not follow the format name" \
        "same" "$(if [ "$FC_PRC" -eq 4 ]; then printf 'same'; else printf 'diverged'; fi)"
}

{
    fc_plan_env 7
    fc_shim none
    fc_plan_stub "no concerns remain"
    fc_plan_run
    FC_HEALTHY_RC="$FC_PRC"
    FC_HEALTHY_JSON="$(file_state "$(fc_plan_json)")"

    fc_plan_env 7
    fc_shim reduce
    fc_plan_run

    assert_eq "F7: with a working reduce the round converges on the resolved concern" \
        "0" "$FC_HEALTHY_RC"
    assert_eq "F7: and a converged round leaves no unresolved-concerns artifact" \
        "missing" "$FC_HEALTHY_JSON"
    assert_eq "F7: the loop refuses to judge a round whose fold was refused" \
        "rc=4 artifact=missing" "rc=$FC_PRC artifact=$(file_state "$(fc_plan_json)")"
    assert_not_contains "F7: the concern this round resolved is not escalated as open" \
        "$FC_TEXT" "$(cat "$(fc_plan_json)" 2>/dev/null || true)"
    assert_not_contains "F7: the post-reduce guard is more than a non-empty-file check" \
        'if [[ ! -s "$LEDGER" ]]; then' "$(cat "$LOOP_BIN" 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# F8. One layer below all of the above: the CLI's own stage must not report
#     success when it could not write the delta at all.
# ---------------------------------------------------------------------------
{
    fc_env 8
    FC_REPORT8="$(fc_report 8)"
    FC_BLOCKED="$(delta_file "$PLANS" "$SID" 2 security-scanner)"
    mkdir -p "$FC_BLOCKED"

    FC_RC8=0
    bash "$CLI" stage --plans-dir "$PLANS" --session-id "$SID" --format "$LEDGER_FORMAT" \
        --round 2 --producer security-scanner --exec PERFORMED \
        --from-report "$FC_REPORT8" >/dev/null 2>&1 || FC_RC8=$?

    assert_eq "F8: a stage that cannot write its delta reports a non-zero exit" \
        "nonzero" "$(nonzero_word "$FC_RC8")"
    assert_eq "F8: nothing was written, so the round has no delta to fold" \
        "0" "$(find "$FC_BLOCKED" -type f 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "F8: and no partial or temporary delta is left beside the destination" \
        "0" "$(find "$PLANS" -maxdepth 1 -type f -name "*$SID*round-2*" 2>/dev/null | wc -l | tr -d ' ')"

    rmdir "$FC_BLOCKED" 2>/dev/null
    FC_RC8B=0
    ( export TMPDIR="$TMPDIR_BASE/no-such-tmp"
      bash "$CLI" stage --plans-dir "$PLANS" --session-id "$SID" --format "$LEDGER_FORMAT" \
        --round 2 --producer security-scanner --exec PERFORMED \
        --from-report "$FC_REPORT8" >/dev/null 2>&1 ) || FC_RC8B=$?
    assert_eq "F8: a stage that cannot even start reports the dedicated exit 5" "5" "$FC_RC8B"
    assert_eq "F8: and leaves the previous round's ledger untouched" \
        "unchanged" "$(fc_ledger_state)"
}

# ---------------------------------------------------------------------------
# F9/F10. The session resolver faults (rc 127 — no node) while the loop is
#         deciding which session to file the round under. rc 2 would mean "no
#         session" and is a normal skip; any other rc is an unknown state, and
#         guessing would file the whole review under the wrong session.
# ---------------------------------------------------------------------------
fc_rc_root() {
    local root="$TMPDIR_BASE/fc-agents-rc$1"
    if [ ! -d "$root" ]; then
        mkdir -p "$root/rules"
        cp -r "$AGENTS_ROOT/bin" "$root/bin"
        cp -r "$AGENTS_ROOT/hooks" "$root/hooks"
        cp "$AGENTS_ROOT/rules/core-principles.md" "$root/rules/core-principles.md" 2>/dev/null || \
            printf '# stub\n' > "$root/rules/core-principles.md"
        printf '#!/usr/bin/env bash\nprintf "resolve-session-id: node not found\\n" >&2\nexit %s\n' \
            "$1" > "$root/bin/resolve-session-id"
        chmod +x "$root/bin/resolve-session-id"
    fi
    printf '%s' "$root"
}

# fc_no_sid_run <root> — the loop with no --session-id at all, so the resolver
# is the only thing that can name the session. Sets FC_NRC / FC_NOUT.
fc_no_sid_run() {
    FC_NRC=0
    local errf="$TMPDIR_BASE/fc-nosid-err.txt"
    FC_NOUT="$(
        cd "$REPO" || exit 1
        export PATH="$FULL_PATH" HOME="$TMPDIR_BASE" AGENTS_CONFIG_DIR="$1"
        export CODEX_MOCK_PROMPT="$TMPDIR_BASE/fc-nosid-prompt.txt" \
               CODEX_MOCK_BODY="$NONE_BODY" CODEX_MOCK_EXIT=0
        env -u SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
            bash "$1/bin/run-codex-review-loop" --format "$LOOP_FORMAT" \
            --plans-dir "$PLANS" --cap 2 --max-extensions 0 --extensions-used 0 \
            --accepted-tradeoffs "$PLANS/tradeoffs.md" --repo-root "$REPO" 2>"$errf"
    )" || FC_NRC=$?
    FC_NOUT="$FC_NOUT$(cat "$errf" 2>/dev/null || true)"
}

{
    fc_env 9
    fc_shim none
    FC_RC_ROOT="$(fc_rc_root 127)"
    fc_no_sid_run "$FC_RC_ROOT"

    assert_eq "F9: a faulting resolver stops the round rather than guessing a session" \
        "nonzero" "$(nonzero_word "$FC_NRC")"
    FC_NAMED=no
    case "$FC_NOUT" in *127*|*session*) FC_NAMED=yes ;; esac
    assert_eq "F9: and the fault is named instead of reading as 'no session'" "yes" "$FC_NAMED"
    assert_eq "F9: the previous round's ledger is left exactly as it was" \
        "unchanged" "$(fc_ledger_state)"
    assert_eq "F9: no ledger is opened under a guessed session id" \
        "1" "$(find "$PLANS" -maxdepth 1 -name '*concern-ledger.txt' -type f 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "F9: and no artifact is written for the round it refused to start" \
        "missing" "$(file_state "$(json_file "$PLANS" "$SID")")"
}

{
    fc_env 10
    fc_shim none
    FC_RC_ROOT2="$(fc_rc_root 2)"
    fc_no_sid_run "$FC_RC_ROOT2"

    assert_eq "F10: rc 2 means 'no session', which is still not a reason to invent one" \
        "nonzero" "$(nonzero_word "$FC_NRC")"
    assert_eq "F10: nothing is staged under a session nobody named" \
        "0" "$(find "$PLANS" -maxdepth 1 -name '*round-1-delta-*' -type f 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "F10: the seeded ledger is untouched by the refusal" \
        "unchanged" "$(fc_ledger_state)"
    assert_eq "F10: the two resolver faults are refused the same way (CPR-ORTH)" \
        "both-nonzero" "$(if [ "$FC_NRC" -ne 0 ]; then printf 'both-nonzero'; else printf 'diverged'; fi)"
}
