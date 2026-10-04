#!/usr/bin/env bash
# tests/bin/fix-1378-worker-log-tail-integrity.sh
# Tests: bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/emit.js
# Tags: worker-dispatch, test-runner, log-tail, contract, TL2, scope:common
# #1378 S4-1: worker lifts RUN_CONTRACT from raw output; renderer emits exactly
# one contract line at top. Two copies → ambiguous → demote. Tests pin BOTH:
# contract line absent from log_tail AND surrounding content preserved.
# TL3 gap: run-all.sh format drift — gated in TL3-worker-dispatch-run-tests.sh.
set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
PRELOAD="$AGENTS_DIR/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$DISPATCH_JS" ] || [ ! -f "$PRELOAD" ]; then
    fail "0/prerequisites" "dispatcher=$DISPATCH_JS stub=$PRELOAD"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-lt-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md).
export WORKFLOW_PLANS_DIR="$(nodepath "$TMPD/plans")"
export WORKFLOW_STATE_DIR="$TMPD/workflow-state"
mkdir -p "$TMPD/plans" "$TMPD/workflow-state"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

REPO_RAW="$TMPD/repo"
mkdir -p "$REPO_RAW/tests"
git -C "$REPO_RAW" init -q -b main
git -C "$REPO_RAW" config user.email "test@example.com"
git -C "$REPO_RAW" config user.name "Test"
git -C "$REPO_RAW" config core.hooksPath /dev/null
printf '#!/usr/bin/env bash\nexit 0\n' > "$REPO_RAW/tests/run-all.sh"
REPO="$(nodepath "$REPO_RAW")"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"
printf '%s' "{\"cwd\":\"$REPO\",\"timeout_seconds\":30}" > "$TMPD/plans/lt.json"
PAYLOAD="$(nodepath "$TMPD/plans/lt.json")"

DOUT=""
# set_run <exit-status> <line>...
set_run() {
    local status="$1"; shift
    run_with_timeout 30 node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[1], JSON.stringify([{
  status: Number(process.argv[2]),
  stdout: process.argv.slice(3).join("\n") + "\n",
}]));
' "$(nodepath "$CANNED")" "$status" "$@"
}
dispatch() {
    : > "$CALLLOG"
    DOUT="$(run_with_timeout 90 env \
        "WD_SPAWN_MODULE=$(nodepath "$AGENTS_DIR/bin/worker-dispatch/spawn.js")" \
        "WD_CANNED=$(nodepath "$CANNED")" \
        "WD_CALL_LOG=$(nodepath "$CALLLOG")" \
        node -r "$(nodepath "$PRELOAD")" "$(nodepath "$DISPATCH_JS")" \
        test-runner "$REPO" "$PAYLOAD" 2>/dev/null)" || true
}
# Everything after the `log_tail: |` marker, i.e. the block scalar body.
tail_body() { printf '%s\n' "$DOUT" | sed -n '/^log_tail: |$/,$p' | tail -n +2; }
# Contract lines anywhere in the emitted YAML, counted with an independent regex.
contract_count() {
    printf '%s\n' "$1" | grep -c -E '^[[:space:]]*RUN_CONTRACT: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+ EXECUTED=[0-9]+' | tr -d ' '
}
count_in_tail() { tail_body | grep -c -E "$1" | tr -d ' '; }

# A ≥40-suite run: 45 green suites, one failing suite with its own output, then
# the trailing summary + contract. The failure and the contract are deliberately
# adjacent so an over-greedy removal takes the evidence with it.
build_lines() {
    LINES=()
    local i
    for i in $(seq 1 45); do LINES+=("PASS: tests/green-$i.sh"); done
    LINES+=("FAIL: tests/alpha.sh (exit 1)")
    LINES+=("  assertion failed: want=complete got=pending")
    LINES+=("  at tests/alpha.sh line 42")
    LINES+=("Results: PASS=45  FAIL=1  SKIP=0")
}

case_begin "test-runner-no-cap" "bin/worker-dispatch/workers/test-runner.js"

# (a)+(b)+(c)+(d) — one well-formed contract line in the suite output.
build_lines
set_run 1 "${LINES[@]}" "RUN_CONTRACT: PASS=45 FAIL=1 SKIP=0 EXECUTED=46"
dispatch

# (a) The contract survives as structured output: exactly one line, at the top,
#     where the hook's parser can see it without reading the block scalar.
assert_eq "a/exactly-one-contract-line-in-the-emitted-yaml" "1" "$(contract_count "$DOUT")"
case "$(printf '%s\n' "$DOUT" | head -1)" in
    "RUN_CONTRACT: PASS=45 FAIL=1 SKIP=0 EXECUTED=46")
        pass "a/contract-is-the-first-line-with-the-suite-s-own-numbers" ;;
    *)
        fail "a/contract-is-the-first-line-with-the-suite-s-own-numbers" \
             "got=$(printf '%s\n' "$DOUT" | head -1)" ;;
esac

# (b) …and is NOT also left inside log_tail. Asserted separately from (a):
#     (a) alone is satisfied by a renderer that emits the top line and leaves a
#     second copy below, which is precisely the ambiguous-parse regression.
assert_eq "b/log_tail-carries-no-contract-line" "0" "$(count_in_tail '^[[:space:]]*RUN_CONTRACT:')"

# (c) The failing test's own output is the reason log_tail exists. All three of
#     its lines must survive the removal.
assert_eq "c/log_tail-keeps-the-FAIL-header" "1" "$(count_in_tail '^  FAIL: tests/alpha\.sh \(exit 1\)$')"
assert_eq "c/log_tail-keeps-the-assertion-line" "1" "$(count_in_tail 'assertion failed: want=complete got=pending')"
assert_eq "c/log_tail-keeps-the-location-line" "1" "$(count_in_tail 'at tests/alpha\.sh line 42')"

# (d) The neighbouring summary lines are not collateral damage either.
assert_eq "d/log_tail-keeps-the-Results-line" "1" "$(count_in_tail '^  Results: PASS=45  FAIL=1  SKIP=0$')"
assert_eq "d/log_tail-keeps-PASS-lines" "1" "$(count_in_tail '^  PASS: tests/green-45\.sh$')"

# The bound itself must not have moved: removing one line from a 40-line window
# must not silently shrink or grow it.
assert_eq "d/log_tail-is-still-bounded-at-40-lines" "40" "$(tail_body | grep -c '' | tr -d ' ')"

# ===========================================================================
# (e) Exactly-one, applied at the WORKER rather than deferred to the hook.
#     Zero lines and two lines are both "no trustworthy contract"; emitting one
#     anyway would let the worker manufacture a verdict the suite never gave.
# ===========================================================================
build_lines
set_run 1 "${LINES[@]}"
dispatch
assert_eq "e/zero-contract-lines-yields-no-contract" "0" "$(contract_count "$DOUT")"

build_lines
set_run 1 "${LINES[@]}" \
    "RUN_CONTRACT: PASS=45 FAIL=1 SKIP=0 EXECUTED=46" \
    "RUN_CONTRACT: PASS=99 FAIL=0 SKIP=0 EXECUTED=99"
dispatch
assert_eq "e/two-contract-lines-yields-no-contract" "0" "$(contract_count "$DOUT")"
# A forged second line must not be laundered into log_tail as fact either — but
# suppression is only correct when the run's real diagnostics still survive, so
# the status line is checked alongside it.
assert_eq "e/ambiguous-run-still-reports-its-status" "fail" \
    "$(printf '%s\n' "$DOUT" | sed -n 's/^status: //p' | head -1)"


# (f) MAX_FAILING / MAX_FAILING_TESTS / slice(0, 10) must be absent.
# Their presence means boundary tests (g)/(h) would test an already-capped
# value and pass for the wrong reason.
RUNNER_JS="$AGENTS_DIR/bin/worker-dispatch/workers/test-runner.js"
EMIT_JS="$AGENTS_DIR/bin/worker-dispatch/emit.js"

if grep -qF 'MAX_FAILING' "$RUNNER_JS" 2>/dev/null; then
    fail "f/MAX_FAILING-absent-in-test-runner" "constant still present in test-runner.js"
else
    pass "f/MAX_FAILING-absent-in-test-runner"
fi
if grep -qF 'MAX_FAILING_TESTS' "$EMIT_JS" 2>/dev/null; then
    fail "f/MAX_FAILING_TESTS-absent-in-emit" "constant still present in emit.js"
else
    pass "f/MAX_FAILING_TESTS-absent-in-emit"
fi
if grep -qF 'slice(0, 10)' "$EMIT_JS" 2>/dev/null; then
    fail "f/slice-0-10-absent-in-emit" "slice(0, 10) still present in emit.js"
else
    pass "f/slice-0-10-absent-in-emit"
fi

# (g) Exactly 10: old cap was 10 — behaviour unchanged.
# (h) Exactly 11: first value the old cap would have dropped.
# (i) 15 items: end-to-end assertion that no residual cap exists.
parse_failing_count() {
    local n="$1"
    run_with_timeout 30 node -e '
try {
  var m = require(process.argv[1]);
  if (typeof m.parseFailingTests !== "function") {
    process.stdout.write("ERR:not-exported"); process.exit(0);
  }
  var lines = [];
  for (var i = 1; i <= parseInt(process.argv[2], 10); i++) {
    lines.push("FAIL: tests/suite-" + i + ".sh (exit 1)");
  }
  process.stdout.write(String(m.parseFailingTests(lines).length));
} catch (e) { process.stdout.write("ERR:" + e.message); }
' "$(nodepath "$RUNNER_JS")" "$n" 2>/dev/null
}

assert_eq "g/parseFailingTests-boundary-10" "10" "$(parse_failing_count 10)"
assert_eq "h/parseFailingTests-boundary-11" "11" "$(parse_failing_count 11)"
assert_eq "i/parseFailingTests-15-all-returned" "15" "$(parse_failing_count 15)"

case_end

case_begin "emit-no-cap" "bin/worker-dispatch/emit.js"

# (j) emit.js renders all 15 failing_tests entries end-to-end.
# Old MAX_FAILING_TESTS=10 silently dropped entries 11-15 before rendering.
build_lines_n() {
    LINES=()
    local n="$1" i
    for i in $(seq 1 "$n"); do LINES+=("FAIL: tests/suite-$i.sh (exit 1)"); done
    LINES+=("Results: PASS=0  FAIL=$n  SKIP=0")
}

build_lines_n 15
set_run 1 "${LINES[@]}" "RUN_CONTRACT: PASS=0 FAIL=15 SKIP=0 EXECUTED=15"
dispatch

_ft_count=$(printf '%s\n' "$DOUT" | grep -cF "  - '" 2>/dev/null | tr -d ' ')
assert_eq "j/emit-renders-all-15-entries" "15" "$_ft_count"

_ft_first=$(printf '%s\n' "$DOUT" | grep "^  - '" | head -1)
_ft_last=$(printf '%s\n' "$DOUT" | grep "^  - '" | tail -1)
assert_eq "j2/first-failing-entry-intact" "  - 'tests/suite-1.sh'" "$_ft_first"
assert_eq "j2/last-failing-entry-intact" "  - 'tests/suite-15.sh'" "$_ft_last"

# (k) Header field order: RUN_CONTRACT → status → … → failing_tests → log_tail.
# Positional order is load-bearing — hook's parser scopes to header by position.
build_lines_n 3
set_run 1 "${LINES[@]}" "RUN_CONTRACT: PASS=0 FAIL=3 SKIP=0 EXECUTED=3"
dispatch

_ln_contract=$(printf '%s\n' "$DOUT" | grep -n '^RUN_CONTRACT:' | head -1 | cut -d: -f1)
_ln_status=$(printf '%s\n' "$DOUT" | grep -n '^status:' | head -1 | cut -d: -f1)
_ln_failing=$(printf '%s\n' "$DOUT" | grep -n '^failing_tests' | head -1 | cut -d: -f1)
_ln_logtail=$(printf '%s\n' "$DOUT" | grep -n '^log_tail: |' | head -1 | cut -d: -f1)

if [ -n "$_ln_contract" ] && [ -n "$_ln_status" ] && [ "$_ln_contract" -lt "$_ln_status" ]; then
    pass "k/contract-before-status"
else
    fail "k/contract-before-status" "contract=$_ln_contract status=$_ln_status"
fi
if [ -n "$_ln_failing" ] && [ -n "$_ln_logtail" ] && [ "$_ln_failing" -lt "$_ln_logtail" ]; then
    pass "k/failing-tests-before-log-tail"
else
    fail "k/failing-tests-before-log-tail" "failing=$_ln_failing logtail=$_ln_logtail"
fi
_ln_prev=$((_ln_logtail - 1))
_prev_line=$(printf '%s\n' "$DOUT" | sed -n "${_ln_prev}p")
case "$_prev_line" in
    "  - "* | "failing_tests: []")
        pass "k/failing-tests-is-last-field-before-log-tail" ;;
    *)
        fail "k/failing-tests-is-last-field-before-log-tail" "got='$_prev_line'" ;;
esac

case_end

# #2431: /run-tests baseline classification needs EVERY failing path, so neither the
# parser nor the YAML renderer may truncate or reorder the list.
case_begin "parser-keeps-every-fail-line" "bin/worker-dispatch/workers/test-runner.js"
for n in 11 25; do
    got="$(run_with_timeout 30 node -e '
const { parseFailingTests } = require(process.argv[1]);
const n = Number(process.argv[2]);
const lines = [];
for (let i = 1; i <= n; i++) lines.push("FAIL: tests/s" + i + ".sh (exit 1)", "noise " + i);
const out = parseFailingTests(lines);
const inOrder = out.every((p, i) => p === "tests/s" + (i + 1) + ".sh");
process.stdout.write(out.length + ":" + inOrder);
' "$(nodepath "$RUNNER_JS")" "$n" 2>&1)"
    assert_eq "P$n/parseFailingTests-returns-all-$n-in-order" "$n:true" "$got"
done
case_end

case_begin "renderer-lists-every-failing-test" "bin/worker-dispatch/emit.js"
RENDERED="$(run_with_timeout 30 node -e '
const { renderTestRunnerYaml } = require(process.argv[1]);
const failingTests = [];
for (let i = 1; i <= 15; i++) failingTests.push("tests/s" + i + ".sh");
process.stdout.write(renderTestRunnerYaml({
  status: "fail", exitCode: 1, durationSeconds: 3, summary: "PASS=0 FAIL=15 SKIP=0",
  failingTests, logTail: ["last line"],
}));
' "$(nodepath "$EMIT_JS")" 2>&1)"
assert_eq "R1/renderTestRunnerYaml-lists-all-15" "15" \
    "$(printf '%s\n' "$RENDERED" | grep -c "^  - 'tests/s[0-9]*\.sh'$" | tr -d ' ')"
if printf '%s\n' "$RENDERED" | grep -qF "  - 'tests/s15.sh'"; then
    pass "R2/15th-failing-test-rendered-not-capped"
else
    fail "R2/15th-failing-test-rendered-not-capped" "tests/s15.sh missing"
fi
order="$(printf '%s\n' "$RENDERED" | grep -oE '^(status|exit_code|duration_seconds|summary|failing_tests|log_tail):' | tr -d ':' | tr '\n' ' ')"
assert_eq "R3/header-order-unchanged-without-contract" \
    "status exit_code duration_seconds summary failing_tests log_tail " "$order"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
