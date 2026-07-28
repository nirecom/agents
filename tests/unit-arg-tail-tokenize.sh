#!/bin/bash
# tests/unit-arg-tail-tokenize.sh
# Tests: hooks/enforce-worktree/arg-tail-guard.js, hooks/lib/quote-spans.js
# Tags: hook, worktree, enforce, arg-tail, quote-spans, parser, unit, security, scope:common
#
# STATUS: RED until C3 lands (hooks/enforce-worktree/arg-tail-guard.js). Every
# row fails today with `ERROR: require arg-tail-guard.js: Cannot find module ...`
# — an implementation-missing failure, not a test bug.
#
# tokenizeArgTail's own contract, pinned exactly rather than only through the
# guard verdicts in tests/fix-1569-quote-span-regression/arg-tail-module.sh.
# The verdict tests can only see a boolean; a tokenizer that mis-attributes a
# piece but happens to reject the same commands would pass them all. These rows
# pin raw / start / end / value / pieces so provenance itself is the assertion.
#
#   Token = { raw, start, end, value, pieces }
#   Piece = { kind: "unquoted"|"dq"|"sq"|"ansic", start, end, text }
#   pieces cover [token.start, token.end) with no holes, in order, and each
#   piece's `text` is exactly argTail.slice(piece.start, piece.end) — i.e. the
#   quote DELIMITERS belong to the piece, not to a gap between pieces.
#
# Column separator is `%` (not `|`) because half of these inputs are about the
# pipe character.
#
# Drive surface: tests/fixtures/arg-tail-tokenize-probe.js.
#
# TL3 gap (what this TL1 test does NOT catch):
# - the tokenizer running inside the real enforce-worktree.js PreToolUse process
#   against a live Claude Code Bash payload (offsets are consumed there by the
#   write-target extractor, whose agreement with these offsets is untested here)
# - real bash's own word splitting of the same arg tails (agreement with the
#   shell is asserted only by construction, never executed)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
PROBE="${_AGENTS_DIR_NODE}/tests/fixtures/arg-tail-tokenize-probe.js"

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

probe() { run_with_timeout 30 node "$PROBE" "$@" 2>/dev/null; }

_trim() {
    local __v="${!1}"
    __v="${__v#"${__v%%[![:space:]]*}"}"
    __v="${__v%"${__v##*[![:space:]]}"}"
    printf -v "$1" '%s' "$__v"
}

# assert_probe <name> <argTail> <op> <args> <want>
assert_probe() {
    local name="$1" input="$2" op="$3" args="$4" want="$5" got
    # `$args` stays unquoted for word splitting but must not glob-expand
    # (symmetric with tests/unit-quote-spans.sh); `set -f` is scoped to the
    # command substitution's subshell.
    # shellcheck disable=SC2086
    got="$(set -f; probe "$op" "$input" $args)"
    assert_eq "$name" "$want" "$got"
}

# run_table <<'TABLE' … TABLE — columns: name%input%op%args%want
# `input` is NOT trimmed: leading/trailing whitespace in an arg tail is exactly
# what the word splitter is being tested on.
run_table() {
    local name input op args want
    # Documented exception to skills/_shared/test-design/parser-regex-tests.md,
    # which mandates `while IFS='|' read -r`: `|` is one of the SET-A
    # metacharacters under test here, so half the inputs would split mid-column.
    while IFS='%' read -r name input op args want; do
        case "${name:-}" in ""|\#*) continue ;; esac
        _trim name; _trim op; _trim args; _trim want
        [ -z "$name" ] && continue
        assert_probe "$name" "$input" "$op" "$args" "$want"
    done
}

if [ ! -f "$PROBE" ]; then
    echo "FAIL: precondition missing — tests/fixtures/arg-tail-tokenize-probe.js"
    echo ""
    echo "Total: PASS=0 FAIL=1"
    exit 1
fi

SCRIPT_DIR_TK="$(dirname "${BASH_SOURCE[0]}")/unit-arg-tail-tokenize"
# shellcheck source=./unit-arg-tail-tokenize/tokens.sh
. "$SCRIPT_DIR_TK/tokens.sh"
# shellcheck source=./unit-arg-tail-tokenize/rules.sh
. "$SCRIPT_DIR_TK/rules.sh"
# shellcheck source=./unit-arg-tail-tokenize/perf.sh
. "$SCRIPT_DIR_TK/perf.sh"

run_tokenize_shape_cases
run_tokenize_rule_cases
run_tokenize_perf_cases

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
