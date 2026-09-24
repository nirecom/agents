# tests/unit-quote-spans/fold-kinds.sh
# Tests: hooks/lib/quote-spans/transform.js, hooks/lib/quote-spans.js
# Tags: hook, quote-spans, transform, unit, fold, scope:common
#
# STATUS: RED until C1 lands — every row fails with
# `ERROR: require quote-spans.js: Cannot find module ...`.
#
# Sourced by tests/unit-quote-spans.sh (uses its assert_probe / run_table /
# assert_eq / probe helpers).
#
# foldNewlinesInSpans(str, kinds) takes a REQUIRED kinds selector. Nothing else
# in the suite exercised it, so a transform that ignored `kinds` and folded
# every newline (or only DQ ones, hard-coded) would have passed. The `mixed`
# fixture in tests/fixtures/quote-spans-probe.js carries exactly one newline in
# each of six contexts — dq, sq, ansic, cmdsubst body, backtick body, bare —
# so each selector below pins which single newline moves and, just as
# importantly, which five do not.
#
# Column note: the `want` values are JSON.stringify output, so `\n` is the two
# characters backslash-n (a newline that did NOT fold) and a literal space is a
# newline that did.

run_fold_kind_cases() {

    # ── kinds selector: exactly one context folds per row ────────────────────
    run_table <<'TABLE'
FK-dq-only     |mixed|foldfix|dq          |ok=true,out="p \"a b\" q 'c\nd' r $'e\nf' s $(echo g\nh) t `echo u\nv` w\nx"
FK-sq-only     |mixed|foldfix|sq          |ok=true,out="p \"a\nb\" q 'c d' r $'e\nf' s $(echo g\nh) t `echo u\nv` w\nx"
FK-ansic-only  |mixed|foldfix|ansic       |ok=true,out="p \"a\nb\" q 'c\nd' r $'e f' s $(echo g\nh) t `echo u\nv` w\nx"
FK-all-quotes  |mixed|foldfix|dq,sq,ansic |ok=true,out="p \"a b\" q 'c d' r $'e f' s $(echo g\nh) t `echo u\nv` w\nx"
FK-json-form   |mixed|foldfix|["dq"]      |ok=true,out="p \"a b\" q 'c\nd' r $'e\nf' s $(echo g\nh) t `echo u\nv` w\nx"
TABLE

    # ansic is NOT sq: $'e\nf' must be invisible to an sq-only selector, and
    # 'c\nd' invisible to an ansic-only selector. Both are pinned above by the
    # untouched neighbours, which is the whole point of the mixed fixture.

    # ── no quotes at all: nothing moves for any selector ─────────────────────
    run_table <<'TABLE'
FK-bare-dq     |bare|foldfix|dq          |ok=true,out="a\nb"
FK-bare-sq     |bare|foldfix|sq          |ok=true,out="a\nb"
FK-bare-all    |bare|foldfix|dq,sq,ansic |ok=true,out="a\nb"
TABLE

    # ── equivalence with the frozen implementation being replaced ────────────
    # The detail plan calls foldNewlinesInSpans(str, ["dq"]) the COMPLETE
    # replacement for worker-script.js's foldDqNewlines. `dqcmd` is the case
    # where a hand-written expectation would be guesswork (a newline inside a
    # $() that is itself inside the DQ span — "innermost span" and "any
    # enclosing span" readings disagree), so it is pinned against the frozen
    # behaviour instead of an invented constant.
    assert_probe "FK-vs-frozen-mixed" mixed foldvsold "" "same=true,ok=true"
    assert_probe "FK-vs-frozen-dqcmd" dqcmd foldvsold "" "same=true,ok=true"
    assert_probe "FK-vs-frozen-bare"  bare  foldvsold "" "same=true,ok=true"
}
