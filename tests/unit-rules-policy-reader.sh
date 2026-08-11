#!/usr/bin/env bash
# tests/unit-rules-policy-reader.sh
# Tests: hooks/lib/rules-policy-reader.js, hooks/lib/rules-injection-policy.js
# Tags: rules-injection, policy-reader, parser, regex, table-driven, parse-dont-evaluate, canary, mutation-probe, TL2, scope:common
#
# WHY (CPR-WPH): hooks/lib/rules-policy-reader.js is the ONLY thing that lets the
# pre-commit checker and the InstructionsLoaded audit hook read a contributor-editable
# declaration file without executing it. Every safety property those two consumers claim
# — "a pull request cannot run code on a reviewer's machine merely by being checked out"
# — rests on this module's four text parsers being both correct and non-evaluating.
# Until now it had zero direct coverage: the consumers' canaries prove the body did not
# run, but nothing proved the parsers actually recover the declarations, and nothing
# pinned their edges (empty string vs absent, /g statelessness, a slash in a character
# class, an unparseable declaration vs an unreadable file).
#
# This is a parser/regex target, so the table-driven pattern from
# skills/_shared/test-design/parser-regex-tests.md is used throughout: each case group is
# a JS `cases` table whose harness emits one ROW per case, and the case NAME is injected
# into every assertion message on the bash side.
#
# Layer: TL2 (real node subprocess, real fixture policy files on disk; the parsers
# themselves are pure, but loadPolicyAsData reads real bytes and the canary cases need a
# real module body that a real require() would have executed).
# Dispatcher only — the cases live in tests/unit-rules-policy-reader/.
#
# TL3 gap (what this test does NOT catch):
# - Whether the real consumers (bin/check-on-demand-rules.sh, hooks/instructions-loaded-audit.js)
#   actually route through this reader in a live pre-commit / live session, rather than
#   reintroducing a require() of the policy path on some branch this file never sees.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/unit-rules-policy-reader"
READER="$AGENTS_DIR/hooks/lib/rules-policy-reader.js"
POLICY="$AGENTS_DIR/hooks/lib/rules-injection-policy.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# The inline assert_eq required by skills/_shared/test-design/parser-regex-tests.md:
# defined per test file, no shared library, case name in every message.
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name (got=$got)"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

# --- implementation guard: a missing target must fail loudly, never look like a skip ---
MISSING=0
for f in "$READER" "$POLICY"; do
    [ -f "$f" ] || { echo "FAIL: IMPLEMENTATION MISSING: $f"; MISSING=1; }
done
if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "Results: 0 passed, 1 failed (target not yet implemented)"
    exit 1
fi

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md). This file spawns plain node
# harnesses rather than hooks, so it pins NEITHER half of the workflow-dir pair — pinning
# one without the other is the contamination bug. What it does do is drop the inherited
# session ids and run every harness from a neutral CWD, so nothing here can resolve the
# live session or the real repo by accident.
unset CLAUDE_SESSION_ID || true
unset CLAUDE_CODE_SESSION_ID || true

READER_NODE="$(node_path "$READER")"
POLICY_NODE="$(node_path "$POLICY")"

# run_rows <js-file> [args...] -> harness stdout+stderr; argv[2] is always the reader.
run_rows() {
    local js="$1"; shift
    ( cd "$BASE" && node "$(node_path "$js")" "$READER_NODE" "$@" ) 2>&1
}

# assert_rows <group> <report> <want-count>
# Iterates the harness's `ROW|<name>|<want>|<got>` lines, asserting each BY NAME, then
# proves the table actually ran: a harness that died after two rows would otherwise leave
# a silently short but entirely green group.
assert_rows() {
    local group="$1" report="$2" want_n="$3" n=0 tag name want got guard
    while IFS='|' read -r tag name want got; do
        [ "$tag" = "ROW" ] || continue
        n=$((n + 1))
        assert_eq "$group [$name]" "$want" "$got"
    done <<ROWS
$report
ROWS
    if [ "$n" -eq "$want_n" ]; then
        pass "$group: all $n table rows were evaluated"
    else
        fail "$group: want $want_n table rows, evaluated $n — the table did not run; report: $(printf '%s' "$report" | tr '\n' ' ' | cut -c1-500)"
    fi
    # The ROW encoding is pipe-separated, so a `|` inside a want or got value would split
    # the field and could make two different values compare equal. The harness counts any
    # such value; a non-zero count invalidates the group.
    guard="$(printf '%s\n' "$report" | grep '^PIPEGUARD=' | head -1 | cut -d= -f2-)"
    if [ "${guard:-0}" = "0" ]; then
        pass "$group: no table value contains the ROW field separator"
    else
        fail "$group: $guard table value(s) contain a '|' — the ROW encoding cannot be trusted for this group"
    fi
}

# shellcheck source=./unit-rules-policy-reader/cases-scalars.sh
. "$SCRIPT_DIR/cases-scalars.sh"
# shellcheck source=./unit-rules-policy-reader/cases-collections.sh
. "$SCRIPT_DIR/cases-collections.sh"
# cases-load.sh runs LAST: it is the only group that writes fixture policy files with
# live module bodies and asserts on the ABSENCE of their side effects.
# shellcheck source=./unit-rules-policy-reader/cases-load.sh
. "$SCRIPT_DIR/cases-load.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
