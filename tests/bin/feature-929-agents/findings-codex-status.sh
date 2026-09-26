# findings-codex-status.sh — fragment of tests/bin/feature-929-agents.sh (no frontmatter).
# Source: bin/supervisor-findings-codex (R3-C4). STATUS-channel + no-redirect contract.
# NOTE: RED until write-code creates bin/supervisor-findings-codex (#929); the file
#   is absent now, so every run yields empty stdout and these asserts fail.

# Run findings-codex with codex forced absent; capture stdout only (stderr dropped
# so a missing-file error does not masquerade as a STATUS line).
_fcs_run_absent() {
    local tf="$1"; shift
    PATH="$(codex_absent_path)" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR" \
        run_with_timeout 60 bash "$FINDINGS_CLI" "$@" 2>/dev/null
}

_fcs_run() {
    echo ""
    echo "--- findings-codex-status (R3-C4) ---"

    local tf="$TMPDIR_BASE/transcript-fcs.jsonl"
    printf '{"type":"user","text":"hello"}\n' > "$tf"
    local sid="sid-fcs-$RANDOM$RANDOM"

    # alert, codex absent -> STATUS: SKIPPED, first line, no OUTFILE.
    local out_alert line1_alert
    out_alert="$(_fcs_run_absent "$tf" --mode alert --sid "$sid" --wsid "$sid" --transcript "$tf")"
    line1_alert="${out_alert%%$'\n'*}"
    assert_eq "fcs: alert codex-absent STATUS line is first & SKIPPED" "STATUS: SKIPPED" "$line1_alert"
    assert_not_contains "fcs: alert codex-absent emits no OUTFILE" "$out_alert" "OUTFILE:"

    # audit, codex absent -> STATUS: SKIPPED, first line, no OUTFILE.
    local out_audit line1_audit
    out_audit="$(_fcs_run_absent "$tf" --mode audit --sid "$sid" --wsid "$sid" --transcript "$tf")"
    line1_audit="${out_audit%%$'\n'*}"
    assert_eq "fcs: audit codex-absent STATUS line is first & SKIPPED" "STATUS: SKIPPED" "$line1_audit"
    assert_not_contains "fcs: audit codex-absent emits no OUTFILE" "$out_audit" "OUTFILE:"

    # Invalid SID -> never SUCCESS, never OUTFILE (path-traversal guard).
    local out_bad
    out_bad="$(_fcs_run_absent "$tf" --mode alert --sid "bad/../sid" --wsid "$sid" --transcript "$tf")"
    assert_not_contains "fcs: invalid SID never yields STATUS: SUCCESS" "$out_bad" "STATUS: SUCCESS"
    assert_not_contains "fcs: invalid SID never yields OUTFILE" "$out_bad" "OUTFILE:"

    # Missing required --mode -> never SUCCESS, never OUTFILE.
    local out_nomode
    out_nomode="$(_fcs_run_absent "$tf" --sid "$sid" --wsid "$sid" --transcript "$tf")"
    assert_not_contains "fcs: missing --mode never yields STATUS: SUCCESS" "$out_nomode" "STATUS: SUCCESS"
    assert_not_contains "fcs: missing --mode never yields OUTFILE" "$out_nomode" "OUTFILE:"

    # --wsid UNAVAILABLE with a valid --sid still runs cleanly (codex-absent -> SKIPPED).
    local out_unavail line1_unavail
    out_unavail="$(_fcs_run_absent "$tf" --mode audit --sid "$sid" --wsid UNAVAILABLE --transcript "$tf")"
    line1_unavail="${out_unavail%%$'\n'*}"
    assert_eq "fcs: --wsid UNAVAILABLE codex-absent -> SKIPPED (artifact ref skipped)" "STATUS: SKIPPED" "$line1_unavail"
}

_fcs_run
