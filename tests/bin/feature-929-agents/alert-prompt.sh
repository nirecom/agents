# alert-prompt.sh — fragment of tests/bin/feature-929-agents.sh (no frontmatter).
# Source: bin/supervisor-findings-codex (alert mode; audit mode: audit-subcheck-prompt.sh).
# (#2730 / #2731 R3) A codex shim captures the alert PROMPT under CONV_LANG=japanese and
#   english: the free-text language line follows CONV_LANG, the allowed categories are
#   enumerated from the parser (SSOT), and a valid stub finding reaches STATUS: SUCCESS
#   with the finding in OUTFILE. State/plans pins come from the parent dispatcher.

_alp_run() {
    if [[ ! -f "$FINDINGS_CLI" ]]; then
        skip "alert-prompt: bin/supervisor-findings-codex not present"
        return
    fi

    local tmp shim shim_path tf body cats cat_list ja_line
    tmp="$(mktemp -d "$TMPDIR_BASE/alp.XXXXXX")"
    shim="$tmp/shim"
    mkdir -p "$shim"
    printf '%s\n' '#!/bin/bash' 'cat > "${CODEX_PROMPT_CAPTURE:-/dev/null}"' 'cat "$CODEX_STUB_BODY_FILE"' > "$shim/codex"
    chmod +x "$shim/codex"
    shim_path="$shim"
    if command -v cygpath >/dev/null 2>&1; then shim_path="$(cygpath -u "$shim")"; fi
    tf="$tmp/transcript.jsonl"
    printf '%s\n' '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"review the session"},"uuid":"u1","timestamp":"2026-01-01T00:00:00Z"}' > "$tf"
    body="$tmp/body.jsonl"
    printf '%s\n' '{"categories":["workflow"],"severity":"warning","detail":"alert stub finding omega"}' > "$body"

    cats="$(run_with_timeout 30 node "$PARSE_MODULE" --list-categories 2>/dev/null </dev/null | tr -d '\r' | grep -v '^$')"
    cat_list="$(printf '%s\n' "$cats" | paste -sd ',' - | sed 's/,/, /g')"
    ja_line="$(CONV_LANG=japanese run_with_timeout 30 node "$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/lib/lang-directive.js" --codex conv 2>/dev/null </dev/null | tr -d '\r')"

    local lang cap out prompt of c missing
    for lang in japanese english; do
        cap="$tmp/prompt-$lang.txt"
        out="$(unset CLAUDE_CODE_SESSION_ID
            CONV_LANG="$lang" NO_LOG=true \
            CODEX_STUB_BODY_FILE="$body" CODEX_PROMPT_CAPTURE="$cap" PATH="$shim_path:$PATH" \
            run_with_timeout 90 bash "$FINDINGS_CLI" --mode alert --sid "alp-$lang-$$" --wsid UNAVAILABLE \
            --transcript "$(to_node_path "$tf")" 2>/dev/null)"
        prompt=""
        [[ -f "$cap" ]] && prompt="$(tr -d '\r' < "$cap")"
        if [[ -z "$prompt" ]]; then
            fail "alert-prompt[$lang]: codex shim captured no prompt (out: $(printf '%s' "$out" | head -n 2 | tr '\n' ' '))"
            continue
        fi

        if [[ "$lang" == "japanese" ]]; then
            if [[ "$ja_line" == "Write every free-text field"*" in japanese."* && "$prompt" == *"$ja_line"* ]]; then
                pass "alert-prompt[japanese]: PROMPT carries the japanese CODEX_FREE_TEXT line"
            else
                fail "alert-prompt[japanese]: CODEX_FREE_TEXT line for japanese missing (line='$ja_line')"
            fi
        elif [[ "$prompt" == *"Write every free-text field"* ]]; then
            fail "alert-prompt[english]: CONV_LANG=english PROMPT must carry no free-text language line"
        else
            pass "alert-prompt[english]: PROMPT has no free-text language line (english is the no-op)"
        fi

        if [[ -z "$cats" ]]; then
            fail "alert-prompt[$lang]: --list-categories printed nothing"
        else
            missing=""
            for c in $cats; do
                [[ "$prompt" == *"Each \"categories\" value MUST be one of: "*"$c"* ]] || missing="$missing $c"
            done
            if [[ -z "$missing" && "$prompt" == *"Each \"categories\" value MUST be one of: ${cat_list}."* ]]; then
                pass "alert-prompt[$lang]: PROMPT enumerates every allowed category"
            else
                fail "alert-prompt[$lang]: category enumeration incomplete (missing:${missing:- none}; want '${cat_list}')"
            fi
        fi

        if [[ "$(printf '%s\n' "$out" | head -n 1)" != "STATUS: SUCCESS" ]]; then
            fail "alert-prompt[$lang]: valid stub finding must give STATUS: SUCCESS, got: $(printf '%s' "$out" | head -n 2 | tr '\n' ' ')"
            continue
        fi
        of="$(printf '%s\n' "$out" | sed -n 's/^OUTFILE: //p' | head -n 1)"
        if [[ -n "$of" && -f "$of" ]] && grep -q 'alert stub finding omega' "$of"; then
            pass "alert-prompt[$lang]: valid stub finding accepted into OUTFILE"
        else
            fail "alert-prompt[$lang]: OUTFILE missing or lacks the stub finding (OUTFILE='$of')"
        fi
        [[ -n "$of" ]] && rm -f "$of"
    done
    rm -rf "$tmp"
}

_alp_run
