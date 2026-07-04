#!/bin/bash
# tests/property-bash-write-patterns-fail-closed.sh
# Tests: hooks/lib/bash-write-patterns.js, hooks/lib/command-ir.js
# Tags: hook, classify, property-test, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - parseFailure===true forcing "write" (requires IR implementation in write-code)
# - Real hook registration verification (requires real enforce-worktree session)
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
#
# Property: for ANY input string, classify(input) must never throw and must
# return exactly one of "read" | "write" (fail-closed classifier invariant).
set -u

# Skip if node or fast-check not available
command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }
node -e "require('fast-check')" 2>/dev/null || { echo "SKIP: fast-check not installed (run: npm install)"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _A="$(cygpath -m "$AGENTS_DIR")"; else _A="$AGENTS_DIR"; fi
WP="${_A}/hooks/lib/bash-write-patterns.js"

run_with_timeout() {
  if [ -x "${_A}/bin/run-with-timeout.sh" ]; then "${_A}/bin/run-with-timeout.sh" 120 "$@";
  elif command -v timeout >/dev/null 2>&1; then timeout 120 "$@";
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# The property test body is emitted to a temp JS file and executed under node.
PROP_JS="$(mktemp -t bwp-prop-XXXXXX.js 2>/dev/null || echo "${TMPDIR:-/tmp}/bwp-prop-$$.js")"
cleanup() { rm -f "$PROP_JS"; }
trap cleanup EXIT

cat > "$PROP_JS" <<PROPEOF
const fc = require("fast-check");
const { classify } = require(process.argv[1]);

const VALID = new Set(["read", "write"]);

function invariant(input) {
  let out;
  try {
    out = classify(input);
  } catch (e) {
    throw new Error("classify() threw on input " + JSON.stringify(input) + ": " + e.message);
  }
  if (!VALID.has(out)) {
    throw new Error("classify() returned non-{read,write} value " + JSON.stringify(out) + " for input " + JSON.stringify(input));
  }
  return true;
}

// 1+2: arbitrary strings must never throw and must classify as read|write.
fc.assert(
  fc.property(fc.string(), (s) => invariant(s)),
  { numRuns: 500 }
);

// 3+4+5: strings dense with shell metacharacters — adversarial fail-closed check.
const meta = "><|&;\` \$\\\\'\"\n\r\t\0";
fc.assert(
  fc.property(fc.stringOf(fc.constantFrom(...meta.split(""))), (s) => invariant(s)),
  { numRuns: 500 }
);

// Mixed alphanumeric + metacharacter noise to exercise partial-command shapes.
fc.assert(
  fc.property(
    fc.stringOf(fc.constantFrom(...(meta + "abcdefgHIJK0129/-.=").split(""))),
    (s) => invariant(s)
  ),
  { numRuns: 500 }
);

console.log("PASS: fail-closed invariant held across 1500 generated inputs");
PROPEOF

if run_with_timeout node "$PROP_JS" "$WP"; then
  echo ""
  echo "Results: 1 passed, 0 failed"
  exit 0
else
  echo ""
  echo "Results: 0 passed, 1 failed"
  exit 1
fi
