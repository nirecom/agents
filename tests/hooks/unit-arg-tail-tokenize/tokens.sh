# tests/unit-arg-tail-tokenize/tokens.sh
# Tests: hooks/enforce-worktree/arg-tail-guard.js, hooks/lib/quote-spans.js
# Tags: hook, worktree, enforce, arg-tail, parser, unit, scope:common
#
# STATUS: RED until C3 lands — every row fails with
# `ERROR: require arg-tail-guard.js: Cannot find module ...`.
#
# Sourced by tests/unit-arg-tail-tokenize.sh (uses its probe / assert_probe /
# assert_eq / run_table helpers, and its `%` column separator).
# Sections 1-7: word splitting, quoted words, mixed provenance, escapes,
# substitution bodies, ANSI-C, and the fail-closed malformed contract.

run_tokenize_shape_cases() {

# ============================================================================
# 1. Word splitting and token bounds
#
#    `--title foo`  →  0-7, 8-13
#     0123456789...
# ============================================================================
run_table <<'TABLE'
TK-plain-ok            %--title foo%ok    %%true
TK-plain-n             %--title foo%n     %%2
TK-plain-bounds        %--title foo%bounds%%0-7,8-11
TK-plain-raws          %--title foo%raws  %%["--title","foo"]
TK-plain-values        %--title foo%values%%["--title","foo"]
TK-plain-cover         %--title foo%cover %%ok
TK-runs-of-space-n     %--title   a%n     %%2
TK-runs-of-space-bnds  %--title   a%bounds%%0-7,10-11
TK-leading-ws-bounds   % --title a%bounds %%1-8,9-10
TK-tab-separated-n     %--title	a%n       %%2
TK-empty-ok            %%ok               %%true
TK-empty-n             %%n                %%0
TK-ws-only-ok          %   %ok            %%true
TK-ws-only-n           %   %n             %%0
TABLE

# ============================================================================
# 2. Quoted words: delimiters belong to the piece, value has them stripped
#
#    `--title "a b"`  token1 = [9,14)  piece dq@9-14:"a b"  value `a b`
#     0123456789
# ============================================================================
run_table <<'TABLE'
TK-dq-ws-n             %--title "a b"%n         %%2
TK-dq-ws-bounds        %--title "a b"%bounds    %%0-7,8-13
TK-dq-ws-raw           %--title "a b"%tok       %1 raw%"a b"
TK-dq-ws-value         %--title "a b"%tok       %1 value%a b
TK-dq-ws-pieces        %--title "a b"%pieces    %1%dq@8-13:"a b"
TK-dq-ws-cover         %--title "a b"%cover     %%ok
TK-sq-ws-n             %--title 'a b'%n         %%2
TK-sq-ws-value         %--title 'a b'%tok       %1 value%a b
TK-sq-ws-pieces        %--title 'a b'%pieces    %1%sq@8-13:'a b'
TK-sq-ws-cover         %--title 'a b'%cover     %%ok
TK-dq-empty-value      %--title ""%tok          %1 value%
TK-dq-empty-raw        %--title ""%tok          %1 raw%""
TK-dq-empty-n          %--title ""%n            %%2
TK-sq-empty-n          %--title ''%n            %%2
TABLE

# ============================================================================
# 3. Mixed provenance inside ONE shell word — the reason the old
#    {value, quoted, kind} 3-tuple contract was discarded.
#
#    `--title foo"|"bar`   f=8 o=9 o=10 "=11 |=12 "=13 b=14 a=15 r=16
# ============================================================================
run_table <<'TABLE'
TK-mixed-n             %--title foo"|"bar%n        %%2
TK-mixed-bounds        %--title foo"|"bar%bounds   %%0-7,8-17
TK-mixed-raw           %--title foo"|"bar%tok      %1 raw%foo"|"bar
TK-mixed-value         %--title foo"|"bar%tok      %1 value%foo|bar
TK-mixed-piecekinds    %--title foo"|"bar%piecekinds%1%unquoted,dq,unquoted
TK-mixed-pieces        %--title foo"|"bar%pieces   %1%unquoted@8-11:foo,dq@11-14:"|",unquoted@14-17:bar
TK-mixed-cover         %--title foo"|"bar%cover    %%ok
TK-adjacent-dq-sq-val  %--title "a"'b'%tok         %1 value%ab
TK-adjacent-dq-sq-pcs  %--title "a"'b'%pieces      %1%dq@8-11:"a",sq@11-14:'b'
TK-adjacent-cover      %--title "a"'b'%cover       %%ok
TK-quoted-then-space-n %--title "a"b c%n           %%3
TK-quoted-then-space-b %--title "a"b c%bounds      %%0-7,8-12,13-14
TABLE

# ============================================================================
# 4. Escapes. Unquoted `\X` resolves to `X`; sq resolves nothing; dq resolves
#    only \" \\ \` \$.
# ============================================================================
run_table <<'TABLE'
TK-unq-esc-dq-value    %--title a\"b%tok    %1 value%a"b
TK-unq-esc-dq-piece    %--title a\"b%piecekinds%1%unquoted
TK-unq-esc-bs-value    %--title a\\b%tok    %1 value%a\b
TK-dq-esc-dq-value     %--title "a\"b"%tok  %1 value%a"b
TK-dq-esc-dq-raw       %--title "a\"b"%tok  %1 raw%"a\"b"
TK-dq-esc-bs-value     %--title "a\\b"%tok  %1 value%a\b
TK-dq-esc-dollar-value %--title "a\$b"%tok  %1 value%a$b
TK-sq-keeps-backslash  %--title 'a\b'%tok   %1 value%a\b
TK-sq-cannot-escape-n  %--title 'a\'%n      %%2
TK-sq-cannot-escape-v  %--title 'a\'%tok    %1 value%a\
TABLE

# ============================================================================
# 5. Substitution bodies: their internal whitespace never splits a word, and
#    the whole word is a single `unquoted` piece (cmdsubst/backtick/subshell/
#    arith are frame kinds in the scanner, NOT piece kinds in a token).
#
#    `--title $(echo a b)`  token1 = [8,19)
# ============================================================================
run_table <<'TABLE'
TK-cmdsubst-n          %--title $(echo a b)%n        %%2
TK-cmdsubst-bounds     %--title $(echo a b)%bounds   %%0-7,8-19
TK-cmdsubst-piecekinds %--title $(echo a b)%piecekinds%1%unquoted
TK-cmdsubst-cover      %--title $(echo a b)%cover    %%ok
TK-backtick-n          %--title `echo a b`%n         %%2
TK-backtick-bounds     %--title `echo a b`%bounds    %%0-7,8-18
TK-subshell-n          %--title (a b)%n              %%2
TK-subshell-bounds     %--title (a b)%bounds         %%0-7,8-13
TK-arith-n             %--title $((1 + 2))%n         %%2
TK-arith-bounds        %--title $((1 + 2))%bounds    %%0-7,8-18
TK-dq-cmdsubst-ws-n    %--title "$(echo a b)"%n      %%2
TK-dq-cmdsubst-ws-bnds %--title "$(echo a b)"%bounds %%0-7,8-21
TABLE

# ============================================================================
# 5b. Substitution nested INSIDE a DQ word, with a quote inside the
#     substitution body. Section 5 pins only counts and bounds; nothing pinned
#     the piece decomposition, so an implementation that swallowed the whole
#     word as one opaque piece — losing the context transitions — passed.
#
#     A quote inside a substitution body is a REAL quote context (the shell
#     re-parses there), so it is a piece boundary, and the DQ context is
#     restored after the substitution closes. That extends section 5 rather
#     than contradicting it: cmdsubst/backtick are still not piece kinds, they
#     just do not suppress the quote pieces nested in them.
#
#     `--title "x$(echo 'a b')y"`   token1 = [8,25)
#        8 "  9 x  10 $  11 (  12..15 echo  16 sp  17 '  18 a  19 sp  20 b
#       21 '  22 )  23 y  24 "
#
#     Every row's word also contains two spaces that must NOT split it: one in
#     the substitution body and one inside the single quotes.
# ============================================================================
run_table <<'TABLE'
TK-dqsub-sq-n          %--title "x$(echo 'a b')y"%n         %%2
TK-dqsub-sq-bounds     %--title "x$(echo 'a b')y"%bounds    %%0-7,8-25
TK-dqsub-sq-piecekinds %--title "x$(echo 'a b')y"%piecekinds%1%dq,sq,dq
TK-dqsub-sq-pieces     %--title "x$(echo 'a b')y"%pieces    %1%dq@8-17:"x$(echo ,sq@17-22:'a b',dq@22-25:)y"
TK-dqsub-sq-values     %--title "x$(echo 'a b')y"%values    %%["--title","x$(echo a b)y"]
TK-dqsub-sq-cover      %--title "x$(echo 'a b')y"%cover     %%ok
TK-dqsub-sq-rejtok     %--title "x$(echo 'a b')y"%rejtok    %1%true
TK-dqbt-sq-n           %--title "x`echo 'a b'`y"%n          %%2
TK-dqbt-sq-bounds      %--title "x`echo 'a b'`y"%bounds     %%0-7,8-24
TK-dqbt-sq-piecekinds  %--title "x`echo 'a b'`y"%piecekinds %1%dq,sq,dq
TK-dqbt-sq-pieces      %--title "x`echo 'a b'`y"%pieces     %1%dq@8-16:"x`echo ,sq@16-21:'a b',dq@21-24:`y"
TK-dqbt-sq-values      %--title "x`echo 'a b'`y"%values     %%["--title","x`echo a b`y"]
TK-dqbt-sq-cover       %--title "x`echo 'a b'`y"%cover      %%ok
TK-dqbt-sq-rejtok      %--title "x`echo 'a b'`y"%rejtok     %1%true
TABLE
# Unquoted counterpart: same body, no enclosing DQ. The transitions are
# unquoted → sq → unquoted, which is what makes the dq rows above meaningful
# (the outer context is carried, not assumed).
run_table <<'TABLE'
TK-unqsub-sq-bounds    %--title x$(echo 'a b')y%bounds      %%0-7,8-23
TK-unqsub-sq-piecekinds%--title x$(echo 'a b')y%piecekinds  %1%unquoted,sq,unquoted
TK-unqsub-sq-pieces    %--title x$(echo 'a b')y%pieces      %1%unquoted@8-16:x$(echo ,sq@16-21:'a b',unquoted@21-23:)y
TK-unqsub-sq-values    %--title x$(echo 'a b')y%values      %%["--title","x$(echo a b)y"]
TK-unqsub-sq-cover     %--title x$(echo 'a b')y%cover       %%ok
TK-unqsub-sq-rejtok    %--title x$(echo 'a b')y%rejtok      %1%true
TABLE
# No nested quote: the substitution body stays inside ONE dq piece, so the
# boundaries above come from the quote and not from the substitution.
run_table <<'TABLE'
TK-dqsub-plain-pieces  %--title "x$(echo a b)y"%pieces      %1%dq@8-23:"x$(echo a b)y"
TK-dqsub-plain-values  %--title "x$(echo a b)y"%values      %%["--title","x$(echo a b)y"]
TK-dqsub-plain-rejtok  %--title "x$(echo a b)y"%rejtok      %1%true
TK-dqbt-plain-pieces   %--title "x`echo a b`y"%pieces       %1%dq@8-22:"x`echo a b`y"
TK-dqbt-plain-values   %--title "x`echo a b`y"%values       %%["--title","x`echo a b`y"]
TK-dqbt-plain-rejtok   %--title "x`echo a b`y"%rejtok       %1%true
TABLE

# ============================================================================
# 6. ANSI-C words. Rule 2 rejects them outright, so `value` is deliberately not
#    composed — only the piece kind and the verdict are contractual.
#
#    `--title $'a\nb'`  token1 = [8,15) — the table heredoc is quoted, so this
#    word is the SEVEN literal characters  $ ' a \ n b '  (no real newline),
#    i.e. 8+7 = 15. Compare the siblings in section 5: `$(echo a b)` = 11 chars
#    → 8-19, `` `echo a b` `` = 10 → 8-18, `$((1 + 2))` = 10 → 8-18.
# ============================================================================
run_table <<'TABLE'
TK-ansic-n             %--title $'a\nb'%n         %%2
TK-ansic-bounds        %--title $'a\nb'%bounds    %%0-7,8-15
TK-ansic-piecekinds    %--title $'a\nb'%piecekinds%1%ansic
TK-ansic-cover         %--title $'a\nb'%cover     %%ok
TK-ansic-mixed-kinds   %--title a$'x'b%piecekinds %1%unquoted,ansic,unquoted
TABLE

# ============================================================================
# 7. Malformed tails — rule 1 (fail-closed). An unterminated span makes the
#    whole tokenization unusable; ok:false is the ONLY safe answer, because any
#    token list derived from a guessed span boundary is an attacker's choice.
# ============================================================================
run_table <<'TABLE'
TK-bad-dq-ok           %--title "unclosed%ok  %%false
TK-bad-sq-ok           %--title 'unclosed%ok  %%false
TK-bad-ansic-ok        %--title $'unclosed%ok %%false
TK-bad-cmdsubst-ok     %--title $(unclosed%ok %%false
TK-bad-backtick-ok     %--title `unclosed%ok  %%false
TK-bad-subshell-ok     %--title (unclosed%ok  %%false
TK-bad-arith-ok        %--title $((1 + 2%ok   %%false
TK-bad-trailing-bs-dq  %--title "a b\%ok      %%false
TABLE
# Anti-vacuity for section 7: the closed counterparts must be ok:true, so the
# rows above cannot pass via a blanket ok:false.
run_table <<'TABLE'
TK-good-dq-ok          %--title "closed"%ok    %%true
TK-good-sq-ok          %--title 'closed'%ok    %%true
TK-good-ansic-ok       %--title $'closed'%ok   %%true
TK-good-cmdsubst-ok    %--title $(closed)%ok   %%true
TK-good-backtick-ok    %--title `closed`%ok    %%true
TK-good-subshell-ok    %--title (closed)%ok    %%true
TK-good-arith-ok       %--title $((1 + 2))%ok  %%true
TABLE

}
