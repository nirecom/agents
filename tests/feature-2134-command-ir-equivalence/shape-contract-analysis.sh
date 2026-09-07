#!/usr/bin/env bash
# tests/feature-2134-command-ir-equivalence/shape-contract-analysis.sh
# Tests: hooks/lib/command-ir.js, hooks/lib/command-ir/analysis.js
# Tags: hook, command-ir, equivalence, snapshot, TL1, scope:issue-specific
#
# Covers command-ir.js's analysisOf(ir) contract (Step 2 export), split out of
# shape-contract.sh's hard Step-1 pins (s01-s11) so an
# expected Step-2 RED here can't hide a real Step-1 regression there. Dispatcher registers this
# file non-blocking (PENDING), same mechanism as ownership-doc.sh, until the Step 2 landing doc
# lands. Failure reports attributably ("MISSING:analysisOf"/"ERROR:<msg>"), not a silent "".

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$DIR/../.." && pwd)"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

# Fixture isolation (rules/test/fixture-isolation.md): don't pass the parent session id to the child node.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

npath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
IR_JS="$(npath "$AGENTS_DIR/hooks/lib/command-ir.js")"
RUNNER="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; ROWS=0
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name"; echo "    want: $want"; echo "    got:  $got"; FAIL=$((FAIL + 1)); fi
}

# s12: neutral default. A spread/synthetic IR that lacks a real `.analysis`
# (e.g. `{...parse(cmd)}`, which drops non-enumerable properties) must still
# get a fully-shaped, empty-valued analysis back -- a consumer that reads
# analysisOf(ir).separatorLinks.length on a degraded IR must see 0, not throw.
ANALYSIS_DEFAULT="$(bash "$RUNNER" 30 node -e '
  const mod = require(process.argv[1]);
  if (typeof mod.analysisOf !== "function") { process.stdout.write("MISSING:analysisOf"); process.exit(0); }
  try {
    const ir = { ...mod.parse(process.argv[2]) }; // spread drops non-enumerable analysis
    process.stdout.write(JSON.stringify(mod.analysisOf(ir)));
  } catch (e) { process.stdout.write("ERROR:" + e.message); }
' "$IR_JS" 'echo a && echo b' 2>/dev/null)"
ROWS=$((ROWS + 1))
assert_eq "s12-analysisOf: neutral default for a spread IR lacking .analysis" \
    '{"heredocs":[],"substitutions":[],"groups":[],"separatorLinks":[]}' "$ANALYSIS_DEFAULT"

# s13: analysis is frozen and non-enumerable on a real parse() result -- same
# concern as shape-contract.sh's s11 targetRaw pin, applied to the new top-level field so
# Step 2 cannot silently make analysis an enumerable, mutable property.
ANALYSIS_SHAPE="$(bash "$RUNNER" 30 node -e '
  const mod = require(process.argv[1]);
  if (typeof mod.analysisOf !== "function") { process.stdout.write("MISSING:analysisOf"); process.exit(0); }
  try {
    const ir = mod.parse(process.argv[2]);
    if (!("analysis" in ir)) { process.stdout.write("MISSING:ir.analysis"); process.exit(0); }
    const enumerable = Object.keys(ir).includes("analysis");
    process.stdout.write(JSON.stringify([enumerable, Object.isFrozen(ir.analysis)]));
  } catch (e) { process.stdout.write("ERROR:" + e.message); }
' "$IR_JS" 'echo a && echo b' 2>/dev/null)"
ROWS=$((ROWS + 1))
assert_eq "s13-analysisOf: ir.analysis is non-enumerable and frozen" \
    '[false,true]' "$ANALYSIS_SHAPE"

# s14: separatorLinks correctness for a LEADING and a TRAILING separator --
# the null-segment ends are the shape a consumer must not misread as "no
# separator" (leading) or "no downstream command" (trailing) with an index.
SEP_LINKS="$(bash "$RUNNER" 30 node -e '
  const mod = require(process.argv[1]);
  if (typeof mod.analysisOf !== "function") { process.stdout.write("MISSING:analysisOf"); process.exit(0); }
  try {
    const fmt = (cmd) => {
      const ir = mod.parse(cmd);
      const a = mod.analysisOf(ir);
      return a.separatorLinks.map(l =>
        l.index + ":" + l.sep + ":" + (l.leftSegment == null ? "-" : l.leftSegment) + ":" + (l.rightSegment == null ? "-" : l.rightSegment)
      ).join("|");
    };
    process.stdout.write(JSON.stringify([fmt("; echo a"), fmt("echo a;")]));
  } catch (e) { process.stdout.write("ERROR:" + e.message); }
' "$IR_JS" 2>/dev/null)"
ROWS=$((ROWS + 1))
assert_eq "s14-analysisOf: separatorLinks null-segment ends for leading/trailing separators" \
    '["0:;:-:0","0:;:0:-"]' "$SEP_LINKS"

ROWS_EXPECTED=3
if [ "$ROWS" = "$ROWS_EXPECTED" ]; then
    echo "PASS: row budget: $ROWS_EXPECTED analysis rows executed"; PASS=$((PASS + 1))
else
    echo "FAIL: row budget: executed=$ROWS expected=$ROWS_EXPECTED (an empty or unreachable table reports green otherwise)"; FAIL=$((FAIL + 1))
fi

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
