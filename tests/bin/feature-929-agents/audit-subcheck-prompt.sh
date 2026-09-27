# audit-subcheck-prompt.sh — fragment of tests/bin/feature-929-agents.sh (no frontmatter).
# Source: bin/supervisor-findings-codex audit PROMPT construction (R3-C1).
# NOTE: RED until write-code creates bin/supervisor-findings-codex (#929); the
#   capturing codex shim is never invoked, so no prompt is captured and the
#   armed-sub-check / snapshot assertions fail.

# A codex shim that records the prompt (stdin) then emits a valid audit body, so
# the script reaches PERFORMED and we can inspect the constructed PROMPT. Prepend
# to the real PATH so node/git/timeout still resolve.
_asp_present_path() {
    local d="$TMPDIR_BASE/codex-present-shim"
    rm -rf "$d"; mkdir -p "$d"
    cat > "$d/codex" <<'SHIM'
#!/bin/bash
cap="${CODEX_PROMPT_CAPTURE:-/dev/null}"
cat > "$cap"
printf '%s\n' '{"verdict":"CONTINUE","summary":"stub audit verdict"}'
printf '%s\n' '{"categories":["workflow"],"severity":"notice","detail":"stub codex finding zeta"}'
SHIM
    chmod +x "$d/codex"
    local dp="$d"
    if command -v cygpath >/dev/null 2>&1; then dp="$(cygpath -u "$d")"; fi
    echo "$dp:$PATH"
}

_asp_run() {
    echo ""
    echo "--- audit-subcheck-prompt (R3-C1) ---"

    local tf="$TMPDIR_BASE/transcript-asp.jsonl"
    printf '{"type":"user","text":"stage boundary reached"}\n' > "$tf"
    local snap="$TMPDIR_BASE/asp-snapshot.json"
    printf '{"prior_findings":["prior-finding-sentinel-zeta"],"armed_run_id":"run-0001"}\n' > "$snap"
    local sid="sid-asp-$RANDOM$RANDOM"
    local pp; pp="$(_asp_present_path)"

    # With --subcheck (x2) + --state-snapshot: PROMPT embeds ids + snapshot.
    local cap1="$TMPDIR_BASE/asp-prompt-1.txt"
    CODEX_PROMPT_CAPTURE="$cap1" PATH="$pp" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR" \
        run_with_timeout 90 bash "$FINDINGS_CLI" --mode audit --sid "$sid" --wsid "$sid" \
        --transcript "$tf" --subcheck sc-alpha-01 --subcheck sc-beta-02 --state-snapshot "$snap" \
        >/dev/null 2>&1
    if [ -f "$cap1" ]; then
        local c1; c1="$(cat "$cap1")"
        assert_contains "asp: PROMPT embeds first armed sub-check id" "$c1" "sc-alpha-01"
        assert_contains "asp: PROMPT embeds second armed sub-check id" "$c1" "sc-beta-02"
        assert_contains "asp: PROMPT embeds snapshot prior-finding sentinel" "$c1" "prior-finding-sentinel-zeta"
    else
        fail "asp: audit PROMPT not captured with subcheck+snapshot (RED until findings-codex exists)"
    fi

    # Without --subcheck/--state-snapshot: those tokens must be absent.
    local cap2="$TMPDIR_BASE/asp-prompt-2.txt"
    CODEX_PROMPT_CAPTURE="$cap2" PATH="$pp" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR" \
        run_with_timeout 90 bash "$FINDINGS_CLI" --mode audit --sid "$sid" --wsid "$sid" \
        --transcript "$tf" \
        >/dev/null 2>&1
    if [ -f "$cap2" ]; then
        local c2; c2="$(cat "$cap2")"
        assert_not_contains "asp: bare audit PROMPT omits sub-check id" "$c2" "sc-alpha-01"
        assert_not_contains "asp: bare audit PROMPT omits snapshot sentinel" "$c2" "prior-finding-sentinel-zeta"
    else
        fail "asp: bare audit PROMPT not captured (RED until findings-codex exists)"
    fi
}

_asp_run
