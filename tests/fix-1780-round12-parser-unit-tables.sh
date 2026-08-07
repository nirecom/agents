#!/usr/bin/env bash
# tests/fix-1780-round12-parser-unit-tables.sh
# Tests: hooks/block-clearance-token-write/bash-scan/argv-scan.js, hooks/block-clearance-token-write/bash-scan/assignment-text.js, hooks/block-clearance-token-write/interpreter-scan.js, hooks/block-clearance-token-write/nested-bodies.js, hooks/lib/basename-glob-normalize.js, hooks/lib/basename-glob-normalize/brace-ansi-expand.js, hooks/lib/protected-basenames.js
# Tags: off-clearance, session-marker, protected-basename, parser, regex, table-driven, mutation-evidence, allowlist, glob, brace-expansion, ansi-c-quoting, interpreter, interpreter-identity, heredoc, here-string, eval, stdin-program, argv-operand, assignment-chain, pwsh-env, classifier, security, unit, scope:common, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - Nothing about the HOOK. Every function here is called in-process; whether the
#   entrypoint routes a real tool call into them is asserted by the TL2 sibling
#   tests/fix-1780-round12-classifier-attack-shapes.sh and, for PreToolUse
#   registration, statically by tests/enforce-protected-marker-write.sh (X6).
# - Real shell / OS behaviour. That bash expands `{f..f}`, that `$'\x66'` decodes
#   to `f`, and that NTFS folds `x::$DATA` onto `x` are all PREMISES here; what is
#   asserted is only that these modules model them.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.
#
# ---------------------------------------------------------------------------
# WHY THIS FILE EXISTS (#1780 round-12, /review-tests gap 6)
#
# The six modules named above are parsers, regex constants and allowlists — the
# exact target class for which skills/_shared/test-design/parser-regex-tests.md
# makes table-driven cases and mutation evidence MANDATORY. They were reached
# only through the hook until now: every assertion about them was a BLOCK/ALLOW
# verdict several layers downstream, which cannot distinguish "the regex is
# right" from "something else upstream happened to answer the same way".
#
# Two obligations, both discharged here:
#
#   TABLE-DRIVEN (Sections N/G/B/A/S/I/D). Every row is `name|want|fn|input`,
#   iterated with `IFS='|' read -r`, and the row NAME is injected into the
#   assertion message — the pattern the rule prescribes. Each behaviour is
#   carried by a PAIR of rows differing by exactly the property under test
#   (`cat` vs `catx`, `-o` vs `--log`, `$A` vs `"$A"`, `{a,b}` vs `{x}`,
#   `node -e` vs `node script.js`), so a row that passes for the wrong reason
#   has a sibling that fails.
#
#   MUTATION EVIDENCE (Section M). Paired rows argue that a case is DISCRIMINATING;
#   they cannot prove which code decides it. Section M copies hooks/ to a throwaway
#   directory, replaces ONE named regex constant with the never-matching `/(?!)/`
#   (tests/fix-1780-round12-parser-unit-tables/mutate.js), and asserts that the row
#   keyed on that constant FLIPS to a stated different value. A constant whose
#   mutant leaves every row unchanged is dead code as far as this suite is
#   concerned, and the assertion says so by name.
#
#   Why not bin/mutation-probe.sh: it handles the single-line `const NAME = /re/;`
#   form only (its own header says so), and every constant that matters in
#   interpreter-scan.js / argv-scan.js / assignment-text.js is a multi-line
#   `new RegExp(String.raw`…`)`. Section M covers both forms.
#
# WHAT IS BEING DEFENDED. hooks/lib/session-markers.js authorizes on a marker
# file's EXISTENCE alone, so every one of these parsers sits on the path between
# "a shell command that creates a file" and "full session clearance". A widening
# regex over-blocks ordinary work (CPR-ORTH, the ALLOW-side rows); a narrowing one
# is a one-command forge of WORKFLOW_OFF.
#
# NO PROTECTED NAME IS HARDCODED. The marker and token spellings are read from
# hooks/lib/protected-basenames.js at run time and substituted into the tables
# via @MK@ / @MK1@ / @TOK@ / @TOK1@, so a marker kind added to the SSOT later
# cannot leave these tables quietly testing a name that no longer exists.
#
# LAYOUT (rules/coding/file-split.md). This file is the harness — setup, the SSOT
# introspection, _expand(), run_table() and dispatch. The case tables themselves
# live in tests/fix-1780-round12-parser-unit-tables/:
#   cases-basename-glob.sh   Sections N, G, B
#   cases-bash-scan.sh       Sections A, S
#   cases-interpreter.sh     Sections I, D
#   cases-mutation.sh        Section M
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi

RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
PARTS_DIR="$AGENTS_DIR/tests/fix-1780-round12-parser-unit-tables"
PROBE="$PARTS_DIR/probe.js"
MUTATE="$PARTS_DIR/mutate.js"
PB_NODE="$_AGENTS_DIR_NODE/hooks/lib/protected-basenames.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'r12unit'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name - want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# rules/test/fixture-isolation.md: never let anything here resolve the live
# session or the developer's real plans dir. These modules touch no files, but
# the pins are dual and unconditional so no future side effect can escape.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true
SANDBOX=$(make_tmp); WF=$(node_path "$SANDBOX")
export CLAUDE_WORKFLOW_DIR="$WF" WORKFLOW_PLANS_DIR="$WF"
cleanup() { [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -r -f "$SANDBOX" 2>/dev/null; return 0; }
trap cleanup EXIT

# --- H: harness self-checks. Without them a broken probe reports a green run --
if [ -f "$PROBE" ]; then pass "H0 probe present"
else
    fail "H0 probe MISSING at $PROBE - every table below would be vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi

# Protected spellings DERIVED from the SSOT (CPR-SSOT), never written out here.
MK=$("$RWT" 10 node -e \
    "process.stdout.write('.' + require(process.argv[1]).SESSION_MARKER_KINDS[0])" "$PB_NODE" 2>/dev/null)
TOK=$("$RWT" 10 node -e \
    "process.stdout.write(require(process.argv[1]).OFF_CLEARANCE_TOKEN_SUFFIXES[0])" "$PB_NODE" 2>/dev/null)
if [ -z "$MK" ] || [ -z "$TOK" ]; then
    fail "H1 protected-basename SSOT is introspectable (hooks/lib/protected-basenames.js exports)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H1 protected-basename SSOT introspected: marker=[$MK] token=[$TOK]"
MK1="${MK%?}"     # marker suffix minus its last character
TOK1="${TOK%?}"   # token  suffix minus its last character

# _expand <text>: the placeholder substitution every table goes through.
#   @MK@/@MK1@   marker suffix (full / minus last char)
#   @TOK@/@TOK1@ token  suffix (full / minus last char)
# Longest placeholder first, so @MK1@ is never eaten by the @MK@ rule.
_expand() {
    local t="$1"
    t="${t//@MK1@/$MK1}"; t="${t//@TOK1@/$TOK1}"
    t="${t//@MK@/$MK}";   t="${t//@TOK@/$TOK}"
    printf '%s' "$t"
}

# run_table <section> — the pattern from parser-regex-tests.md, with the probe as
# `eval_subject`. The table is read TWICE: once to feed the probe (one node
# process for the whole section) and once to assert. Rows are `name|want|fn|input`;
# with IFS='|' and four `read` targets the whole remainder of the line lands in
# `input`, separators included, so pipeline inputs survive intact.
#
# `want` is the SECOND column, not the last, precisely because the input may
# contain `|`: a trailing `want` could not be split off without truncating the
# pipeline rows this suite exists to cover.
#
# Column padding is trimmed. Two escapes buy back what trimming and line-based
# reading cost: `\n` is a real newline (heredoc rows) and `\s` a literal space
# (a trailing space is itself a normalizer rule under test).
run_table() {
    local section="$1" tbl res
    tbl="$SANDBOX/$section.tbl"
    _expand "$(cat)" > "$tbl"
    res=$("$RWT" 30 node "$(node_path "$PROBE")" "$_AGENTS_DIR_NODE" < "$tbl" 2>&1)
    if [ -z "$res" ]; then
        fail "$section probe produced no output - the whole section is vacuous"
        return
    fi
    case "$res" in
        *__MODULES__*) fail "$section probe could not load the modules under test: $res"; return ;;
    esac
    local name want fn input got
    while IFS='|' read -r name want fn input; do
        [ -z "${name:-}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(printf '%s' "$name" | sed 's/^ *//; s/ *$//')"
        want="$(printf '%s' "$want" | sed 's/^ *//; s/ *$//')"
        got=$(printf '%s\n' "$res" | awk -F'\t' -v n="$name" '$1 == n { print $2; exit }')
        assert_eq "$section $name" "$want" "$got"
    done < "$tbl"
}

# shellcheck source=./fix-1780-round12-parser-unit-tables/cases-basename-glob.sh
. "$PARTS_DIR/cases-basename-glob.sh"
# shellcheck source=./fix-1780-round12-parser-unit-tables/cases-bash-scan.sh
. "$PARTS_DIR/cases-bash-scan.sh"
# shellcheck source=./fix-1780-round12-parser-unit-tables/cases-interpreter.sh
. "$PARTS_DIR/cases-interpreter.sh"
# shellcheck source=./fix-1780-round12-parser-unit-tables/cases-mutation.sh
. "$PARTS_DIR/cases-mutation.sh"

run_N_normalize_basename  # Section N
run_G_glob_match          # Section G
run_B_brace_ansi          # Section B
run_A_argv_scan           # Section A
run_S_assignment_text     # Section S
run_I_interpreter_scan    # Section I
run_D_nested_bodies       # Section D
run_M_mutation_evidence   # Section M

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
