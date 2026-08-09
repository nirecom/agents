#!/usr/bin/env bash
# tests/fix-1378-worker-log-tail-integrity.sh
# Tests: bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/emit.js
# Tags: worker-dispatch, test-runner, log-tail, contract, TL2, scope:common
#
# Issue #1378 fix, step S4-1: the worker lifts the suite's RUN_CONTRACT line out
# of the raw output and reports it as structured data, so the renderer can emit
# exactly one contract line at the top instead of leaving a second copy buried
# in `log_tail`. Two contract lines is not a cosmetic problem — the hook's
# exactly-one rule reads it as `ambiguous` and demotes, which is #1378 again.
#
# Removing something from `log_tail` is the risky half of that. `log_tail` is the
# only diagnostic a human gets when a run fails, and it is already bounded to the
# last 40 non-empty lines, so the failing test's own output sits within a few
# lines of the contract. A removal that is one line too greedy silently deletes
# the evidence and no status assertion anywhere would notice. This file is the
# regression that notices: it pins BOTH directions — the contract line is gone,
# and everything around it is still there.
#
# The suite output is synthesised (45 PASS lines, a failing test's own stderr,
# Results:, RUN_CONTRACT:) and fed through the real dispatcher with a canned
# spawn, because a genuine ≥40-suite run with a chosen failure cannot be
# produced on demand and the parser, not bash, is what is under test.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - The real tests/run-all.sh output format drifting away from
#     `Results: ...` / `RUN_CONTRACT: ...`. Only a real suite run shows that;
#     tests/TL3-worker-dispatch-run-tests.sh is the gated tier for it.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
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

# ===========================================================================
# (a)+(b)+(c)+(d) — one well-formed contract line in the suite output.
# ===========================================================================
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

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
