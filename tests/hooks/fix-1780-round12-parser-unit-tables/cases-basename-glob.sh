#!/usr/bin/env bash
# Part of tests/hooks/fix-1780-round12-parser-unit-tables.sh (rules/coding/file-split.md).
# Sections N, G and B - the basename side of the pipeline; the parent owns the harness
# and explains the row-pairing discipline in its header.

# Section N - normalizeCandidateBasename(); strip rules: hooks/lib/basename-glob-normalize.js.
# N-glob is the round-8 H-3 regression: resolving `?` to a filler char narrowed the deny match (a live bypass).
run_N_normalize_basename() {
run_table N <<'TABLE'
N-plain      | s1@MK@             | norm | s1@MK@
N-ads1       | s1@MK@             | norm | s1@MK@::$DATA
N-ads2       | s1@MK@             | norm | s1@MK@:alt
N-ads-token  | s1@TOK@            | norm | s1@TOK@::$DATA
N-drive      | C:/wf/s1@MK@       | norm | C:/wf/s1@MK@
N-trail1     | s1@MK@             | norm | s1@MK@.
N-trail2     | s1@MK@             | norm | s1@MK@\s
N-interior   | s1@MK@.bak         | norm | s1@MK@.bak
N-quote      | s1@MK@             | norm | "s1@MK@"
N-quotesq    | s1@MK@             | norm | 's1@MK@'
N-quoteinner | a"b.txt            | norm | a"b.txt
N-glob       | s1@MK1@?           | norm | s1@MK1@?
N-globstar   | s1@MK1@*           | norm | s1@MK1@*
TABLE
}

# Section G - hasGlobMetachar() + candidateBasenameMatchesAnySuffix(); the deny decision
# and its no-literal-overlap exception: hooks/lib/basename-glob-normalize.js header.
run_G_glob_match() {
run_table G <<'TABLE'
G-meta-yes    | true  | hasglob | s1@MK1@?
G-meta-class  | true  | hasglob | s1@MK1@[f]
G-meta-star   | true  | hasglob | s1@MK1@*
G-meta-no     | false | hasglob | s1@MK@
G-meta-brace  | false | hasglob | s1@MK1@{f..f}
G-hit         | true  | match | s1@MK@
G-miss        | false | match | s1@MK1@
G-hit-token   | true  | match | s1@TOK@
G-hit-claimed | true  | match | s1@TOK@.claimed
G-q           | true  | match | s1@MK1@?
G-class       | true  | match | s1@MK1@[f]
G-star        | true  | match | s1@MK1@*
G-bare        | false | match | *
G-bulk        | false | match | logs/2024*
G-case        | true  | match | S1@MK@
G-suffixword  | false | match | notes@MK@x
G-ads         | true  | match | s1@MK@::$DATA
G-brace-range | true  | match | s1@MK1@{f..f}
G-brace-same  | true  | match | s1@MK1@{f,f}
G-brace-none  | false | match | s1@MK1@{x,y}
G-ordinary    | false | match | src/app.js
TABLE
}

# Section B - brace / ANSI-C expansion; direction discipline and bash-fidelity rules:
# hooks/lib/basename-glob-normalize/brace-ansi-expand.js header.
# B-upperX: bash does not decode `\X`, the decoder does - accepted over-detection; never narrow the decoder to "fix" it.
run_B_brace_ansi() {
run_table B <<'TABLE'
B-hex     | s1@MK@                        | ansi | s1@MK1@\x66
B-oct     | s1@MK@                        | ansi | s1@MK1@\146
B-none    | s1@MK@                        | ansi | s1@MK@
B-upperX  | s1@MK@                        | ansi | s1@MK1@\X66
B-vars    | s1@MK@~$'s1@MK@'              | ansivars | $'s1@MK1@\x66'
B-vars-no | -                             | ansivars | s1@MK@
B-comma   | ab~ac~a{b,c}                  | braces | a{b,c}
B-single  | {x}                           | braces | {x}
B-range   | f1~f2~f3~f{1..3}              | braces | f{1..3}
B-pad     | f01~f02~f03~f{01..03}         | braces | f{01..03}
B-cart    | abd~abe~axd~axe~a{b,x}{d,e}   | braces | a{b,x}{d,e}
B-plain   | plain                         | braces | plain
B-cap     | false                         | bracecap | a{b,c}
B-raw     | s1@MK@~s1@MK1@{f..f}          | spellings | s1@MK1@{f..f}
B-raw2    | plain.txt                     | spellings | plain.txt
TABLE
}
