# tests/fix-1569-quote-span-regression/rules-hook.sh
# Tests: hooks/enforce-worktree/arg-tail-guard.js, hooks/enforce-worktree.js, hooks/lib/quote-spans.js
# Tags: hook, worktree, enforce, arg-tail, quote-spans, security, regression, scope:issue-specific
#
# STATUS: the rule-5 ALLOW rows are RED until C3 lands (a quoted SET-A
# metacharacter still rejects the sanctioned fast path today); every BLOCK row
# is GREEN and must stay green. Sourced by
# tests/fix-1569-quote-span-regression.sh.
#
# rejectsUnsafeToken decision rules 1-6, observed through the real hook.

run_rule_hook_cases() {
    # ============================================================================
    # 8-13: rejectsUnsafeToken decision rules, driven through the sanctioned
    #       worker-script arg-tail guard.
    # ============================================================================

    # Every rule case below carries a WRITE (rm / tee / touch / >) so that ALLOW and
    # BLOCK are both observable at the hook boundary. The only thing that differs
    # between the R5 and R3 groups is whether the metacharacter sits inside a quote
    # span — that is exactly the #1569 fix.

    # Rule 5 (the #1569 fix): SET-A metacharacters inside dq/sq pieces are ALLOWED,
    # even when the quoted text also contains write-looking words.
    assert_allow "R5 mixed token foo\"|\"bar — pipe inside a DQ piece (rule 5)" \
        "bash \"$DISPATCH\" --title foo\"|\"bar"
    assert_allow "R5 \"a|tee out.txt\" — pipe + write word inside a DQ piece (rule 5)" \
        "bash \"$DISPATCH\" --title \"a|tee out.txt\""
    assert_allow "R5 'a;rm -rf README.md' — inside an SQ piece (rule 5)" \
        "bash \"$DISPATCH\" --title 'a;rm -rf README.md'"
    assert_allow "R5 \"a>b<c\" — redirect chars inside a DQ piece (rule 5)" \
        "bash \"$DISPATCH\" --title \"a>b<c\""

    # Rule 3: the same metacharacters UNQUOTED are a real shell boundary -> REJECT
    # the sanctioned fast path, so the injected repo write is seen and blocked.
    assert_block "R3 bare pipe into tee writing the repo (rule 3)" \
        "bash \"$DISPATCH\" | tee out.txt"
    assert_block "R3 bare semicolon then rm of a repo file (rule 3)" \
        "bash \"$DISPATCH\" --title a ; rm -rf README.md"
    assert_block "R3 bare && then touch of a repo file (rule 3)" \
        "bash \"$DISPATCH\" --title a && touch pwn.txt"
    assert_block "R3 bare > redirect into the repo (rule 3)" \
        "bash \"$DISPATCH\" --title a > out.txt"

    # Rule 4: command substitution is REJECTED even inside a DQ piece.
    assert_block "R4 \$( substitution inside a DQ piece (rule 4)" \
        "bash \"$DISPATCH\" --title \"\$(rm -rf README.md)\""
    assert_block "R4 backtick substitution inside a DQ piece (rule 4)" \
        "bash \"$DISPATCH\" --title \"\`rm -rf README.md\`\""
    assert_block "R4 unquoted \$( substitution (rule 4)" \
        "bash \"$DISPATCH\" --title \$(rm -rf README.md)"

    # Rule 1: unparseable arg tail (scan.ok === false) -> REJECT, fail-closed.
    assert_block "R1 unclosed DQ in the arg tail (rule 1)" \
        "bash \"$DISPATCH\" --title \"unclosed"
    assert_block "R1 unclosed SQ in the arg tail (rule 1)" \
        "bash \"$DISPATCH\" --title a|b'"

    # SKIPPED: a full-hook pin for rule 2 (any `ansic` piece in the arg tail ->
    #          REJECT the sanctioned fast path).
    # Because: rule 2 is pure fail-closed conservatism, not an attack surface —
    #          `$'...'` is a single shell word and cannot inject a second command.
    #          Rejecting the fast path therefore falls through to the standard
    #          classifier, which sees no write and allows, so ALLOW/BLOCK cannot
    #          distinguish rule 2 from rule 6 at this layer.
    # Covered at: tests/unit-quote-spans.sh (ansic span shape) and the `$'a|b'` /
    #          `$'unclosed string` corpus rows in tests/fixtures/quote-spans-corpus.txt.

    # ── Risk-2a: the new bare-'(' subshell frame must not make a quoted paren
    #    unparseable. An unbalanced '(' INSIDE a DQ piece is literal text: the
    #    scanner must stay ok:true and rule 5 must allow it. An unbalanced bare '('
    #    outside quotes must stay fail-closed.
    assert_allow "RISK2A unbalanced ( inside a DQ arg piece stays parseable (rule 5)" \
        "bash \"$DISPATCH\" --title \"release (v2 — rm old notes\""
    assert_allow "RISK2A balanced parens inside a DQ arg piece (rule 5)" \
        "bash \"$DISPATCH\" --title \"release (v2) — tee summary\""
    assert_block "RISK2A unbalanced bare ( wrapping a repo write is fail-closed (rule 1)" \
        "bash \"$DISPATCH\" (touch pwn.txt"
    assert_block "RISK2A balanced bare ( subshell wrapping a repo write (rule 3)" \
        "bash \"$DISPATCH\" ; (touch pwn.txt)"

}
