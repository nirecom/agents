#!/bin/bash
# tests/unit-command-ir.sh
# Tests: hooks/lib/command-ir.js
# Tags: hook, classify, unit, scope:issue-specific
#
# Unit tests for hasUnclosedQuote (tested indirectly via parse().parseFailure,
# since hasUnclosedQuote is private). When hasUnclosedQuote returns true,
# parse() short-circuits with parseFailure: true (fail-closed).
#
# M1: ANSI-C quoting $'...' coverage (issues #1457 / #1568).
# Fix 1: hasUnclosedQuote correctly handles $'...' ANSI-C spans and unquoted \x escapes.
# Expected: UC1 parseFailure:false (Fix 1 implemented).
set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _A="$(cygpath -m "$AGENTS_DIR")"; else _A="$AGENTS_DIR"; fi
IR_JS="${_A}/hooks/lib/command-ir.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}

# Parse a command and return the parseFailure field (true/false).
parse_failure() {
  run_with_timeout node -e "
    const { parse } = require(process.argv[1]);
    const result = parse(process.argv[2]);
    console.log(String(result.parseFailure));
  " -- "$IR_JS" "$1" 2>/dev/null
}

assert_parse_failure() {
  local input="$1" expected="$2" label="$3"
  local got; got="$(parse_failure "$input")"
  if [ "$got" = "$expected" ]; then
    pass "$label"
  else
    fail "$label (expected parseFailure=$expected, got=$got)"
  fi
}

# TL3 gap (what this test does NOT catch):
# - real Claude Code session where hasUnclosedQuote interacts with the full hook
#   pipeline (enforce-worktree.js PreToolUse) when ANSI-C input is passed via
#   the Bash tool — including multi-segment commands and hook environment state
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration

# Table-driven parse-failure cases: input|expected|label
# Each row is pipe-separated; label must not contain a pipe character.
while IFS='|' read -r input expected label; do
  assert_parse_failure "$input" "$expected" "$label"
done <<'TABLE'
$'it'\''s fine'|false|UC1: ANSI-C quoting $'...' with escaped single quote
$'unclosed string|true|UC2: unclosed ANSI-C literal is fail-closed
normal text|false|UC3: plain text has no unclosed quote
'hello world'|false|UC4: closed single-quoted string
'unclosed|true|UC5: unclosed single-quoted string is fail-closed
"hello world"|false|UC6: closed double-quoted string
"unclosed|true|UC7: unclosed double-quoted string is fail-closed
TABLE

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
