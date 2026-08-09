#!/usr/bin/env bash
# tests/fix-1273-round3-contract-scoping.sh
# Tests: hooks/workflow-run-tests.js, bin/worker-dispatch/emit.js
# Tags: workflow, tests, runner, hook, contract, worker-dispatch, security, TL1, TL2, scope:common
#
# WHY (CPR-WPH): round 2 of the #1273 hardening bought two properties by adding a
# rule that only ONE of the two execution routes actually justifies. The post-fix
# security review found the resulting mismatches. Three boundaries, separated
# (CPR-SC):
#
#   NEW-M2  payloadHeader() truncates stdout at the first `log_tail: |` marker
#           before any contract or status parsing. That truncation is sound ONLY
#           on the worker-dispatch route, where bin/worker-dispatch/emit.js
#           renderTestRunnerYaml() structurally guarantees the marker's meaning.
#           It is applied UNCONDITIONALLY, including to the plain run-all route,
#           where stdout is raw suite output with no structural guarantee at all.
#           A suite that prints a `log_tail: |`-shaped line therefore has its own
#           trailing contract cut away — and a line printed BEFORE that marker is
#           promoted to sole authority.
#
#   NEW-L1  emit.js promoteContractFromTail() launders arbitrary log-tail text
#           into the authoritative top-level contract slot, with no identity
#           check on where that text came from. It is unreachable in practice
#           (workers/test-runner.js always supplies `runContract` and strips
#           contract lines out of `logTail` itself), which makes it a loaded
#           mechanism kept alive by nothing. Locked here as a static property.
#
#   NEW-L2  WORKER_FAIL_STATUSES is a DENYLIST. It vetoes completion for five
#           known-bad spellings and waves through everything else — a typo, a
#           newly introduced status word, or a value clipped by emit.js's 64-char
#           `plainValue` cap. The sanctioned green status is the single literal
#           `pass`; anything the hook does not recognise is by definition a status
#           it cannot vouch for, so allowlist is the only sound shape.
#
# Layering: NEW-M2 / NEW-L2 are TL2 (real hook process, hand-built PostToolUse
# stdin, assertions on the real workflow-state file). NEW-L1 is a TL1 static
# source-scan property.
#
# RED-FIRST: rows named `*-must-*` assert the SAFE / fixed outcome and report
# FAIL against today's code. `control-*` rows assert behaviour that must survive
# the fix unchanged.
#
# TL3 gap (what this test does NOT catch):
#   - Whether a real worker-dispatch run can be driven to produce these payload
#     shapes; here the YAML is synthesised, because the hook's parser and trust
#     decision — not the worker — are under test.
#     tests/TL3-worker-dispatch-run-tests.sh is the gated tier for that.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
AGENTS_WIN="$(nodepath "$AGENTS_DIR")"
RUN_TESTS_HOOK="$AGENTS_DIR/hooks/workflow-run-tests.js"
EMIT_JS="$AGENTS_DIR/bin/worker-dispatch/emit.js"

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

if [ ! -f "$RUN_TESTS_HOOK" ] || [ ! -f "$EMIT_JS" ]; then
    fail "0/prerequisites" "hook=$RUN_TESTS_HOOK emit=$EMIT_JS"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/rt-scope3-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): dual-pin the workflow dir
# and the plans dir, and clear the inherited live session ids so the hook can
# never resolve — and mutate — the session running this suite.
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# --- hook drivers ----------------------------------------------------------

# seed_step <sid> <step> <status>
seed_step() {
    run_with_timeout 30 node -e "
      require('$AGENTS_WIN/hooks/workflow-state').markStep(process.argv[1], process.argv[2], process.argv[3]);
    " "$1" "$2" "$3" >/dev/null 2>&1 || true
}

# drive_hook <command> <exit_code> <sid> <stdout_content> <cwd>
drive_hook() {
    local json
    json=$(run_with_timeout 30 node -e "
const payload = {
  tool_name: 'Bash',
  tool_input: { command: process.argv[1], cwd: process.argv[5] },
  tool_response: { exit_code: parseInt(process.argv[2], 10), stdout: process.argv[3] },
  session_id: process.argv[4]
};
process.stdout.write(JSON.stringify(payload));
" "$1" "$2" "$4" "$3" "$5" 2>/dev/null)
    printf '%s' "$json" | run_with_timeout 30 node "$RUN_TESTS_HOOK" >/dev/null 2>&1 || true
}

# run_tests_status <sid> → complete | pending | absent
run_tests_status() {
    run_with_timeout 30 node -e "
try {
  const s = require('$AGENTS_WIN/hooks/workflow-state').readState(process.argv[1]);
  console.log(s && s.steps && s.steps.run_tests ? s.steps.run_tests.status : 'absent');
} catch (e) { console.log('absent'); }
" "$1" 2>/dev/null || echo "absent"
}

# The two routes, each spelled the way its own provenance branch resolves.
# Both must pass the round-2 filesystem identity check, so both point at the
# REAL files in this repo — the routes, not the emitter identity, are under test.
RUNALL_CMD="bash $AGENTS_WIN/tests/run-all.sh"
DISPATCH_CMD="node $AGENTS_WIN/bin/worker-dispatch.js test-runner $AGENTS_WIN $TMPD/s-worker-test-runner.json"

# ===========================================================================
# NEW-M2 — header scoping applied to a route that has no header
#
# On the run-all route stdout is whatever the suite printed. `log_tail: |` is
# then just eleven characters a suite may legitimately print — a test of the
# worker payload renderer prints it, a YAML fixture echoes it, a diff of
# emit.js contains it. Truncating there deletes the suite's own contract.
#
# Two failure modes on the same boundary, kept apart because a fix could address
# one without the other:
#   M2a  the REAL trailing contract is lost           → false demotion
#   M2b  an EARLIER line is promoted to sole verdict  → false completion
# ===========================================================================

# M2a-0 — CONTROL / boundary probe: an INDENTED marker-shaped line. Green today
# because LOG_TAIL_MARKER_RE anchors at column 0. Pinned so the fix's blast
# radius is visible: this is the shape that is already safe, and it must stay
# safe whichever way the route scoping is resolved.
SID="m2lost-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
drive_hook "$RUNALL_CMD" 0 "$SID" "Running tests/fix-1378-worker-log-tail-integrity.sh
  case: renderer emits log_tail: |
PASS: renderer-block-scalar
RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5" "$AGENTS_WIN"
assert_eq "M2/control-indented-marker-shaped-line-is-already-harmless" "complete" \
    "$(run_tests_status "$SID")"

# M2a-2 — the same shape, unindented and at column 0, i.e. the exact spelling
# LOG_TAIL_MARKER_RE matches. Kept separate so a fix that only tightens the
# regex's indentation tolerance is still measured against the real question
# (WHICH ROUTE may be scoped), not the marker's cosmetics.
SID="m2lost2-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
drive_hook "$RUNALL_CMD" 0 "$SID" "Running tests/emit-render.sh
log_tail: |
expected renderer output above
RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5" "$AGENTS_WIN"
assert_eq "M2a/run-all-route-must-see-contract-after-column0-marker" "complete" \
    "$(run_tests_status "$SID")"

# M2b — the offensive direction of the same bug. Raw suite output is not a
# payload, so nothing makes the FIRST contract authoritative; scoping invents
# that authority and discards the suite's real, failing verdict. Parsed
# unscoped, this stdout holds two contract lines → ambiguous → pending, which is
# the exactly-one rule the hook already owns.
SID="m2win-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
seed_step "$SID" "run_tests" "complete"
drive_hook "$RUNALL_CMD" 0 "$SID" "RUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9
log_tail: |
(the real run continues below)
RUN_CONTRACT: PASS=0 FAIL=3 SKIP=0 EXECUTED=3" "$AGENTS_WIN"
assert_eq "M2b/run-all-route-must-not-let-pre-marker-contract-win" "pending" \
    "$(run_tests_status "$SID")"

# CONTROL — plain run-all output with no marker at all still completes.
SID="m2ctl-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
drive_hook "$RUNALL_CMD" 0 "$SID" "Running tests/foo.sh
PASS: everything
RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5" "$AGENTS_WIN"
assert_eq "M2/control-run-all-plain-output-completes" "complete" "$(run_tests_status "$SID")"

# CONTROL, opposite route (CPR-ORTH): the worker-dispatch route MUST keep the
# scoping. Its `log_tail: |` really is a renderer-owned boundary, so an indented
# contract inside the block is log text and may not complete. A fix that removes
# payloadHeader() outright would pass every M2 row above and reopen #1273 H1.
SID="m2wd-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
seed_step "$SID" "run_tests" "complete"
drive_hook "$DISPATCH_CMD" 0 "$SID" "status: fail
exit_code: 1
duration_seconds: 4
summary: 'suite failed'
failing_tests:
  - 'tests/broken.sh'
log_tail: |
  RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1" "$AGENTS_WIN"
assert_eq "M2/control-worker-dispatch-route-keeps-log-tail-scoping" "pending" \
    "$(run_tests_status "$SID")"

# ===========================================================================
# NEW-L1 — promoteContractFromTail() is a live mechanism with no live purpose
#
# workers/test-runner.js parses the suite's contract into `runContract` AND
# strips contract lines out of `logTail` before handing the result over
# (see tests/fix-1378-worker-log-tail-integrity.sh). So by the time
# renderTestRunnerYaml() reaches the promotion fallback, `tailSource` can no
# longer contain a contract line: the fallback is unreachable for every worker
# in the dispatcher.
#
# What it still is, is a function that copies untrusted log text into the ONE
# position the hook treats as authoritative, with no check on that text's
# origin. The property locked here is "no unguarded promotion path exists":
# the fix may keep it true by deleting the function, or break it deliberately by
# introducing a caller that authenticates the source first.
# ===========================================================================
occurrences() {
    # count identifier occurrences in one file (0 when the file is absent)
    [ -f "$1" ] || { echo 0; return; }
    grep -c 'promoteContractFromTail' "$1" 2>/dev/null || echo 0
}

EXTERNAL_HITS="$(grep -rl 'promoteContractFromTail' "$AGENTS_DIR/bin" "$AGENTS_DIR/hooks" 2>/dev/null \
    | grep -v 'bin/worker-dispatch/emit.js' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "L1/no-caller-outside-emit-js" "" "$EXTERNAL_HITS"

# Exactly one occurrence = the definition alone, i.e. no call site. Today there
# are two (definition + the unguarded fallback call in renderTestRunnerYaml).
assert_eq "L1/emit-js-holds-definition-only-no-call-site" "1" "$(occurrences "$EMIT_JS")"

# ===========================================================================
# NEW-L2 — WORKER_FAIL_STATUSES is a denylist
#
# The set is {fail, failed, runner-error, timeout, error}. Everything outside it
# is silently treated as "not a failure", which is not the same claim as "the
# worker said it passed". Three ways that gap is reached without any attacker at
# all: a new status word added to the renderer's vocabulary, a typo, and
# emit.js's `plainValue(result.status, 64, …)` clipping a long value to 64 chars.
#
# The renderer's own vocabulary is pass | fail | timeout | runner-error, so the
# allowlist is a one-element set: `pass`.
# ===========================================================================
CONTRACT_HEADER="RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3"

# l2_case <label> <status_value> <want_status>
l2_case() {
    local label="$1" status_value="$2" want="$3"
    local sid="l2-$$-$RANDOM"
    seed_step "$sid" "write_tests" "complete"
    drive_hook "$DISPATCH_CMD" 0 "$sid" "$CONTRACT_HEADER
status: $status_value
exit_code: 0
duration_seconds: 2
summary: 'reported'
failing_tests: []
log_tail: |
  ok" "$AGENTS_WIN"
    assert_eq "L2/$label" "$want" "$(run_tests_status "$sid")"
}

# Unenumerated garbage: not in the denylist, and not the sanctioned green word.
l2_case "unknown-status-must-veto" "totally-bogus-value" "pending"
# A near-miss spelling of the green word — the class of typo a denylist can
# never enumerate.
l2_case "passed-is-not-pass-must-veto" "passed" "pending"
# A future/renamed vocabulary word nobody remembered to add to the denylist.
l2_case "unenumerated-vocabulary-word-must-veto" "degraded" "pending"
# emit.js caps `status:` at 64 chars via plainValue; a clipped value is
# unrecognisable by construction and must not read as success.
l2_case "truncated-64-char-status-must-veto" \
    "runner-errorrunner-errorrunner-errorrunner-errorrunner-errorrunn" "pending"

# CONTROL — the one sanctioned green spelling still completes.
l2_case "control-status-pass-completes" "pass" "complete"
# CONTROL — a denylisted failure keeps vetoing (no regression of round 2's H1b).
l2_case "control-status-fail-still-vetoes" "fail" "pending"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
