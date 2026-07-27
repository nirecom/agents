# tests/unit-quote-spans/query-options.sh
# Tests: hooks/lib/quote-spans/query.js, hooks/lib/quote-spans.js
# Tags: hook, quote-spans, parser, unit, query-opts, scope:common
#
# STATUS: RED until C1 lands — every row fails with
# `ERROR: require quote-spans.js: Cannot find module ...`.
#
# Sourced by tests/unit-quote-spans.sh (uses its assert_probe / run_table /
# assert_eq / probe helpers). Covers the `opts = { contexts,
# includeCmdSubstBody, onAmbiguous }` surface of the query API, RegExp pattern
# inputs (including a caller-supplied /g), and spanAwareNewlineSplit's
# trim + filter(Boolean) contract.

run_query_option_cases() {

    # ── contexts (default new Set(["unquoted"])) ─────────────────────────────
    # Input: "a rm" rm x
    #         0123456789...   dq body "a rm" spans 1..4, unquoted rm at 7.
    run_table <<'TABLE'
QO-ctx-default        |"a rm" rm x|findo|rm {}                                        |7
QO-ctx-explicit-unq   |"a rm" rm x|findo|rm {"contexts":["unquoted"]}                  |7
QO-ctx-dq-only        |"a rm" rm x|findo|rm {"contexts":["dq"]}                        |3
QO-ctx-both           |"a rm" rm x|findo|rm {"contexts":["unquoted","dq"]}             |3
QO-ctx-sq-only-miss   |"a rm" rm x|findo|rm {"contexts":["sq"]}                        |-1
QO-ctx-dq-test-true   |"a rm" x   |testo|rm {"contexts":["dq"]}                        |true
QO-ctx-dq-test-false  |'a rm' x   |testo|rm {"contexts":["dq"]}                        |false
QO-ctx-sq-test-true   |'a rm' x   |testo|rm {"contexts":["sq"]}                        |true
QO-ctx-ansic-true     |$'a rm' x  |testo|rm {"contexts":["ansic"]}                     |true
QO-ctx-ansic-not-sq   |$'a rm' x  |testo|rm {"contexts":["sq"]}                        |false
TABLE

    # ── includeCmdSubstBody (default true) ───────────────────────────────────
    # `$(rm)` — the body position is `unquoted` context but lives inside a
    # cmdsubst frame. Excluding the body must hide it.
    run_table <<'TABLE'
QO-body-default-true  |$(rm)          |findo|rm {}                                     |2
QO-body-explicit-true |$(rm)          |findo|rm {"includeCmdSubstBody":true}           |2
QO-body-false-hides   |$(rm)          |findo|rm {"includeCmdSubstBody":false}          |-1
QO-body-backtick-false|`rm`           |findo|rm {"includeCmdSubstBody":false}          |-1
QO-body-backtick-true |`rm`           |findo|rm {"includeCmdSubstBody":true}           |1
QO-body-subshell-false|(rm)           |findo|rm {"includeCmdSubstBody":false}          |-1
QO-body-subshell-true |(rm)           |findo|rm {"includeCmdSubstBody":true}           |1
QO-body-arith-false   |$((rm))        |findo|rm {"includeCmdSubstBody":false}          |-1
QO-body-arith-true    |$((rm))        |findo|rm {"includeCmdSubstBody":true}           |3
QO-body-outside-kept  |$(x) rm        |findo|rm {"includeCmdSubstBody":false}          |5
QO-body-test-false    |$(rm)          |testo|rm {"includeCmdSubstBody":false}          |false
QO-body-test-true     |$(rm)          |testo|rm {"includeCmdSubstBody":true}           |true
TABLE

    # ── onAmbiguous ("danger" default | "safe") ──────────────────────────────
    # Input is an unclosed dq: span resolution is ambiguous, so the predicate
    # API must answer on the danger side unless the caller opts out.
    run_table <<'TABLE'
QO-amb-default-test   |"unclosed rm   |testo|rm {}                                     |true
QO-amb-danger-test    |"unclosed rm   |testo|rm {"onAmbiguous":"danger"}               |true
QO-amb-safe-test      |"unclosed rm   |testo|rm {"onAmbiguous":"safe"}                 |false
QO-amb-default-find   |"unclosed rm   |findo|rm {}                                     |0
QO-amb-danger-find    |"unclosed rm   |findo|rm {"onAmbiguous":"danger"}               |0
QO-amb-safe-find      |"unclosed rm   |findo|rm {"onAmbiguous":"safe"}                 |-1
QO-amb-clean-unaffect |clean rm       |findo|rm {"onAmbiguous":"safe"}                 |6
QO-amb-clean-danger   |clean rm       |findo|rm {"onAmbiguous":"danger"}               |6
TABLE

    # ── RegExp pattern inputs ────────────────────────────────────────────────
    run_table <<'TABLE'
QO-re-literal         |"a rm" rm x    |findo|re:/rm/ {}                                |7
QO-re-charclass       |"a rm" rm x    |findo|re:/r[m]/ {}                              |7
QO-re-anchorless-alt  |a;b            |findo|re:/[;&]/ {}                              |1
QO-re-case-flag       |A RM b         |findo|re:/rm/i {}                               |2
QO-re-in-dq-ctx       |"a rm" rm x    |findo|re:/rm/ {"contexts":["dq"]}               |3
QO-re-no-match        |plain          |findo|re:/rm/ {}                                |-1
QO-str-metachar-lit   |a.b            |findo|. {}                                      |1
TABLE
    # A caller-supplied /g RegExp carries lastIndex state. Two consecutive calls
    # with the SAME object must agree, and the caller's object must come back
    # unmutated (the API re-adds `g` on an internal clone).
    assert_probe "QO-re-gflag-stateless"  '"a rm" rm x' gflag 're:/rm/g'  "first=7,second=7,lastIndex=0"
    assert_probe "QO-re-gyflag-stateless" '"a rm" rm x' gflag 're:/rm/gi' "first=7,second=7,lastIndex=0"
    assert_probe "QO-re-noflag-stateless" '"a rm" rm x' gflag 're:/rm/'   "first=7,second=7,lastIndex=0"

    # ── splitOutsideQuotes with opts ─────────────────────────────────────────
    assert_eq "QO-split-default-ctx" \
        'ok=true,parts=["a","\"b;c\"","d"]' \
        "$(probe splito 'a;"b;c";d' ';' '{}')"
    assert_eq "QO-split-body-excluded" \
        'ok=true,parts=["$(a;b)","c"]' \
        "$(probe splito '$(a;b);c' ';' '{"includeCmdSubstBody":false}')"
    assert_eq "QO-split-body-included" \
        'ok=true,parts=["$(a","b)","c"]' \
        "$(probe splito '$(a;b);c' ';' '{"includeCmdSubstBody":true}')"
    # Ambiguous input: split API is fail-closed regardless of onAmbiguous —
    # {ok:false, parts:[str]} is the single error contract for the split family.
    assert_eq "QO-split-ambiguous-danger" \
        'ok=false,parts=["a;\"unclosed"]' \
        "$(probe splito 'a;"unclosed' ';' '{"onAmbiguous":"danger"}')"
    assert_eq "QO-split-ambiguous-safe" \
        'ok=false,parts=["a;\"unclosed"]' \
        "$(probe splito 'a;"unclosed' ';' '{"onAmbiguous":"safe"}')"

    # ── string input vs precomputed ScanResult ───────────────────────────────
    # The query module is specified to accept EITHER a raw string OR a
    # ScanResult, so a caller that already scanned can reuse the result. Every
    # other row here passes a string, so the second half of that contract was
    # unexercised. `srsame` runs spanAt / quoteContextAt / findOutsideQuotes /
    # testOutsideQuotes / hasUnclosedQuoteSpan both ways and compares; the
    # `answers` half of the expectation keeps `same=true` from being vacuously
    # satisfied by two identically-broken (e.g. undefined) answers.
    # Fields: spanAt(i).kind|quoteContextAt(i)|findOutsideQuotes|test|hasUnclosed
    assert_probe "QO-sr-dq-position"   '"a rm" rm x' srsame '3 rm' \
        "same=true,answers=dq|dq|7|true|false"
    assert_probe "QO-sr-unq-position"  '"a rm" rm x' srsame '7 rm' \
        "same=true,answers=undefined|unquoted|7|true|false"
    assert_probe "QO-sr-sq-position"   "'a rm' rm x" srsame '3 rm' \
        "same=true,answers=sq|sq|7|true|false"
    assert_probe "QO-sr-ansic-position" "\$'a rm' x" srsame '4 rm' \
        "same=true,answers=ansic|ansic|-1|false|false"
    assert_probe "QO-sr-cmdsubst-body" '$(rm) x'    srsame '2 rm' \
        "same=true,answers=cmdsubst|unquoted|2|true|false"
    # ...and the ScanResult really is consumed rather than silently rescanned:
    # handed a result whose spans were emptied, the answers must follow the
    # RESULT (no span at 3), not the string it was derived from.
    assert_probe "QO-sr-doctored-not-rescanned" '"a rm" rm x' srdoctored '3' \
        "span=null,ctx=unquoted"

    # ── spanAwareNewlineSplit: trim + filter(Boolean), CRLF, blank runs ──────
    assert_eq "QO-nl-crlf-basic" \
        'ok=true,lines=["a","b"]' \
        "$(probe nlsplito "$(printf 'a\r\nb')" '{}')"
    assert_eq "QO-nl-repeated-blank" \
        'ok=true,lines=["a","b"]' \
        "$(probe nlsplito "$(printf 'a\n\n\n\nb')" '{}')"
    assert_eq "QO-nl-crlf-repeated-blank" \
        'ok=true,lines=["a","b"]' \
        "$(probe nlsplito "$(printf 'a\r\n\r\n\r\nb')" '{}')"
    assert_eq "QO-nl-trims-each-line" \
        'ok=true,lines=["a","b"]' \
        "$(probe nlsplito "$(printf '   a  \r\n\t b\t')" '{}')"
    assert_eq "QO-nl-whitespace-only-dropped" \
        'ok=true,lines=["a"]' \
        "$(probe nlsplito "$(printf 'a\n   \n\t\n')" '{}')"
    assert_eq "QO-nl-leading-and-trailing-blanks" \
        'ok=true,lines=["a"]' \
        "$(probe nlsplito "$(printf '\r\n\r\na\r\n\r\n')" '{}')"
    assert_eq "QO-nl-all-blank-empty-result" \
        'ok=true,lines=[]' \
        "$(probe nlsplito "$(printf '\r\n  \n\t\n')" '{}')"
    # A newline INSIDE a dq span is literal text, not a separator.
    assert_eq "QO-nl-dq-newline-not-a-separator" \
        'ok=true,lines=["\"a\nb\" c"]' \
        "$(probe nlsplito "$(printf '"a\nb" c')" '{}')"
    # ...and the trailing CRLF outside it still is.
    assert_eq "QO-nl-dq-newline-plus-real-break" \
        'ok=true,lines=["\"a\nb\"","c"]' \
        "$(probe nlsplito "$(printf '"a\nb"\r\nc')" '{}')"
    # Ambiguous input -> {ok:false, lines:[str]} (single error contract).
    assert_eq "QO-nl-ambiguous-fail-closed" \
        'ok=false,lines=["a\n\"unclosed"]' \
        "$(probe nlsplito "$(printf 'a\n"unclosed')" '{}')"
}
