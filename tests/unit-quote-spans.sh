#!/bin/bash
# tests/unit-quote-spans.sh
# Tests: hooks/lib/quote-spans.js, hooks/lib/quote-spans/scan.js, hooks/lib/quote-spans/query.js, hooks/lib/quote-spans/transform.js
# Tags: hook, quote-spans, parser, unit, security, scope:common
#
# STATUS: RED until C1 lands (hooks/lib/quote-spans/{scan,query,transform}.js +
# the hooks/lib/quote-spans.js barrel). EVERY assertion in this file and in
# tests/unit-quote-spans/*.sh is expected to fail today with
# `ERROR: require quote-spans.js: Cannot find module ...` — an
# implementation-missing failure, not a test bug.
#
# Dispatcher for the #1569 quote-span scanner unit suite:
#   unit-quote-spans/structure.sh     — the mandatory 14-case span-structure table
#   unit-quote-spans/context.sh       — quoteContextAt / error contract / memoization
#   unit-quote-spans/query-options.sh — contexts / includeCmdSubstBody /
#                                       onAmbiguous / RegExp inputs / newline split
#   unit-quote-spans/ambiguity.sh     — fail-closed contract for all 7 frame kinds
#   unit-quote-spans/edges.sh         — non-string inputs, lone backslashes, depth
#   unit-quote-spans/fold-kinds.sh    — foldNewlinesInSpans(str, kinds) selector
#
# Drive surface: tests/fixtures/quote-spans-probe.js (thin CLI over the barrel).
#
# TL3 gap (what this TL1/TL2 test does NOT catch):
# - the scanner running inside the real enforce-worktree.js PreToolUse process
#   with a live Claude Code Bash payload (span offsets are consumed there by
#   arg-tail tokenization and write-target extraction, not in isolation)
# - real bash's own parse of the same strings (agreement with the shell is
#   asserted only by construction, never executed)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
PROBE="${_AGENTS_DIR_NODE}/tests/fixtures/quote-spans-probe.js"

PASS=0
FAIL=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

probe() {
    run_with_timeout 30 node "$PROBE" "$@" 2>/dev/null
}

# Trim leading/trailing whitespace of the named variable, in place.
_trim() {
    local __v="${!1}"
    __v="${__v#"${__v%%[![:space:]]*}"}"
    __v="${__v%"${__v##*[![:space:]]}"}"
    printf -v "$1" '%s' "$__v"
}

# assert_probe <name> <input> <op> <args> <want>
# `want` may be the sentinel @LEN, meaning "the character length of <input>"
# (used to pin a span's exclusive `end` at end-of-string without hardcoding it).
assert_probe() {
    local name="$1" input="$2" op="$3" args="$4" want="$5"
    if [ "$want" = "@LEN" ]; then want="${#input}"; fi
    local got
    # `$args` is intentionally unquoted (it carries 0..3 words), but it must NOT
    # be glob-expanded: the kind selector "*" and the `[...]`/`{...}` JSON opts
    # would otherwise be replaced by matching filenames in the cwd. `set -f` is
    # scoped to the command substitution's subshell, so word splitting still
    # happens and the caller's shell is untouched.
    # shellcheck disable=SC2086
    got="$(set -f; probe "$op" "$input" $args)"
    assert_eq "$name" "$want" "$got"
}

# run_table <<'TABLE' … TABLE — columns: name|input|op|args|want
run_table() {
    local name input op args want
    while IFS='|' read -r name input op args want; do
        [ -z "${name:-}" ] && continue
        case "$name" in \#*) continue ;; esac
        _trim name; _trim op; _trim args; _trim want
        # `input` keeps its interior spacing; only the padding around the
        # column separator is removed.
        _trim input
        [ -z "$name" ] && continue
        assert_probe "$name" "$input" "$op" "$args" "$want"
    done
}

if [ ! -f "$PROBE" ]; then
    echo "FAIL: precondition missing — tests/fixtures/quote-spans-probe.js"
    echo ""
    echo "Total: PASS=0 FAIL=1"
    exit 1
fi

SCRIPT_DIR_1569="$(dirname "${BASH_SOURCE[0]}")/unit-quote-spans"
# shellcheck source=./unit-quote-spans/structure.sh
. "$SCRIPT_DIR_1569/structure.sh"
# shellcheck source=./unit-quote-spans/context.sh
. "$SCRIPT_DIR_1569/context.sh"
# shellcheck source=./unit-quote-spans/query-options.sh
. "$SCRIPT_DIR_1569/query-options.sh"
# shellcheck source=./unit-quote-spans/ambiguity.sh
. "$SCRIPT_DIR_1569/ambiguity.sh"
# shellcheck source=./unit-quote-spans/edges.sh
. "$SCRIPT_DIR_1569/edges.sh"
# shellcheck source=./unit-quote-spans/fold-kinds.sh
. "$SCRIPT_DIR_1569/fold-kinds.sh"
# shellcheck source=./unit-quote-spans/deep-recursion.sh
. "$SCRIPT_DIR_1569/deep-recursion.sh"

run_structure_cases
run_context_cases
run_query_option_cases
run_ambiguity_cases
run_edge_cases
run_fold_kind_cases
run_deep_recursion_cases

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
