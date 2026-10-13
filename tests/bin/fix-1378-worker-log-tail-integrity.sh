#!/usr/bin/env bash
# tests/bin/fix-1378-worker-log-tail-integrity.sh
# Tests: bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/emit.js
# Tags: worker-dispatch, test-runner, log-tail, contract, TL2, scope:common
# #1378 S4-1: worker lifts RUN_CONTRACT from raw output; renderer emits exactly
# one contract line at top. Two copies → ambiguous → demote. Tests pin BOTH:
# contract line absent from log_tail AND surrounding content preserved.
# TL3 gap: run-all.sh format drift — gated in TL3-worker-dispatch-run-tests.sh.
set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }
DISPATCH_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch.js"
PRELOAD="$SCRIPT_CHECKOUT_ROOT/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"
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
unset CLAUDE_CODE_SESSION_ID

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
        "WD_SPAWN_MODULE=$(nodepath "$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/spawn.js")" \
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
RUNNER_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/workers/test-runner.js"
EMIT_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/emit.js"

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

# #2501 D5-3: the 6-field contract (UNRUNNABLE / TIMEOUT), status `unrunnable`, the
# `Missing runtimes:` summary, and case-level result lines kept out of log_tail.
yaml_status() { printf '%s\n' "$DOUT" | sed -n 's/^status: //p' | head -1; }
yaml_summary() { printf '%s\n' "$DOUT" | sed -n 's/^summary: //p' | head -1; }
first_line() { printf '%s\n' "$DOUT" | head -1; }

case_begin "test-runner-unrunnable-status" "bin/worker-dispatch/workers/test-runner.js"
set_run 0 "PASS: tests/a.sh" \
    "UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)" \
    "UNRUNNABLE: tests/q.Tests.ps1 (missing: Pester>=5.0)" \
    "Missing runtimes: Pester>=5.0 (2 files)" \
    "Results: PASS=3  FAIL=0  SKIP=0  UNRUNNABLE=2  TIMEOUT=0" \
    "RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=2 TIMEOUT=0"
dispatch
assert_eq "U1/exit0-with-unrunnable-is-status-unrunnable" "unrunnable" "$(yaml_status)"
assert_eq "U1/six-field-contract-is-the-first-line" \
    "RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=2 TIMEOUT=0" "$(first_line)"
assert_eq "U1/exactly-one-contract-line" "1" "$(contract_count "$DOUT")"
case "$(yaml_summary)" in
    *"Missing runtimes: Pester>=5.0 (2 files)"*) pass "U1/summary-carries-missing-runtimes" ;;
    *) fail "U1/summary-carries-missing-runtimes" "summary=$(yaml_summary)" ;;
esac
case "$(yaml_summary)" in
    *"Missing runtimes: Pester>=5.0 (2 files); PASS=3 "*) pass "U1/missing-runtimes-precede-the-totals" ;;
    *) fail "U1/missing-runtimes-precede-the-totals" "summary=$(yaml_summary)" ;;
esac

# A real failure outranks the missing runtime.
set_run 1 "FAIL: tests/b.sh (exit 1)" \
    "UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)" \
    "Missing runtimes: Pester>=5.0 (1 file)" \
    "Results: PASS=0  FAIL=1  SKIP=0  UNRUNNABLE=1  TIMEOUT=0" \
    "RUN_CONTRACT: PASS=0 FAIL=1 SKIP=0 EXECUTED=1 UNRUNNABLE=1 TIMEOUT=0"
dispatch
assert_eq "U2/nonzero-exit-with-unrunnable-stays-fail" "fail" "$(yaml_status)"

# Symmetric control: UNRUNNABLE=0 on exit 0 is an ordinary pass.
set_run 0 "Results: PASS=2  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0" \
    "RUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0"
dispatch
assert_eq "U3/exit0-without-unrunnable-is-pass" "pass" "$(yaml_status)"
assert_eq "U3/six-field-input-renders-verbatim" \
    "RUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0" "$(first_line)"
case_end

case_begin "emit-keeps-contract-shape" "bin/worker-dispatch/emit.js"
# Legacy 4-field suite output stays 4 fields: zero-filling it would let the hook read it as current (#2501 C3).
set_run 0 "Results: PASS=4  FAIL=0  SKIP=0" "RUN_CONTRACT: PASS=4 FAIL=0 SKIP=0 EXECUTED=4"
dispatch
assert_eq "E1/four-field-input-renders-four-fields" \
    "RUN_CONTRACT: PASS=4 FAIL=0 SKIP=0 EXECUTED=4" "$(first_line)"
assert_eq "E1/four-field-input-status-pass" "pass" "$(yaml_status)"

E_RENDERED="$(run_with_timeout 30 node -e '
const { renderTestRunnerYaml } = require(process.argv[1]);
const base = { exitCode: 0, durationSeconds: 1, summary: "s", failingTests: [], logTail: ["x"] };
const out = [
  renderTestRunnerYaml({ ...base, status: "unrunnable",
    runContract: { pass: 2, fail: 1, skip: 0, executed: 3, unrunnable: 2, timeout: 1 } }),
  renderTestRunnerYaml({ ...base, status: "pass",
    runContract: { pass: 3, fail: 0, skip: 0, executed: 3 } }),
  renderTestRunnerYaml({ ...base, status: "pass",
    runContract: "PASS=1 FAIL=5 SKIP=0 EXECUTED=6 UNRUNNABLE=4 TIMEOUT=5" }),
];
process.stdout.write(out.map((y) => y.split("\n").slice(0, 2).join("|")).join("\n"));
' "$(nodepath "$EMIT_JS")" 2>&1)"
assert_eq "E2/object-with-new-fields-renders-them" \
    "RUN_CONTRACT: PASS=2 FAIL=1 SKIP=0 EXECUTED=3 UNRUNNABLE=2 TIMEOUT=1|status: unrunnable" \
    "$(printf '%s\n' "$E_RENDERED" | sed -n 1p)"
assert_eq "E3/object-without-new-fields-keeps-legacy-shape" \
    "RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3|status: pass" \
    "$(printf '%s\n' "$E_RENDERED" | sed -n 2p)"
assert_eq "E4/six-field-string-renders-verbatim" \
    "RUN_CONTRACT: PASS=1 FAIL=5 SKIP=0 EXECUTED=6 UNRUNNABLE=4 TIMEOUT=5|status: pass" \
    "$(printf '%s\n' "$E_RENDERED" | sed -n 3p)"
case_end

case_begin "test-runner-missing-runtimes-anchor" "bin/worker-dispatch/workers/test-runner.js"
# Only a line-start `Missing runtimes:` is the suite's own; the LAST one wins, and a
# neutralized nested copy (prefix `[run-all:neutralized] `) is never picked.
set_run 0 "Missing runtimes: stale>=1.0 (1 file)" \
    "Missing runtimes: Pester>=5.0 (2 files)" \
    "[run-all:neutralized] Missing runtimes: decoy>=9.9 (9 files)" \
    "Results: PASS=1  FAIL=0  SKIP=0  UNRUNNABLE=2  TIMEOUT=0" \
    "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=2 TIMEOUT=0"
dispatch
M_SUMMARY="$(yaml_summary)"
case "$M_SUMMARY" in
    *"Missing runtimes: Pester>=5.0 (2 files)"*) pass "M1/summary-has-the-last-anchored-line" ;;
    *) fail "M1/summary-has-the-last-anchored-line" "summary=$M_SUMMARY" ;;
esac
case "$M_SUMMARY" in
    *decoy*) fail "M2/summary-ignores-the-neutralized-line" "summary=$M_SUMMARY" ;;
    *"Missing runtimes:"*) pass "M2/summary-ignores-the-neutralized-line" ;;
    *) fail "M2/summary-ignores-the-neutralized-line" "no Missing runtimes in summary=$M_SUMMARY" ;;
esac
case "$M_SUMMARY" in
    *stale*) fail "M3/summary-ignores-an-earlier-anchored-line" "summary=$M_SUMMARY" ;;
    *"Missing runtimes:"*) pass "M3/summary-ignores-an-earlier-anchored-line" ;;
    *) fail "M3/summary-ignores-an-earlier-anchored-line" "no Missing runtimes in summary=$M_SUMMARY" ;;
esac
case_end

case_begin "test-runner-log-tail-drops-passing-case-lines" "bin/worker-dispatch/workers/test-runner.js"
set_run 1 "child stdout alpha" \
    "PASS: tests/a.sh" \
    "PASS tests/a.sh::c1 target=bin/x.sh" \
    "SKIP tests/a.sh::c2 target=bin/x.sh" \
    "XFAIL tests/a.sh::c3 target=bin/x.sh" \
    "child stdout beta" \
    "FAIL: tests/b.sh (exit 1)" \
    "FAIL tests/b.sh::c4 target=bin/y.sh" \
    "XPASS tests/b.sh::c5 target=bin/y.sh" \
    "Results: PASS=1  FAIL=1  SKIP=0  UNRUNNABLE=0  TIMEOUT=0" \
    "RUN_CONTRACT: PASS=1 FAIL=1 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0"
dispatch
assert_eq "L1/log_tail-drops-PASS-case-lines" "0" "$(count_in_tail '^  PASS [^ ]*::')"
assert_eq "L1/log_tail-drops-SKIP-case-lines" "0" "$(count_in_tail '^  SKIP [^ ]*::')"
assert_eq "L1/log_tail-drops-XFAIL-case-lines" "0" "$(count_in_tail '^  XFAIL [^ ]*::')"
assert_eq "L2/log_tail-keeps-FAIL-case-line" "1" "$(count_in_tail '^  FAIL tests/b\.sh::c4 target=bin/y\.sh$')"
assert_eq "L2/log_tail-keeps-XPASS-case-line" "1" "$(count_in_tail '^  XPASS tests/b\.sh::c5 target=bin/y\.sh$')"
assert_eq "L3/log_tail-keeps-file-level-FAIL-line" "1" "$(count_in_tail '^  FAIL: tests/b\.sh \(exit 1\)$')"
assert_eq "L3/log_tail-keeps-file-level-PASS-line" "1" "$(count_in_tail '^  PASS: tests/a\.sh$')"
assert_eq "L3/log_tail-keeps-child-stdout" "2" "$(count_in_tail '^  child stdout (alpha|beta)$')"
assert_eq "L4/failing_tests-lists-only-the-file" "  - 'tests/b.sh'" \
    "$(printf '%s\n' "$DOUT" | grep "^  - '" | tr -d '\r')"

# The point of the filter: 45 passing case lines must not push the failing unit's
# context out of the 40-line window.
LINES=("FAIL: tests/b.sh (exit 1)" "  assertion failed: want=x got=y")
for i in $(seq 1 45); do LINES+=("PASS tests/a.sh::case-$i target=bin/x.sh"); done
set_run 1 "${LINES[@]}" "RUN_CONTRACT: PASS=1 FAIL=1 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0"
dispatch
assert_eq "L5/failure-context-survives-many-pass-case-lines" "1" "$(count_in_tail 'assertion failed: want=x got=y')"
case_end

# Security round: FAIL_LINE_RE separators are ASCII blanks only. JS `\s` also matches NBSP,
# U+2028, U+3000 …, which run-all.sh's neutralizer need not prefix — so a child line with
# those separators would land in failing_tests as if the runner had printed it.
case_begin "fail-line-separators-are-ascii-blanks" "bin/worker-dispatch/workers/test-runner.js"
# name:hex code point:want (1 = a FAIL line, 0 = not one)
SEP_ROWS="space:0020:1 tab:0009:1 nbsp:00a0:0 lsep:2028:0 ideo:3000:0 emsp:2003:0 nnbsp:202f:0"
SEP_GOT="$(run_with_timeout 30 node -e '
const { parseFailingTests } = require(process.argv[1]);
const fs = require("fs");
const lines = [], out = [];
for (const row of process.argv[3].split(" ")) {
  const [name, hex] = row.split(":");
  const s = String.fromCodePoint(parseInt(hex, 16));
  const line = "FAIL:" + s + "tests/s.sh" + s + "(exit" + s + "1)";
  lines.push(line);
  out.push(name + "=" + parseFailingTests([line]).length);
}
fs.writeFileSync(process.argv[2], lines.join("\n") + "\n");
process.stdout.write(out.join(" "));
' "$(nodepath "$RUNNER_JS")" "$(nodepath "$TMPD/sep-lines.txt")" "$SEP_ROWS" 2>&1)"
sep_i=0
for row in $SEP_ROWS; do
    sep_i=$((sep_i + 1))
    sep_name="${row%%:*}" sep_want="${row##*:}"
    sep_js=" $SEP_GOT "
    sep_js="${sep_js#* "$sep_name"=}"
    sep_js="${sep_js%% *}"
    assert_eq "S1/$sep_name-separator-FAIL-line-match" "$sep_want" "$sep_js"
done
# Cross-check with the shell side: a line the JS parser reads as FAIL must be one the
# neutralizer prefixes, or a child could still forge it.
( . "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-report.sh" && rar_neutralize "$TMPD/sep-lines.txt" ) >"$TMPD/sep-neut.txt" 2>/dev/null
sep_i=0
for row in $SEP_ROWS; do
    sep_i=$((sep_i + 1))
    sep_name="${row%%:*}"
    sep_js=" $SEP_GOT "
    sep_js="${sep_js#* "$sep_name"=}"
    sep_js="${sep_js%% *}"
    sep_line="$(sed -n "${sep_i}p" "$TMPD/sep-neut.txt")"
    case "$sep_js:$sep_line" in
        "0:"* | "1:[run-all:neutralized] "*) pass "S2/$sep_name-js-match-implies-neutralized" ;;
        *) fail "S2/$sep_name-js-match-implies-neutralized" "js=$sep_js line=$(printf '%q' "$sep_line")" ;;
    esac
done
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
