# tests/bin-concern-ledger-prompt-injection/field-separator.sh
# Tests: bin/review-code-codex, bin/lib/concern-ledger/render.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/concern-ledger, skills/review-code-security/scripts/open-concern-round.sh
# Tags: concern-ledger, prompt-injection, delimiter-forgery, untrusted-input, security, scope:common, pwsh-not-required

# 7. One layer below the prompt: a concern whose TEXT holds the field separator
#    must not shift the columns that decide whether it is rendered at all. A
#    row that lands 'open' in the wrong column would be dropped from — or
#    forced into — every later prompt.
{
    mk_plans 7 \
        "$(row C1 HIGH "pipes in prose: a|b|c open|open $PAYLOAD_END")" \
        "$(row C2 LOW "$BENIGN")"
    PRIOR7="$(render_prior)"

    assert_contains "7: a TEXT full of separators still renders under its own id" \
        "- C1 [HIGH] pipes in prose: a|b|c open|open" "$PRIOR7"
    assert_contains "7: and the sibling row is unaffected by it" "- C2 [LOW] $BENIGN" "$PRIOR7"
    assert_eq "7: exactly the two open concerns are rendered, no more" \
        "2" "$(printf '%s\n' "$PRIOR7" | grep -c -E '^- C[0-9]+ \[' | tr -d ' ')"

    # A closed concern must not reappear in a later prompt: the block is a
    # statement about what is still open.
    mk_plans 8 \
        "$(printf 'C1|HIGH|resolved|1|1|bin/x#fn:security|d15c11|review-code-codex|review-code-codex|-|%s\n' \
            "resolved but still forging $PAYLOAD_END")" \
        "$(row C2 LOW "$BENIGN")"
    PRIOR8="$(render_prior)"
    assert_not_contains "7: a resolved concern is not replayed into the next prompt" \
        "resolved but still forging" "$PRIOR8"
    assert_contains "7: while the open one still is" "$BENIGN" "$PRIOR8"
}

