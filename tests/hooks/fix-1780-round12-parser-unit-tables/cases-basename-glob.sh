#!/usr/bin/env bash
# Part of tests/fix-1780-round12-parser-unit-tables.sh (rules/coding/file-split.md).
# Sections N, G and B - the basename side of the pipeline:
#   N  normalizeCandidateBasename()  (hooks/lib/basename-glob-normalize.js)
#   G  hasGlobMetachar() + candidateBasenameMatchesAnySuffix()
#   B  brace / ANSI-C expansion      (hooks/lib/basename-glob-normalize/brace-ansi-expand.js)
# Sourced by the parent, which owns run_table(), _expand() and the counters.

# ===========================================================================
# Section N — normalizeCandidateBasename() (hooks/lib/basename-glob-normalize.js)
#
# The normalizer answers "what basename does the OS actually see?" for a spelling
# a hook reads BEFORE the shell and the filesystem have had their say. It is
# consumed in the DETECTION direction, so it may widen and may never rewrite.
#
# PAIRING (the mutation-evidence discipline of parser-regex-tests.md): each strip
# rule is stated by a row that exercises it and a row that must NOT trigger it and
# differs by exactly one property —
#   N-ads1/N-ads2 (`::$DATA` / `:alt` are stream specs) vs N-drive (`C:` is not)
#   N-trail1/N-trail2 (trailing dot / space are stripped by Windows)
#                      vs N-interior (an interior dot is content, not padding)
#   N-quote (outer quotes are shell syntax) vs N-quoteinner (an interior quote is not)
#   N-glob (metachars SURVIVE normalization — the round-8 H-3 regression: resolving
#           `?` to a filler char here NARROWED the deny match and was a live bypass)
# ===========================================================================
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

# ===========================================================================
# Section G — hasGlobMetachar() + candidateBasenameMatchesAnySuffix()
#
# The deny decision. `?`/`[…]`/`*` are over-approximated (a glob that COULD expand
# onto a protected name is a hit), and the named exception from the module header
# is pinned by its own rows: a pattern contributing NO literal character to the
# protected suffix is NOT a hit, or `rm -rf build/*` would be blocked.
#
# PAIRING:
#   G-hit vs G-miss           full suffix vs the same string one char short
#   G-q / G-star vs G-bare / G-bulk   glob WITH literal overlap vs glob WITHOUT
#   G-case vs G-suffixword    case-folding vs a name that merely CONTAINS the
#                             suffix but does not END with it (`…-offx`)
#   G-brace-same vs G-brace-none  a brace alternative that rebuilds the marker vs
#                             one where no alternative does
#   G-meta-yes/G-meta-no      hasGlobMetachar is the predicate the caller branches
#                             on, so it gets its own pair; `{` is deliberately NOT
#                             a glob metachar (brace expansion is a separate axis)
# ===========================================================================
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

# ===========================================================================
# Section B — brace-ansi-expand.js. These two constructs differ IN KIND from a
# glob and the difference is the whole point: a glob can only match a file that
# already EXISTS, while `{f..f}` and `$'…\x66'` CREATE the exact protected
# basename — and a marker's existence alone is clearance.
#
# PAIRING:
#   B-hex/B-oct vs B-none      an escape that decodes vs text with none
#   B-upperX                   uppercase `\X` — bash does NOT decode it, the shared
#                              decoder does. Named, accepted over-detection: the
#                              widening direction is the safe one, do not "fix" it
#                              by narrowing the decoder.
#   B-comma/B-range vs B-single   `{a,b}` and `{a..b}` expand; a single element
#                              `{x}` does NOT — bash fidelity, and the boundary a
#                              too-eager widener would cross
#   B-pad                      zero-padded ranges keep their width
#   B-cart                     adjacent groups multiply (cartesian product)
#   B-raw                      the RAW spelling is always in the candidate set —
#                              a normalizer in the detection direction may add
#                              spellings but may never drop one
# ===========================================================================
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
B-cart    | abd~abe~acd~ace~a{b,c}{d,e}   | braces | a{b,c}{d,e}
B-plain   | plain                         | braces | plain
B-cap     | false                         | bracecap | a{b,c}
B-raw     | s1@MK@~s1@MK1@{f..f}          | spellings | s1@MK1@{f..f}
B-raw2    | plain.txt                     | spellings | plain.txt
TABLE
}
