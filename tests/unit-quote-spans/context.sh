# tests/unit-quote-spans/context.sh
# Tests: hooks/lib/quote-spans/query.js, hooks/lib/quote-spans/transform.js
# Tags: hook, quote-spans, parser, unit, security, scope:common
#
# STATUS: RED until C1 lands. Sourced by tests/unit-quote-spans.sh.
#
# Pins for:
#   - quoteContextAt (only dq/sq/ansic yield their own name; every expanding
#     frame body — cmdsubst/backtick/subshell/arith — reports "unquoted")
#   - the ok:false error contract across all three API groups
#   - hasUnclosedQuoteSpan kind limiting (default kinds EXCLUDE the four
#     expanding frames)
#   - LRU memoization + _resetCacheForTest()

run_context_cases() {

# ---------------------------------------------------------------------------
# quoteContextAt
# ---------------------------------------------------------------------------
run_table <<'TABLE'
QC-dq              | "abc"     | ctxat | 1 | dq
QC-sq              | 'abc'     | ctxat | 1 | sq
QC-ansic           | $'abc'    | ctxat | 3 | ansic
QC-unquoted        | abc       | ctxat | 1 | unquoted
QC-cmdsubst-body   | $(rm x)   | ctxat | 3 | unquoted
QC-backtick-body   | `rm x`    | ctxat | 2 | unquoted
QC-subshell-body   | (rm x)    | ctxat | 2 | unquoted
QC-arith-body      | $((1+2))  | ctxat | 4 | unquoted
QC-dq-in-cmdsubst  | $(a "b")  | ctxat | 5 | dq
QC-sq-in-cmdsubst  | $(a 'b')  | ctxat | 5 | sq
QC-cmdsubst-in-dq  | "$(a)"    | ctxat | 3 | unquoted
TABLE

# ---------------------------------------------------------------------------
# hasUnclosedQuoteSpan kind limiting.
# Default kinds are ["dq","sq","ansic"] — an unclosed EXPANDING frame
# (cmdsubst/backtick/subshell/arith) must NOT be reported by the default call,
# otherwise every `$(` typo would be treated as an unclosed quote.
# ---------------------------------------------------------------------------
run_table <<'TABLE'
KL-cmdsubst-default  | $(unclosed | unclosed |                      | false
KL-cmdsubst-explicit | $(unclosed | unclosed | dq,sq,ansic          | false
KL-cmdsubst-included | $(unclosed | unclosed | dq,sq,ansic,cmdsubst | true
KL-subshell-default  | (unclosed  | unclosed |                      | false
KL-subshell-included | (unclosed  | unclosed | subshell             | true
KL-arith-default     | $((1       | unclosed |                      | false
KL-backtick-default  | `unclosed  | unclosed |                      | false
KL-backtick-included | `unclosed  | unclosed | backtick             | true
KL-dq-default        | "unclosed  | unclosed |                      | true
KL-sq-default        | 'unclosed  | unclosed |                      | true
KL-ansic-default     | $'unclosed | unclosed |                      | true
KL-closed-default    | "closed"   | unclosed |                      | false
TABLE

# ---------------------------------------------------------------------------
# Happy-path query / split / transform behaviour.
# Present so the ok:false contract below cannot pass vacuously (a stub that
# always returns {ok:false} would fail every row here).
# ---------------------------------------------------------------------------
run_table <<'TABLE'
Q-find-outside      | echo ";" ; ls  | find  | ;      | 9
Q-find-none         | echo ";"       | find  | ;      | -1
Q-test-none         | echo ";"       | test  | ;      | false
Q-test-outside      | echo ";" ; ls  | test  | ;      | true
Q-find-cmdsubst-body| echo "$(a;b)"  | find  | ;      | 9
Q-split-protected   | a;"b;c"        | split | ;      | ok=true,n=2,first_is_input=false
Q-split-none        | "a;b"          | split | ;      | ok=true,n=1,first_is_input=true
TR-blank-changes    | echo "abc"     | transform | blank  | ok=true,unchanged=false
TR-blank-noop       | echo abc       | transform | blank  | ok=true,unchanged=true
TR-unwrap-changes   | echo "$(rm x)" | transform | unwrap | ok=true,unchanged=false
TR-unwrap-noop      | echo abc       | transform | unwrap | ok=true,unchanged=true
TR-fold-noop        | echo "abc"     | transform | fold   | ok=true,unchanged=true
TABLE

# Newline-bearing inputs cannot live in the pipe table (rows are line-based).
assert_probe "TR-fold-dq-newline"   "$(printf 'echo "a\nb"')"   transform fold    "ok=true,unchanged=false"
assert_probe "TR-fold-bare-newline" "$(printf 'echo a\nb')"     transform fold    "ok=true,unchanged=true"
assert_probe "NL-split-protected"   "$(printf 'a\n"b\nc"')"     nlsplit   ""      "ok=true,n=2,first_is_input=false"

# ---------------------------------------------------------------------------
# ok:false error contract — 5 unclosed-quote inputs × 3 API groups.
#   predicate group -> DANGER (testOutsideQuotes=true, findOutsideQuotes=0,
#                              hasUnclosedQuoteSpan=true)
#   split group     -> {ok:false} with parts/lines === [str]
#   transform group -> {ok:false, out === str}
# ---------------------------------------------------------------------------
ERR_INPUTS=()
while IFS= read -r _inp; do
    [ -z "$_inp" ] && continue
    ERR_INPUTS+=("$_inp")
done <<'INPUTS'
"unclosed
'unclosed
$'unclosed
"a'b
'a"b
INPUTS

ERR_CONTRACT=()
while IFS= read -r _row; do
    [ -z "$_row" ] && continue
    case "$_row" in \#*) continue ;; esac
    ERR_CONTRACT+=("$_row")
done <<'CONTRACT'
test|;|true
find|;|0
unclosed||true
split|;|ok=false,n=1,first_is_input=true
nlsplit||ok=false,n=1,first_is_input=true
transform|blank|ok=false,unchanged=true
transform|fold|ok=false,unchanged=true
transform|unwrap|ok=false,unchanged=true
CONTRACT

for _inp in "${ERR_INPUTS[@]}"; do
    for _row in "${ERR_CONTRACT[@]}"; do
        IFS='|' read -r _op _args _want <<< "$_row"
        assert_probe "ERR[$_inp] $_op $_args" "$_inp" "$_op" "$_args" "$_want"
    done
done

# The exception path shares the same contract shape (failReason "exception",
# failKinds ["*"]). It is not reachable from a plain string input at this layer.
# SKIPPED: force scanSpans() to throw and assert {spans:[],ok:false,
#          failReason:"exception",failKinds:["*"]}.
# Because: requires fault injection into the scanner's internals; not
#          reproducible from the public string-in/JSON-out probe surface.
# TL3 gap: only a real malformed-input crash in the live hook would exercise it;
#          the fail-safe consequence (BLOCK) is covered by
#          tests/fix-1569-quote-span-regression.sh case 13.

# ---------------------------------------------------------------------------
# Memoization: 8-entry LRU keyed on the string, plus _resetCacheForTest().
# ---------------------------------------------------------------------------
run_table <<'TABLE'
MEMO-identity | $(a "b") | memoid  |  | same=true,after_reset=false
MEMO-lru-evict| $(a "b") | memolru |  | evicted=true
TABLE

}
