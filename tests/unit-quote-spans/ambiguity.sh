# tests/unit-quote-spans/ambiguity.sh
# Tests: hooks/lib/quote-spans/scan.js, hooks/lib/quote-spans/query.js, hooks/lib/quote-spans/transform.js
# Tags: hook, quote-spans, parser, unit, fail-closed, security, scope:common
#
# STATUS: RED until C1 lands — every row fails with
# `ERROR: require quote-spans.js: Cannot find module ...`.
#
# Sourced by tests/unit-quote-spans.sh. The single error contract, applied to
# EVERY ambiguous frame kind — not just the three quote kinds:
#
#   predicate API -> danger side  (testOutsideQuotes true, findOutsideQuotes 0,
#                                  hasUnclosedQuoteSpan true for its kind set)
#   split API     -> { ok:false, parts/lines: [str] }
#   transform API -> { ok:false, out === str }
#
# The unclosed `$(`, backtick, bare `(` subshell and `$((` arith cases are the
# ones the new frame stack introduces; before #1569 no implementation tracked
# them at all, so they are the highest-risk direction of the refactor.

run_ambiguity_cases() {

    # ── scan-level shape of each ambiguous frame ─────────────────────────────
    run_table <<'TABLE'
AMB-dq-ok             |"unclosed        |ok       |            |false
AMB-dq-kinds          |"unclosed        |failkinds|            |dq
AMB-sq-ok             |'unclosed        |ok       |            |false
AMB-sq-kinds          |'unclosed        |failkinds|            |sq
AMB-ansic-ok          |$'unclosed       |ok       |            |false
AMB-ansic-kinds       |$'unclosed       |failkinds|            |ansic
AMB-cmdsubst-ok       |$(unclosed       |ok       |            |false
AMB-cmdsubst-kinds    |$(unclosed       |failkinds|            |cmdsubst
AMB-backtick-ok       |`unclosed        |ok       |            |false
AMB-backtick-kinds    |`unclosed        |failkinds|            |backtick
AMB-subshell-ok       |(unclosed        |ok       |            |false
AMB-subshell-kinds    |(unclosed        |failkinds|            |subshell
AMB-arith-ok          |$((1 + 2         |ok       |            |false
AMB-arith-kinds       |$((1 + 2         |failkinds|            |arith
AMB-arith-single-paren|$((1 + 2)        |ok       |            |false
AMB-nested-kinds      |$(echo "unclosed |failkinds|            |cmdsubst,dq
TABLE

    # ── predicate API: danger side for every ambiguous kind ──────────────────
    # The searched-for token sits AFTER the ambiguity, so a scanner that gave up
    # and returned "not found" would look identical to a clean miss — the
    # danger-side contract (find -> 0, test -> true) is what distinguishes them.
    run_table <<'TABLE'
AMB-pred-dq-test        |"unclosed rm    |test |rm |true
AMB-pred-dq-find        |"unclosed rm    |find |rm |0
AMB-pred-sq-test        |'unclosed rm    |test |rm |true
AMB-pred-sq-find        |'unclosed rm    |find |rm |0
AMB-pred-ansic-test     |$'unclosed rm   |test |rm |true
AMB-pred-ansic-find     |$'unclosed rm   |find |rm |0
AMB-pred-cmdsubst-test  |$(unclosed rm   |test |rm |true
AMB-pred-cmdsubst-find  |$(unclosed rm   |find |rm |0
AMB-pred-backtick-test  |`unclosed rm    |test |rm |true
AMB-pred-backtick-find  |`unclosed rm    |find |rm |0
AMB-pred-subshell-test  |(unclosed rm    |test |rm |true
AMB-pred-subshell-find  |(unclosed rm    |find |rm |0
AMB-pred-arith-test     |$((1 + rm       |test |rm |true
AMB-pred-arith-find     |$((1 + rm       |find |rm |0
TABLE

    # hasUnclosedQuoteSpan default kinds are ["dq","sq","ansic"] ONLY: the four
    # expanding frames must NOT be reported by the default call (Risk 1 / 2a —
    # otherwise every legitimate `$(...)`-bearing command becomes "unclosed").
    run_table <<'TABLE'
AMB-unc-dq-default        |"unclosed  |unclosed|                    |true
AMB-unc-sq-default        |'unclosed  |unclosed|                    |true
AMB-unc-ansic-default     |$'unclosed |unclosed|                    |true
AMB-unc-cmdsubst-default  |$(unclosed |unclosed|                    |false
AMB-unc-backtick-default  |`unclosed  |unclosed|                    |false
AMB-unc-subshell-default  |(unclosed  |unclosed|                    |false
AMB-unc-arith-default     |$((1 + 2   |unclosed|                    |false
AMB-unc-cmdsubst-asked    |$(unclosed |unclosed|cmdsubst            |true
AMB-unc-backtick-asked    |`unclosed  |unclosed|backtick            |true
AMB-unc-subshell-asked    |(unclosed  |unclosed|subshell            |true
AMB-unc-arith-asked       |$((1 + 2   |unclosed|arith               |true
AMB-unc-cmdsubst-wrongset |$(unclosed |unclosed|dq,sq,ansic         |false
AMB-unc-closed-all-false  |$(echo "a")|unclosed|dq,sq,ansic,cmdsubst|false
TABLE

    # ── split API: { ok:false, parts/lines:[str] } for every ambiguous kind ───
    run_table <<'TABLE'
AMB-split-dq        |a;"unclosed    |split|;|ok=false,n=1,first_is_input=true
AMB-split-sq        |a;'unclosed    |split|;|ok=false,n=1,first_is_input=true
AMB-split-ansic     |a;$'unclosed   |split|;|ok=false,n=1,first_is_input=true
AMB-split-cmdsubst  |a;$(unclosed   |split|;|ok=false,n=1,first_is_input=true
AMB-split-backtick  |a;`unclosed    |split|;|ok=false,n=1,first_is_input=true
AMB-split-subshell  |a;(unclosed    |split|;|ok=false,n=1,first_is_input=true
AMB-split-arith     |a;$((1 + 2     |split|;|ok=false,n=1,first_is_input=true
TABLE
    assert_eq "AMB-nlsplit-cmdsubst" 'ok=false,lines=["a\n$(unclosed"]' \
        "$(probe nlsplito "$(printf 'a\n$(unclosed')" '{}')"
    assert_eq "AMB-nlsplit-backtick" 'ok=false,lines=["a\n`unclosed"]' \
        "$(probe nlsplito "$(printf 'a\n`unclosed')" '{}')"
    assert_eq "AMB-nlsplit-subshell" 'ok=false,lines=["a\n(unclosed"]' \
        "$(probe nlsplito "$(printf 'a\n(unclosed')" '{}')"
    assert_eq "AMB-nlsplit-arith" 'ok=false,lines=["a\n$((1 + 2"]' \
        "$(probe nlsplito "$(printf 'a\n$((1 + 2')" '{}')"

    # ── transform API: { ok:false, out === str } for every ambiguous kind ─────
    run_table <<'TABLE'
AMB-tr-blank-dq        |a "unclosed  |transform|blank |ok=false,unchanged=true
AMB-tr-blank-sq        |a 'unclosed  |transform|blank |ok=false,unchanged=true
AMB-tr-blank-ansic     |a $'unclosed |transform|blank |ok=false,unchanged=true
AMB-tr-blank-cmdsubst  |a $(unclosed |transform|blank |ok=false,unchanged=true
AMB-tr-blank-backtick  |a `unclosed  |transform|blank |ok=false,unchanged=true
AMB-tr-blank-subshell  |a (unclosed  |transform|blank |ok=false,unchanged=true
AMB-tr-blank-arith     |a $((1 + 2   |transform|blank |ok=false,unchanged=true
AMB-tr-fold-cmdsubst   |a $(unclosed |transform|fold  |ok=false,unchanged=true
AMB-tr-fold-backtick   |a `unclosed  |transform|fold  |ok=false,unchanged=true
AMB-tr-fold-subshell   |a (unclosed  |transform|fold  |ok=false,unchanged=true
AMB-tr-fold-arith      |a $((1 + 2   |transform|fold  |ok=false,unchanged=true
AMB-tr-unwrap-cmdsubst |a $(unclosed |transform|unwrap|ok=false,unchanged=true
AMB-tr-unwrap-backtick |a `unclosed  |transform|unwrap|ok=false,unchanged=true
AMB-tr-unwrap-subshell |a (unclosed  |transform|unwrap|ok=false,unchanged=true
AMB-tr-unwrap-arith    |a $((1 + 2   |transform|unwrap|ok=false,unchanged=true
TABLE

    # Anti-vacuity: the SAME shapes, closed, must be ok:true so the rows above
    # cannot pass by a blanket ok:false.
    run_table <<'TABLE'
AMB-anti-cmdsubst-ok   |a $(closed)     |ok       |      |true
AMB-anti-backtick-ok   |a `closed`      |ok       |      |true
AMB-anti-subshell-ok   |a (closed)      |ok       |      |true
AMB-anti-arith-ok      |a $((1 + 2))    |ok       |      |true
AMB-anti-split-ok      |a;$(b);c        |split    |;     |ok=true,n=3,first_is_input=false
AMB-anti-blank-ok      |a "q"           |transform|blank |ok=true,unchanged=false
AMB-anti-unwrap-ok     |a "$(b)"        |transform|unwrap|ok=true,unchanged=false
TABLE
}
