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
    printf '%s\n' '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"stage boundary reached"},"uuid":"u1","timestamp":"2026-01-01T00:00:00Z"}' > "$tf"
    local snap="$TMPDIR_BASE/asp-snapshot.json"
    printf '{"prior_findings":["prior-finding-sentinel-zeta"],"armed_run_id":"run-0001"}\n' > "$snap"
    local sid="sid-asp-$RANDOM$RANDOM"
    local pp; pp="$(_asp_present_path)"

    # With --subcheck (x2) + --state-snapshot: PROMPT embeds ids + snapshot.
    local cap1="$TMPDIR_BASE/asp-prompt-1.txt"
    CODEX_PROMPT_CAPTURE="$cap1" PATH="$pp" \
        WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR" \
        run_with_timeout 90 bash "$FINDINGS_CLI" --mode audit --sid "$sid" --wsid "$sid" \
        --transcript "$tf" --subcheck sc-alpha-01 --subcheck sc-beta-02 --state-snapshot "$snap" \
        >/dev/null 2>&1
    if [ -f "$cap1" ]; then
        local c1; c1="$(cat "$cap1")"
        assert_contains "asp: PROMPT embeds first armed sub-check id" "$c1" "sc-alpha-01"
        assert_contains "asp: PROMPT embeds second armed sub-check id" "$c1" "sc-beta-02"
        assert_contains "asp: PROMPT embeds snapshot prior-finding sentinel" "$c1" "prior-finding-sentinel-zeta"
        # #2475: the snapshot is rendered inside the assembled SUPERVISOR STATE block.
        local state_block
        state_block="$(printf '%s\n' "$c1" | awk '/^\[SUPERVISOR STATE START\]$/{f=1;next} /^\[SUPERVISOR STATE END\]$/{f=0} f')"
        assert_contains "asp: snapshot sentinel sits inside [SUPERVISOR STATE] block (#2475)" "$state_block" "prior-finding-sentinel-zeta"
    else
        fail "asp: audit PROMPT not captured with subcheck+snapshot (RED until findings-codex exists)"
    fi

    # Without --subcheck/--state-snapshot: those tokens must be absent.
    local cap2="$TMPDIR_BASE/asp-prompt-2.txt"
    CODEX_PROMPT_CAPTURE="$cap2" PATH="$pp" \
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

# ── #2730 + #2731 R3: category enumeration, sub-check-in-detail rule, language line ─
# NOTE: RED until write-code adds --list-categories, the enumeration/sub-check lines and
#   the `conv` preamble argument; the SUCCESS/reject pair below is GREEN already (guard).

# Shim: records the prompt to CODEX_PROMPT_CAPTURE, then prints CODEX_STUB_BODY_FILE.
_asp_body_path() {
    local d="$TMPDIR_BASE/codex-body-shim"
    rm -rf "$d"; mkdir -p "$d"
    cat > "$d/codex" <<'SHIM'
#!/bin/bash
cat > "${CODEX_PROMPT_CAPTURE:-/dev/null}"
cat "$CODEX_STUB_BODY_FILE"
SHIM
    chmod +x "$d/codex"
    local dp="$d"
    if command -v cygpath >/dev/null 2>&1; then dp="$(cygpath -u "$d")"; fi
    echo "$dp:$PATH"
}

# _asp_audit <conv-lang> <body-file> <capture-file> — one armed audit run; prints CLI stdout.
_asp_audit() {
    CONV_LANG="$1" CODEX_STUB_BODY_FILE="$2" CODEX_PROMPT_CAPTURE="$3" PATH="$ASP_BODY_PATH" \
        WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR" \
        run_with_timeout 90 bash "$FINDINGS_CLI" --mode audit --sid "$ASP_SID" --wsid "$ASP_SID" \
        --transcript "$ASP_TF" --subcheck sc-alpha-01 2>/dev/null
}

_asp_categories_run() {
    echo ""
    echo "--- audit-category-prompt (#2730 / #2731 R3) ---"
    ASP_TF="$TMPDIR_BASE/transcript-acp.jsonl"
    printf '%s\n' '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"stage boundary reached"},"uuid":"u1","timestamp":"2026-01-01T00:00:00Z"}' > "$ASP_TF"
    ASP_SID="sid-acp-$RANDOM$RANDOM"
    ASP_BODY_PATH="$(_asp_body_path)"

    local ok_body="$TMPDIR_BASE/acp-body-ok.txt"
    printf '%s\n%s\n' '{"verdict":"CONTINUE","summary":"stages cohere"}' \
        '{"categories":["workflow"],"severity":"notice","detail":"sc-alpha-01: armed sub-check observed a gap"}' > "$ok_body"

    # The validator's accept set, read from the parser itself (SSOT).
    local cats cat_list cats_rc=0
    cats="$(run_with_timeout 30 node "$PARSE_MODULE" --list-categories 2>/dev/null </dev/null)" || cats_rc=$?
    [ "$cats_rc" -eq 0 ] || cats=""
    cats="$(printf '%s' "$cats" | tr -d '\r')"
    cat_list="$(printf '%s\n' "$cats" | grep -v '^$' | paste -sd ',' - | sed 's/,/, /g')"

    # Japanese: prompt enumerates categories, routes sub-check names to detail, carries the language line.
    local cap_ja="$TMPDIR_BASE/acp-prompt-ja.txt" out_ja
    out_ja="$(_asp_audit japanese "$ok_body" "$cap_ja")"
    local p_ja=""; [ -f "$cap_ja" ] && p_ja="$(tr -d '\r' < "$cap_ja")"
    if [ -z "$cats" ]; then
        fail "acp: --list-categories printed nothing (RED until #2730 lands)"
    else
        local c missing=""
        for c in $cats; do
            case "$p_ja" in *"\"$c\""*|*" $c,"*|*" $c."*|*": $c"*) ;; *) missing="$missing $c" ;; esac
        done
        assert_eq "acp: PROMPT names every --list-categories value" "" "$missing"
        assert_contains "acp: PROMPT carries the enumeration line" "$p_ja" "Each \"categories\" value MUST be one of: ${cat_list}."
    fi
    assert_contains "acp: PROMPT routes sub-check names into detail" "$p_ja" \
        'Never put an armed sub-check name or any other label into "categories"; name the sub-check inside "detail" instead.'
    # Enumeration and rule sit in the instruction part, before the untrusted-data blocks.
    local enum_ln data_ln
    enum_ln="$(printf '%s\n' "$p_ja" | grep -n 'MUST be one of:' | head -1 | cut -d: -f1)"
    data_ln="$(printf '%s\n' "$p_ja" | grep -n 'untrusted data' | head -1 | cut -d: -f1)"
    if [ -n "$enum_ln" ] && [ -n "$data_ln" ] && [ "$enum_ln" -lt "$data_ln" ]; then
        pass "acp: enumeration precedes the untrusted-data notice"
    else
        fail "acp: enumeration missing or after the untrusted-data notice (enum=${enum_ln:-none} data=${data_ln:-none})"
    fi
    local lang_line
    lang_line="$(CONV_LANG=japanese run_with_timeout 30 node "$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/lib/lang-directive.js" --codex conv 2>/dev/null </dev/null | tr -d '\r')"
    case "$lang_line" in
        "Write every free-text field"*japanese*) assert_contains "acp: CONV_LANG=japanese PROMPT carries the CODEX_FREE_TEXT line" "$p_ja" "$lang_line" ;;
        *) fail "acp: lang-directive.js --codex conv gave no CODEX_FREE_TEXT line for japanese (RED until S1/S4 land): '$lang_line'" ;;
    esac

    # Sub-check named in detail with a valid category -> SUCCESS, finding in OUTFILE.
    assert_eq "acp: sub-check in detail -> line 1 STATUS: SUCCESS" "STATUS: SUCCESS" "$(printf '%s\n' "$out_ja" | head -1)"
    local of; of="$(printf '%s\n' "$out_ja" | sed -n 's/^OUTFILE: //p' | head -1)"
    if [ -n "$of" ] && [ -f "$of" ]; then
        assert_contains "acp: OUTFILE holds the sub-check finding" "$(cat "$of")" "sc-alpha-01: armed sub-check observed a gap"
        rm -f "$of"
    else
        fail "acp: OUTFILE missing for the sub-check-in-detail audit"
    fi

    # English (noop): no CODEX_FREE_TEXT line; the enumeration stays (language-independent).
    local cap_en="$TMPDIR_BASE/acp-prompt-en.txt"
    _asp_audit english "$ok_body" "$cap_en" >/dev/null
    local p_en=""; [ -f "$cap_en" ] && p_en="$(tr -d '\r' < "$cap_en")"
    assert_not_contains "acp: CONV_LANG=english PROMPT has no free-text language line" "$p_en" "Write every free-text field"
    assert_contains "acp: CONV_LANG=english PROMPT still routes sub-check names into detail" "$p_en" 'name the sub-check inside "detail" instead.'

    # Control: the sub-check id as a category is still rejected (no remapping on the parse side).
    local bad_body="$TMPDIR_BASE/acp-body-bad.txt" out_bad
    printf '%s\n%s\n' '{"verdict":"CONTINUE","summary":"stages cohere"}' \
        '{"categories":["sc-alpha-01"],"severity":"notice","detail":"armed sub-check as a category"}' > "$bad_body"
    out_bad="$(_asp_audit english "$bad_body" /dev/null)"
    assert_eq "acp control: sub-check as category -> STATUS: FAILED" "STATUS: FAILED" "$(printf '%s\n' "$out_bad" | head -1)"
    assert_contains "acp control: reason names the unknown category" "$out_bad" "unknown-category:"
    assert_not_contains "acp control: no OUTFILE on rejection" "$out_bad" "OUTFILE:"
}
