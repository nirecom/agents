# tests/unit-quote-spans/structure.sh
# Tests: hooks/lib/quote-spans/scan.js
# Tags: hook, quote-spans, parser, unit, scope:common
#
# STATUS: RED until C1 lands. Sourced by tests/unit-quote-spans.sh (harness,
# assert_eq, probe, run_table are defined there).
#
# Span-structure pins for scanSpans():
#   - the MANDATORY 14-case table from the #1569 plan (S1..S14)
#   - per-kind shape pins (expands / closed / depth / parent / inner offsets)
#   - flat-array-in-start-order pin
#
# Column format for run_table: name|input|op|args|want
# `@LEN` in the want column means "character length of the input" — used to pin
# a span's exclusive `end` at end-of-string without hardcoding an offset.

run_structure_cases() {

# ---------------------------------------------------------------------------
# Per-kind shape pins: kind detection, expands flag, inner offsets, closed.
# ---------------------------------------------------------------------------
run_table <<'TABLE'
K-dq-count        | "abc"   | count     | dq            | 1
K-dq-expands      | "abc"   | spanfield | dq 0 expands  | true
K-dq-inner        | "abc"   | innertext | dq 0          | abc
K-dq-end          | "abc"   | spanfield | dq 0 end      | @LEN
K-dq-closed       | "abc"   | spanfield | dq 0 closed   | true
K-dq-depth        | "abc"   | spanfield | dq 0 depth    | 0
K-dq-parent       | "abc"   | parentkind| dq 0          | null
K-dq-unclosed     | "abc    | spanfield | dq 0 closed   | false
K-sq-count        | 'abc'   | count     | sq            | 1
K-sq-expands      | 'abc'   | spanfield | sq 0 expands  | false
K-sq-inner        | 'abc'   | innertext | sq 0          | abc
K-sq-backslash-literal | 'a\'  | count   | sq            | 1
K-ansic-count     | $'abc'  | count     | ansic         | 1
K-ansic-expands   | $'abc'  | spanfield | ansic 0 expands | false
K-ansic-inner     | $'abc'  | innertext | ansic 0       | abc
K-ansic-esc-quote | $'\''   | count     | ansic         | 1
K-ansic-esc-ok    | $'\''   | ok        |               | true
K-ansic-esc-end   | $'\''   | spanfield | ansic 0 end   | @LEN
K-cmdsubst-count  | $(a)    | count     | cmdsubst      | 1
K-cmdsubst-expands| $(a)    | spanfield | cmdsubst 0 expands | true
K-cmdsubst-inner  | $(a)    | innertext | cmdsubst 0    | a
K-backtick-count  | `a`     | count     | backtick      | 1
K-backtick-expands| `a`     | spanfield | backtick 0 expands | true
K-subshell-count  | (a)     | count     | subshell      | 1
K-subshell-expands| (a)     | spanfield | subshell 0 expands | true
K-arith-count     | $((1))  | count     | arith         | 1
K-arith-expands   | $((1))  | spanfield | arith 0 expands | true
K-arith-not-cmdsubst | $((1)) | count   | cmdsubst      | 0
K-arith-end       | $((1))  | spanfield | arith 0 end   | @LEN
TABLE

# Flat array, start order, sq/dq/cmdsubst side by side.
run_table <<'TABLE'
K-flat-order      | "a" 'b' $(c) | kinds |    | dq,sq,cmdsubst
K-flat-count      | "a" 'b' $(c) | count | *  | 3
TABLE

# Backtick is NON-nestable: the second ` closes the first span, the third opens
# a new (unclosed) one.
run_table <<'TABLE'
K-backtick-nonnest-count | `a`b` | count     | backtick | 2
K-backtick-nonnest-ok    | `a`b` | ok        |          | false
K-backtick-nonnest-kinds | `a`b` | failkinds |          | backtick
TABLE

# ---------------------------------------------------------------------------
# MANDATORY 14-case table (S1..S14) — the #1569 plan's structural contract.
# ---------------------------------------------------------------------------

# S1: cmdsubst closes at the FINAL ) — the ) inside the SQ is literal, so
# `rm -rf x` stays inside the cmdsubst body (this is the whole point of the
# refactor: a naive first-) scan would expose it as top-level text).
run_table <<'TABLE'
S1-cmdsubst-count | $(printf ')'; rm -rf x) | count     | cmdsubst   | 1
S1-sq-count       | $(printf ')'; rm -rf x) | count     | sq         | 1
S1-cmdsubst-end   | $(printf ')'; rm -rf x) | spanfield | cmdsubst 0 end | @LEN
S1-cmdsubst-inner | $(printf ')'; rm -rf x) | innertext | cmdsubst 0 | printf ')'; rm -rf x
S1-rm-is-inside   | $(printf ')'; rm -rf x) | spanatkind| 14         | cmdsubst
S1-ok             | $(printf ')'; rm -rf x) | ok        |            | true
TABLE

# S2: ) inside a DQ span does not close the cmdsubst.
run_table <<'TABLE'
S2-cmdsubst-count | $(echo "a)b") | count     | cmdsubst       | 1
S2-dq-count       | $(echo "a)b") | count     | dq             | 1
S2-cmdsubst-end   | $(echo "a)b") | spanfield | cmdsubst 0 end | @LEN
S2-ok             | $(echo "a)b") | ok        |                | true
TABLE

# S3 (the mandatory case 3): `$(echo $'a\')b')`.
#
#   index: 0 $  1 (  2 e 3 c 4 h 5 o  6 ␠  7 $  8 '  9 a  10 \  11 '  12 )
#         13 b  14 ' 15 )                                        len = 16
#
# Inside an `ansic` frame a backslash skips 2 characters, so the `'` at 11 is
# LITERAL — it neither terminates the ANSI-C span nor lets the `)` at 12 escape
# into the cmdsubst frame. The ANSI-C span therefore closes at the `'` at 14,
# and only then does the `)` at 15 close the command substitution, at
# end-of-string. This is the #1457 root cause: a scanner that treats `\'` as a
# terminator closes the ANSI-C span at 11, sees the `)` at 12 as the end of the
# substitution, and leaves `b')` as live unquoted text — which is exactly the
# position an injected payload wants to occupy.
#
# `depth` is 0-based with 0 = outermost (spec: "`depth` = 0 が最外"). The ANSI-C
# span's only ancestor is the cmdsubst at depth 0, so its depth is 1 — pinned
# together with S3-ansic-parent, which names that ancestor.
run_table <<'TABLE'
S3-ok               | $(echo $'a\')b') | ok        |                  | true
S3-cmdsubst-count   | $(echo $'a\')b') | count     | cmdsubst         | 1
S3-ansic-count      | $(echo $'a\')b') | count     | ansic            | 1
S3-sq-count         | $(echo $'a\')b') | count     | sq               | 0
S3-cmdsubst-end     | $(echo $'a\')b') | spanfield | cmdsubst 0 end   | @LEN
S3-cmdsubst-start   | $(echo $'a\')b') | spanfield | cmdsubst 0 start | 0
S3-ansic-start      | $(echo $'a\')b') | spanfield | ansic 0 start    | 7
S3-ansic-end        | $(echo $'a\')b') | spanfield | ansic 0 end      | 15
S3-ansic-inner      | $(echo $'a\')b') | innertext | ansic 0          | a\')b
S3-ansic-parent     | $(echo $'a\')b') | parentkind| ansic 0          | cmdsubst
S3-ansic-depth      | $(echo $'a\')b') | spanfield | ansic 0 depth    | 1
S3-ansic-no-expand  | $(echo $'a\')b') | spanfield | ansic 0 expands  | false
S3-kinds-order      | $(echo $'a\')b') | kinds     |                  | cmdsubst,ansic
TABLE
# The escaped quote must not become a context boundary either: every index from
# 9 to 13 is still inside the ANSI-C span, including the `'` at 11 and the `)`
# at 12 that a naive scanner would treat as structure.
run_table <<'TABLE'
S3-ctx-at-9  | $(echo $'a\')b') | ctxat | 9  | ansic
S3-ctx-at-10 | $(echo $'a\')b') | ctxat | 10 | ansic
S3-ctx-at-11 | $(echo $'a\')b') | ctxat | 11 | ansic
S3-ctx-at-12 | $(echo $'a\')b') | ctxat | 12 | ansic
S3-ctx-at-13 | $(echo $'a\')b') | ctxat | 13 | ansic
S3-ctx-at-15 | $(echo $'a\')b') | ctxat | 15 | unquoted
TABLE

# S3b: the SAME shape without the `$` prefix. Here `\'` is an ordinary
# unquoted backslash-escape (skip 2), so the cmdsubst closes at offset 10 and
# the trailing `'` opens an UNCLOSED sq span; the `)` inside it closes nothing.
# (bash agrees: it reports an unterminated quoted string.) Keeping both shapes
# proves the `$'` prefix is what selects the ANSI-C rule — a scanner that
# ignored the prefix would have to fail one of the two blocks.
run_table <<'TABLE'
S3b-cmdsubst-count | $(echo a\')b') | count     | cmdsubst       | 1
S3b-sq-count       | $(echo a\')b') | count     | sq             | 1
S3b-cmdsubst-end   | $(echo a\')b') | spanfield | cmdsubst 0 end | 11
S3b-ok             | $(echo a\')b') | ok        |                | false
S3b-failkinds      | $(echo a\')b') | failkinds |                | sq
TABLE

# S4: nested cmdsubst with an SQ containing ) — inner cmdsubst closes first.
run_table <<'TABLE'
S4-cmdsubst-count | $(a $(b ')') c) | count     | cmdsubst       | 2
S4-sq-count       | $(a $(b ')') c) | count     | sq             | 1
S4-outer-end      | $(a $(b ')') c) | spanfield | cmdsubst 0 end | @LEN
S4-inner-end      | $(a $(b ')') c) | spanfield | cmdsubst 1 end | 12
S4-sq-parent      | $(a $(b ')') c) | parentkind| sq 0           | cmdsubst
S4-sq-depth       | $(a $(b ')') c) | spanfield | sq 0 depth     | 2
S4-ok             | $(a $(b ')') c) | ok        |                | true
TABLE

# S5: escaped ) does not close the cmdsubst.
run_table <<'TABLE'
S5-cmdsubst-count | $(cmd \)) | count     | cmdsubst       | 1
S5-cmdsubst-end   | $(cmd \)) | spanfield | cmdsubst 0 end | @LEN
S5-ok             | $(cmd \)) | ok        |                | true
TABLE

# S6: dq > cmdsubst > sq nesting — the " inside the SQ is literal.
run_table <<'TABLE'
S6-dq-count       | "$(printf '"')" | count     | dq         | 1
S6-cmdsubst-count | "$(printf '"')" | count     | cmdsubst   | 1
S6-sq-count       | "$(printf '"')" | count     | sq         | 1
S6-dq-end         | "$(printf '"')" | spanfield | dq 0 end   | @LEN
S6-sq-depth       | "$(printf '"')" | spanfield | sq 0 depth | 2
S6-ok             | "$(printf '"')" | ok        |            | true
TABLE

# S7: unclosed cmdsubst (the SQ inside is balanced) → ok:false.
run_table <<'TABLE'
S7-ok             | $(printf ')' | ok        |    | false
S7-failkinds      | $(printf ')' | failkinds |    | cmdsubst
S7-sq-count       | $(printf ')' | count     | sq | 1
TABLE

# S8: a ' inside a DQ span is literal — exactly one dq span, zero sq spans.
run_table <<'TABLE'
S8-dq-count       | "a'b" | count | dq | 1
S8-sq-count       | "a'b" | count | sq | 0
S8-ok             | "a'b" | ok    |    | true
TABLE

# S9: backtick span nested inside a cmdsubst.
run_table <<'TABLE'
S9-cmdsubst-count | $(echo `date`) | count     | cmdsubst  | 1
S9-backtick-count | $(echo `date`) | count     | backtick  | 1
S9-backtick-parent| $(echo `date`) | parentkind| backtick 0| cmdsubst
S9-ok             | $(echo `date`) | ok        |           | true
TABLE

# S10 (Risk-2a): a BARE ( inside a cmdsubst pushes a subshell frame, so the
# subshell's ) does NOT close the cmdsubst. `rm -rf y` therefore remains inside
# the cmdsubst body rather than being exposed as top-level text.
run_table <<'TABLE'
S10-subshell-count | $( (echo x); rm -rf y ) | count     | subshell       | 1
S10-cmdsubst-count | $( (echo x); rm -rf y ) | count     | cmdsubst       | 1
S10-cmdsubst-end   | $( (echo x); rm -rf y ) | spanfield | cmdsubst 0 end | @LEN
S10-rm-is-inside   | $( (echo x); rm -rf y ) | spanatkind| 13             | cmdsubst
S10-ok             | $( (echo x); rm -rf y ) | ok        |                | true
TABLE

# S11: subshell inside an if/then body — cmdsubst end lands at end-of-string.
run_table <<'TABLE'
S11-subshell-count | $(if [ -f a ]; then (b; c); fi) | count     | subshell       | 1
S11-cmdsubst-count | $(if [ -f a ]; then (b; c); fi) | count     | cmdsubst       | 1
S11-cmdsubst-end   | $(if [ -f a ]; then (b; c); fi) | spanfield | cmdsubst 0 end | @LEN
S11-ok             | $(if [ -f a ]; then (b; c); fi) | ok        |                | true
TABLE

# S12: $(( matched before $( (longest match); arith pops only on )).
run_table <<'TABLE'
S12-arith-count    | $(( 1 + (2 * 3) )) | count     | arith       | 1
S12-subshell-count | $(( 1 + (2 * 3) )) | count     | subshell    | 1
S12-cmdsubst-count | $(( 1 + (2 * 3) )) | count     | cmdsubst    | 0
S12-arith-end      | $(( 1 + (2 * 3) )) | spanfield | arith 0 end | @LEN
S12-ok             | $(( 1 + (2 * 3) )) | ok        |             | true
TABLE

# S13: a bare ( at top level is a subshell frame, but a subshell body is NOT a
# quote context — quoteContextAt is "unquoted" at every offset.
run_table <<'TABLE'
S13-subshell-count | echo (a) | count  | subshell | 1
S13-ctxset         | echo (a) | ctxset |          | unquoted
S13-ok             | echo (a) | ok     |          | true
TABLE

# S14: the inner subshell closed, the outer cmdsubst did not — failKinds must
# list ONLY the frames still on the stack at EOF.
run_table <<'TABLE'
S14-ok             | $( (echo x) | ok        |          | false
S14-failkinds      | $( (echo x) | failkinds |          | cmdsubst
S14-subshell-count | $( (echo x) | count     | subshell | 1
TABLE

}
