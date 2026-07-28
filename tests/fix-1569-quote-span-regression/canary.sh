# tests/fix-1569-quote-span-regression/canary.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/arg-tail-guard.js, hooks/lib/quote-spans.js
# Tags: hook, worktree, enforce, arg-tail, quote-spans, security, canary, scope:issue-specific
#
# STATUS: GREEN today and after C3 — this is a protection-fix negative
# assertion. Sourced by tests/fix-1569-quote-span-regression.sh.
#
# C8 / Protection Pattern 1. Every other attack row in this suite asserts a
# guard VERDICT. A verdict is a claim about the hook's answer, not about the
# world: a guard that blocks only after its write-target extractor has already
# opened, truncated or removed the file would still print `"decision":"block"`
# and every one of those rows would stay green. These rows put a canary file in
# the path each attack payload names and assert byte equality afterwards, so the
# assertion is about the filesystem rather than about the verdict text.
#
# The canary lives inside the throwaway fixture main worktree ($TMPDIR_BASE/repo,
# removed by the suite's EXIT trap) — never inside this repository. It has to be
# inside a REGISTERED repo: a write target outside every registered repo is out
# of the hook's scope, so the attack rows would be ALLOWed for reasons that have
# nothing to do with quote spans and the pairing would be vacuous.

run_canary_cases() {
    local canary="$MAIN_WT_RAW/canary.txt"
    printf 'CANARY-1569-INTACT\n' > "$canary"
    local before; before="$(cat "$canary")"

    # Command substitution — the grammar defect class the refactor fixes: the
    # old paren counter could terminate `$(` early and hide the write.
    assert_block "CANARY cmd-subst inside a DQ arg piece targeting the canary" \
        "bash \"$DISPATCH\" --title \"\$(rm -f canary.txt)\""
    assert_block "CANARY cmd-subst whose body hides a ')' in an SQ piece" \
        "bash \"$DISPATCH\" --title \"\$(printf ')'; rm -f canary.txt)\""
    assert_block "CANARY backtick substitution targeting the canary" \
        "bash \"$DISPATCH\" --title \"\`rm -f canary.txt\`\""
    assert_block "CANARY ANSI-C span followed by a substitution on the canary" \
        "bash \"$DISPATCH\" --title \$'a\\'b' \"\$(rm -f canary.txt)\""

    # Chaining — the other injection family.
    assert_block "CANARY semicolon chaining an rm of the canary" \
        "bash \"$DISPATCH\" --title a ; rm -f canary.txt"
    assert_block "CANARY && chaining a truncation of the canary" \
        "bash \"$DISPATCH\" --title a && : > canary.txt"
    assert_block "CANARY newline chaining an rm of the canary" \
        "bash \"$DISPATCH\" --title a${LF}rm -f canary.txt"
    assert_block "CANARY redirect overwriting the canary" \
        "bash \"$DISPATCH\" --title a > canary.txt"

    # The rule-5 ALLOW side of the same axis: a quoted metacharacter is inert
    # text, so it must be allowed AND must still leave the canary alone. Without
    # this row the canary check could be satisfied by a guard that blocks
    # everything.
    assert_allow "CANARY quoted metacharacters naming the canary are inert (rule 5)" \
        "bash \"$DISPATCH\" --title \"a;rm -f canary.txt|b\""

    if [ -f "$canary" ] && [ "$(cat "$canary")" = "$before" ]; then
        pass "CANARY protected file unchanged after every substitution/chaining attack"
    else
        fail "CANARY protected file was modified or removed while evaluating the attacks"
    fi
}
