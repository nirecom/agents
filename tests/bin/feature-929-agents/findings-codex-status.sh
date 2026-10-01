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
    printf '%s\n' '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"hello"},"uuid":"u1","timestamp":"2026-01-01T00:00:00Z"}' > "$tf"
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

    # #2475: codex present + nonexistent --transcript -> input assembly fails
    # before codex runs: STATUS: FAILED first, a reason: line, no OUTFILE.
    # Local shim: _asp_present_path is defined by a fragment sourced AFTER this one.
    local shim="$TMPDIR_BASE/fcs-codex-present-shim"
    rm -rf "$shim"; mkdir -p "$shim"
    printf '#!/bin/bash\ncat >/dev/null\n: > "${FCS_MOCK_CALLED:-/dev/null}"\nexit 0\n' > "$shim/codex"
    chmod +x "$shim/codex"
    local shim_posix="$shim"
    if command -v cygpath >/dev/null 2>&1; then shim_posix="$(cygpath -u "$shim")"; fi
    local called="$TMPDIR_BASE/fcs-mock-called"
    rm -f "$called"
    local out_asm line1_asm
    out_asm="$(FCS_MOCK_CALLED="$called" PATH="$shim_posix:$PATH" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR" \
        run_with_timeout 60 bash "$FINDINGS_CLI" --mode alert --sid "$sid" --wsid "$sid" \
        --transcript "$TMPDIR_BASE/no-such-transcript.jsonl" 2>/dev/null)"
    line1_asm="${out_asm%%$'\n'*}"
    assert_eq "fcs: missing transcript -> STATUS: FAILED first line (#2475)" "STATUS: FAILED" "$line1_asm"
    assert_contains "fcs: missing transcript -> reason: input assembly failed (#2475)" "$out_asm" "reason: input assembly failed"
    assert_not_contains "fcs: missing transcript emits no OUTFILE (#2475)" "$out_asm" "OUTFILE:"
    if [ -e "$called" ]; then
        fail "fcs: missing transcript must not invoke codex (#2475)"
    else
        pass "fcs: missing transcript does not invoke codex (#2475)"
    fi
}

_fcs_run
