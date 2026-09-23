# dual-id.sh — fragment of tests/feature-929-agents.sh (no frontmatter).
# Source: bin/supervisor-findings-codex ID resolution (--sid vs --wsid).
# NOTE: RED until write-code creates bin/supervisor-findings-codex (#929); no
#   prompt is captured, so the no-swap and UNAVAILABLE assertions fail.
# Reuses _asp_present_path (capturing codex shim) from audit-subcheck-prompt.sh,
# sourced earlier by the dispatcher.

_did_run() {
    echo ""
    echo "--- dual-id (--sid vs --wsid) ---"

    local sid="sid-did-$RANDOM$RANDOM"
    local wsid="wsid-did-$RANDOM$RANDOM"
    local tf="$TMPDIR_BASE/transcript-did.jsonl"
    printf '{"type":"user","text":"transcript-sentinel-tau"}\n' > "$tf"

    # Artifact resolved via wsid (passed explicitly) vs a sid-named decoy (never passed).
    local wsid_art="$WORKFLOW_PLANS_DIR/${wsid}-detail.md"
    printf 'detail plan body wsid-artifact-sentinel-omega\n' > "$wsid_art"
    local sid_decoy="$WORKFLOW_PLANS_DIR/${sid}-detail.md"
    printf 'decoy body sid-decoy-sentinel-kappa\n' > "$sid_decoy"

    local pp; pp="$(_asp_present_path)"

    # Case 1: different --sid/--wsid — wsid artifact embedded, sid decoy is not.
    local cap1="$TMPDIR_BASE/did-prompt-1.txt"
    CODEX_PROMPT_CAPTURE="$cap1" PATH="$pp" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR" \
        run_with_timeout 90 bash "$FINDINGS_CLI" --mode audit --sid "$sid" --wsid "$wsid" \
        --transcript "$tf" --artifact "$wsid_art" \
        >/dev/null 2>&1
    if [ -f "$cap1" ]; then
        local c1; c1="$(cat "$cap1")"
        assert_contains "did: transcript embedded (resolved via --sid session)" "$c1" "transcript-sentinel-tau"
        assert_contains "did: wsid-resolved artifact embedded" "$c1" "wsid-artifact-sentinel-omega"
        assert_not_contains "did: sid-named decoy artifact NOT slurped" "$c1" "sid-decoy-sentinel-kappa"
    else
        fail "did: prompt not captured for distinct sid/wsid (RED until findings-codex exists)"
    fi

    # Case 2: --wsid UNAVAILABLE + valid --sid — artifact ref skipped, still proceeds.
    local cap2="$TMPDIR_BASE/did-prompt-2.txt"
    CODEX_PROMPT_CAPTURE="$cap2" PATH="$pp" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR" \
        run_with_timeout 90 bash "$FINDINGS_CLI" --mode audit --sid "$sid" --wsid UNAVAILABLE \
        --transcript "$tf" \
        >/dev/null 2>&1
    if [ -f "$cap2" ]; then
        local c2; c2="$(cat "$cap2")"
        assert_contains "did: UNAVAILABLE wsid still builds prompt from --sid transcript" "$c2" "transcript-sentinel-tau"
    else
        fail "did: prompt not captured for --wsid UNAVAILABLE (RED until findings-codex exists)"
    fi
}

_did_run
