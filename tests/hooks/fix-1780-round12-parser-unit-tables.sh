#!/usr/bin/env bash
# tests/hooks/fix-1780-round12-parser-unit-tables.sh — table-driven and mutation-evidence unit tests (#1780 round-12).
# Tests: hooks/block-clearance-token-write/bash-scan/argv-scan.js, hooks/block-clearance-token-write/bash-scan/assignment-text.js, hooks/block-clearance-token-write/interpreter-scan.js, hooks/block-clearance-token-write/nested-bodies.js, hooks/lib/basename-glob-normalize.js, hooks/lib/basename-glob-normalize/brace-ansi-expand.js, hooks/lib/protected-basenames.js
# Tags: off-clearance, session-marker, protected-basename, parser, regex, table-driven, mutation-evidence, allowlist, glob, brace-expansion, ansi-c-quoting, interpreter, interpreter-identity, heredoc, here-string, eval, stdin-program, argv-operand, assignment-chain, pwsh-env, classifier, security, unit, scope:common, pwsh-not-required, TL1
# TL3 gap: hook routing (TL2 sibling fix-1780-round12-classifier-attack-shapes.sh; X6 of enforce-protected-marker-write.sh)
#   and real shell / OS behaviour ({f..f}, $'\x66', x::$DATA) are premises here, not asserted.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.
# Rows are `name|want|fn|input`, paired by the property under test; Section M swaps one regex constant for `/(?!)/`
#   (mutate.js) and asserts its row flips. Protected spellings come from hooks/lib/protected-basenames.js (@MK@/@TOK@).
# Pattern and rationale: skills/_shared/test-design/parser-regex-tests.md. Tables in fix-1780-round12-parser-unit-tables/:
#   cases-basename-glob.sh (N, G, B), cases-bash-scan.sh (A, S), cases-interpreter.sh (I, D), cases-mutation.sh (M).

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"; else _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"; fi

RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
PARTS_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/fix-1780-round12-parser-unit-tables"
PROBE="$PARTS_DIR/probe.js"
MUTATE="$PARTS_DIR/mutate.js"
PB_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/lib/protected-basenames.js"

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
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
SANDBOX=$(make_tmp); WF=$(node_path "$SANDBOX")
export WORKFLOW_STATE_DIR="$WF" WORKFLOW_PLANS_DIR="$WF"
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

# run_table <section> — the parser-regex-tests.md pattern with the probe as `eval_subject`. The
# table is read twice: once to feed the probe (one node process per section), once to assert.
# Rows are `name|want|fn|input`; with IFS='|' the rest of the line lands in `input`, so a `|`
# inside an input survives, which is why `want` is the second column. Padding is trimmed; `\n`
# is a real newline and `\s` a literal space. The table file has no final newline, so the loop
# also takes the last, unterminated row.
run_table() {
    local section="$1" tbl res
    tbl="$SANDBOX/$section.tbl"
    _expand "$(cat)" > "$tbl"
    res=$("$RWT" 30 node "$(node_path "$PROBE")" "$_SCRIPT_CHECKOUT_ROOT_NODE" < "$tbl" 2>&1)
    if [ -z "$res" ]; then
        fail "$section probe produced no output - the whole section is vacuous"
        return
    fi
    case "$res" in
        *__MODULES__*) fail "$section probe could not load the modules under test: $res"; return ;;
    esac
    local name want fn input got
    while IFS='|' read -r name want fn input || [ -n "$name" ]; do
        [ -z "${name:-}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(printf '%s' "$name" | sed 's/^ *//; s/ *$//')"
        want="$(printf '%s' "$want" | sed 's/^ *//; s/ *$//')"
        got=$(printf '%s\n' "$res" | awk -F'\t' -v n="$name" '$1 == n { print $2; exit }')
        assert_eq "$section $name" "$want" "$got"
    done < "$tbl"
}

# H2: run_table must assert the last, unterminated row; a wrong want there has to fail. Runs in a
# subshell so the deliberate failure never reaches the real counters.
H2_OUT="$(printf 'H2-first | s1@MK@ | norm | s1@MK@\nH2-last | WRONG-ON-PURPOSE | norm | s1@MK@' | run_table H2)"
case "$H2_OUT" in *"FAIL: H2 H2-last"*) pass "H2 a wrong want on the unterminated last row fails" ;;
    *) fail "H2 a wrong want on the unterminated last row went unasserted: $H2_OUT" ;; esac
case "$H2_OUT" in *"PASS: H2 H2-first"*) pass "H2 the rows before it still pass" ;;
    *) fail "H2 the first row did not pass: $H2_OUT" ;; esac

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
