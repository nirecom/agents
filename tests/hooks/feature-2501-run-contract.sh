#!/usr/bin/env bash
# tests/hooks/feature-2501-run-contract.sh
# Tests: hooks/lib/run-contract.js
# Tags: TL1, hooks, run-contract, parser, security, scope:issue-specific
# run-contract.js (#2501 D5-1): the one RUN_CONTRACT parser. 6 fields are shape "current"; 4 fields
# are shape "legacy" with unrunnable/timeout null (never 0). Trailing text, 5 fields, unsafe integers
# and nested/indented forgeries are handled by the strict line regex and the single-line rule;
# formatContract keeps the shape.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 77; }

RC_JS="$SCRIPT_CHECKOUT_ROOT/hooks/lib/run-contract.js"
T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT

# probe.js <module> <mode> <json-lines> — prints one canonical line for the call.
cat >"$T/probe.js" <<'EOF'
const m = require(process.argv[2]);
const mode = process.argv[3];
const lines = JSON.parse(process.argv[4]);
const show = (c) => c === null || c === undefined ? "null"
  : ["shape", "pass", "fail", "skip", "executed", "unrunnable", "timeout"].map((k) => `${k}=${c[k]}`).join(" ");
if (mode === "parse") console.log(show(m.parseContractLine(lines[0])));
else if (mode === "find") { const r = m.findSingleContract(lines); console.log(r && r.reason ? `reason=${r.reason}` : show(r)); }
else if (mode === "format") console.log(JSON.stringify(m.formatContract(m.parseContractLine(lines[0]))));
else if (mode === "prefix") console.log(lines.map((l) => (m.CONTRACT_PREFIX_RE.test(l) ? 1 : 0)).join(""));
EOF

# probe <mode> <line>... — the probe's output for these lines (or <error> when the module throws).
probe() {
  local mode="$1" json
  shift
  json="$(node -e 'console.log(JSON.stringify(process.argv.slice(1)))' -- "$@")"
  node "$(np "$T/probe.js")" "$(np "$RC_JS")" "$mode" "$json" 2>/dev/null | tr -d '\r' || printf '<error>'
}

C6="RUN_CONTRACT: PASS=3 FAIL=1 SKIP=2 EXECUTED=6 UNRUNNABLE=1 TIMEOUT=0"
C4="RUN_CONTRACT: PASS=3 FAIL=0 SKIP=2 EXECUTED=5"

case_begin "module-present" "hooks/lib/run-contract.js"
if [ -f "$RC_JS" ]; then pass "run-contract.js present"; else fail "run-contract.js missing" "$RC_JS"; fi
case_end

case_begin "parse-line-shapes" "hooks/lib/run-contract.js"
# Table: <label>|<line>|<expected probe output>.
while IFS='|' read -r label line want; do
  [ -n "$label" ] || continue
  assert_eq "$label: $(probe parse "$line")" "$label: $want"
done <<'ROWS'
current|RUN_CONTRACT: PASS=3 FAIL=1 SKIP=2 EXECUTED=6 UNRUNNABLE=1 TIMEOUT=0|shape=current pass=3 fail=1 skip=2 executed=6 unrunnable=1 timeout=0
legacy|RUN_CONTRACT: PASS=3 FAIL=0 SKIP=2 EXECUTED=5|shape=legacy pass=3 fail=0 skip=2 executed=5 unrunnable=null timeout=null
indented-current|  	RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0|shape=current pass=1 fail=0 skip=0 executed=1 unrunnable=0 timeout=0
trailing-blank|RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0  |shape=current pass=1 fail=0 skip=0 executed=1 unrunnable=0 timeout=0
five-fields|RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0|null
trailing-text|RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 extra|null
legacy-trailing-text|RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 (forged)|null
unsafe-integer|RUN_CONTRACT: PASS=9007199254740993 FAIL=0 SKIP=0 EXECUTED=9007199254740993 UNRUNNABLE=0 TIMEOUT=0|null
negative|RUN_CONTRACT: PASS=-1 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=0 TIMEOUT=0|null
reordered|RUN_CONTRACT: FAIL=0 PASS=1 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0|null
prefixed-text|echo RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0|null
masked|[masked] RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0|null
ROWS
case_end

case_begin "self-inconsistent-counts-are-no-contract" "hooks/lib/run-contract.js"
# EXECUTED is PASS+FAIL+SKIP in both shapes, and TIMEOUT is a subset of FAIL (a timed-out unit
# counts as FAIL): a line breaking either is not a contract, so it can never complete run_tests.
# Table: <label>|<line>|<expected probe output>.
while IFS='|' read -r label line want; do
  [ -n "$label" ] || continue
  assert_eq "$label: $(probe parse "$line")" "$label: $want"
done <<'ROWS'
executed-above-sum|RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=5 UNRUNNABLE=0 TIMEOUT=0|null
executed-below-sum|RUN_CONTRACT: PASS=3 FAIL=1 SKIP=1 EXECUTED=4 UNRUNNABLE=0 TIMEOUT=0|null
executed-counts-unrunnable|RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=2 UNRUNNABLE=1 TIMEOUT=0|null
legacy-executed-mismatch|RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=2|null
timeout-above-fail|RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=1|null
timeout-above-nonzero-fail|RUN_CONTRACT: PASS=0 FAIL=1 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=2|null
timeout-equals-fail|RUN_CONTRACT: PASS=0 FAIL=2 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=2|shape=current pass=0 fail=2 skip=0 executed=2 unrunnable=0 timeout=2
all-zero|RUN_CONTRACT: PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=0 TIMEOUT=0|shape=current pass=0 fail=0 skip=0 executed=0 unrunnable=0 timeout=0
ROWS
assert_eq "find inconsistent alone: $(probe find "RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=5 UNRUNNABLE=0 TIMEOUT=0")" \
  "find inconsistent alone: reason=invalid"
case_end

case_begin "trailing-cr-literal" "hooks/lib/run-contract.js"
# A heredoc row cannot carry a raw CR, so the CRLF line is built with printf here.
assert_eq "crlf: $(probe parse "$(printf 'RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0\r')")" \
  "crlf: shape=current pass=1 fail=0 skip=0 executed=1 unrunnable=0 timeout=0"
case_end

case_begin "find-single-contract" "hooks/lib/run-contract.js"
assert_eq "one current: $(probe find "PASS: a.sh" "$C6" "")" \
  "one current: shape=current pass=3 fail=1 skip=2 executed=6 unrunnable=1 timeout=0"
assert_eq "one legacy: $(probe find "$C4")" \
  "one legacy: shape=legacy pass=3 fail=0 skip=2 executed=5 unrunnable=null timeout=null"
assert_eq "none: $(probe find "PASS: a.sh" "Results: PASS=1")" "none: reason=absent"
# Security: a test that prints its own contract (nested run, forged line) makes the run ambiguous.
assert_eq "two lines: $(probe find "  $C6" "$C6")" "two lines: reason=ambiguous"
assert_eq "forged + real: $(probe find "RUN_CONTRACT: PASS=99 FAIL=0 SKIP=0 EXECUTED=99 UNRUNNABLE=0 TIMEOUT=0" "$C6")" \
  "forged + real: reason=ambiguous"
assert_eq "loose but not strict: $(probe find "RUN_CONTRACT: PASS=1 FAIL=0 bogus")" "loose but not strict: reason=invalid"
assert_eq "five fields alone: $(probe find "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0")" "five fields alone: reason=invalid"
case_end

case_begin "prefix-regex-is-loose" "hooks/lib/run-contract.js"
assert_eq "prefix: $(probe prefix "$C6" "  RUN_CONTRACT: junk" "RUN_CONTRACT:" "x RUN_CONTRACT: y" "[masked] RUN_CONTRACT:")" "prefix: 11100"
case_end

case_begin "format-keeps-shape" "hooks/lib/run-contract.js"
assert_eq "format current: $(probe format "$C6")" "format current: \"$C6\""
assert_eq "format legacy: $(probe format "$C4")" "format legacy: \"$C4\""
assert_eq "format indented current: $(probe format "   $C6")" "format indented current: \"$C6\""
case_end

case_begin "format-is-idempotent" "hooks/lib/run-contract.js"
once="$(node -e 'const m=require(process.argv[1]);const a=m.formatContract(m.parseContractLine(process.argv[2]));const b=m.formatContract(m.parseContractLine(a));console.log(a===b?"same":"differs:"+a+"|"+b)' "$(np "$RC_JS")" "$C6" 2>/dev/null | tr -d '\r')"
assert_eq "idempotent: $once" "idempotent: same"
case_end

echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
