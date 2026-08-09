#!/bin/bash
# tests/unit-command-ir.sh
# Tests: hooks/lib/command-ir.js
# Tags: hook, classify, unit, argv-raw, TL1, scope:issue-specific
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

# ===========================================================================
# Group R — argv/argvRaw positional-correspondence invariant (#1273 C1)
#
# stripEnvPrefix() and resolveEffectiveSegment()'s control-keyword branch shift
# `argv` without shifting `argvRaw`, so after either transform `argv[i]` and
# `argvRaw[i]` describe different tokens and `cmd0Raw` still points at the
# stripped keyword/assignment. The execution-position classifier indexes the two
# arrays against each other, so the invariant "same length, same position" must
# hold on the resolved segment — and a segment whose argvRaw is missing or short
# must fall back to a copy of argv rather than throw (the same module backs
# three security hooks; a TypeError there fails the guard open).
# ===========================================================================

RAW_PROBE_JS="$(mktemp -t irprobe.XXXXXX.js 2>/dev/null || echo "${TMPDIR:-/tmp}/irprobe-$$.js")"
trap 'rm -f "$RAW_PROBE_JS"' EXIT
cat > "$RAW_PROBE_JS" <<'PROBE'
"use strict";
// argv/argvRaw correspondence probe.
//   node probe.js <command-ir.js> parse "<command>"
//   node probe.js <command-ir.js> synth '<segment-json>'
// Prints cmd0|cmd0Raw|argvLen|argvRawLen|argvRaw0|argv0, or THREW on exception.
const irPath = process.argv[2];
const mode = process.argv[3];
const arg = process.argv[4];
let eff = null;
try {
  const { parse, resolveEffectiveSegment } = require(irPath);
  if (mode === "synth") {
    eff = resolveEffectiveSegment(JSON.parse(arg));
  } else {
    const ir = parse(arg);
    for (const seg of ir.segments) {
      const r = resolveEffectiveSegment(seg);
      if (r !== null && r.cmd0 !== "") { eff = r; break; }
    }
  }
} catch (e) {
  process.stdout.write("THREW");
  process.exit(0);
}
if (eff === null) { process.stdout.write("NULL"); process.exit(0); }
const raw = Array.isArray(eff.argvRaw) ? eff.argvRaw : null;
process.stdout.write([
  String(eff.cmd0),
  String(eff.cmd0Raw),
  String(Array.isArray(eff.argv) ? eff.argv.length : -1),
  String(raw === null ? -1 : raw.length),
  raw === null || raw.length === 0 ? "(none)" : String(raw[0]),
  Array.isArray(eff.argv) && eff.argv.length > 0 ? String(eff.argv[0]) : "(none)",
].join("|"));
PROBE

raw_probe() {
  run_with_timeout node "$RAW_PROBE_JS" "$IR_JS" "$1" "$2" 2>/dev/null
}

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"
  else fail "$name (want=$(printf '%q' "$want") got=$(printf '%q' "$got"))"; fi
}

# label~mode~input~expected  (cmd0|cmd0Raw|argvLen|argvRawLen|argvRaw[0]|argv[0])
while IFS='~' read -r label mode input expected; do
  [ -z "$label" ] && continue
  case "$label" in '#'*) continue ;; esac
  assert_eq "$label" "$expected" "$(raw_probe "$mode" "$input")"
done <<'TABLE'
R1: env prefix keeps argv/argvRaw aligned~parse~A=1 B=2 bash tests/x.sh~bash|bash|1|1|tests/x.sh|tests/x.sh
R2: env prefix preserves the quoted raw spelling~parse~A=1 bash "tests/x.sh"~bash|bash|1|1|"tests/x.sh"|tests/x.sh
R3: control body keyword keeps argv/argvRaw aligned~parse~for f in x; do bash tests/x.sh; done~bash|bash|1|1|tests/x.sh|tests/x.sh
R4: control keyword + env prefix combined~parse~for f in x; do A=1 bash tests/x.sh; done~bash|bash|1|1|tests/x.sh|tests/x.sh
R5: condition header + env prefix combined~parse~while A=1 node tests/y.js; do echo hi; done~node|node|1|1|tests/y.js|tests/y.js
R6: missing argvRaw falls back to a copy of argv~synth~{"cmd0":"A=1","argv":["bash","tests/x.sh"],"cmd0Raw":"A=1"}~bash|bash|1|1|tests/x.sh|tests/x.sh
R7: short argvRaw falls back to a copy of argv~synth~{"cmd0":"do","argv":["bash","tests/x.sh"],"cmd0Raw":"do","argvRaw":["do"]}~bash|bash|1|1|tests/x.sh|tests/x.sh
TABLE

# The fallback must be reached WITHOUT an exception — asserted separately from the
# value check above so a crash is never reported as a mere value mismatch.
for _synth in \
  '{"cmd0":"A=1","argv":["bash","tests/x.sh"],"cmd0Raw":"A=1"}' \
  '{"cmd0":"do","argv":["bash","tests/x.sh"],"cmd0Raw":"do","argvRaw":["do"]}'
do
  _got="$(raw_probe synth "$_synth")"
  if [ "$_got" = "THREW" ]; then
    fail "R8: malformed argvRaw must not throw (input=$_synth)"
  else
    pass "R8: malformed argvRaw must not throw (input=$_synth)"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
