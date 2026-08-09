#!/usr/bin/env bash
# tests/fix-1273-round4-emitter-ambiguity.sh
# Tests: hooks/workflow-run-tests/exec-model.js, hooks/workflow-run-tests.js
# Tags: workflow, tests, runner, hook, classifier, provenance, worker-dispatch, security, TL1, TL2, scope:common
#
# WHY (CPR-WPH): round 3 of the #1273 hardening added two worker-dispatch-only
# protections to hooks/workflow-run-tests.js — the worker-verdict veto (NEW-L2,
# `status:` must literally be `pass`) and the log_tail payload scoping (NEW-M2,
# only the renderer-owned header may be parsed for a contract). Both are gated on
# ONE scalar: `emitter === "worker-dispatch"` (workflow-run-tests.js ~L241-246).
#
# That scalar comes from resolveTestProvenance() (exec-model.js ~L335-356), which
# walks every execution position of the command in order and RETURNS AT THE FIRST
# position whose spelling + filesystem identity verify. A command has as many
# execution positions as it has segments, so "the first verifying position" and
# "the process that wrote this stdout" are different claims whenever a command
# has more than one segment.
#
#   NEW-N1  A compound command whose EARLY segment is a verifying run-all
#           position and whose LATE segment is the real worker-dispatch
#           invocation resolves to emitter="run-all". The stdout the hook then
#           reads is nonetheless the worker-dispatch YAML payload, because that
#           is the command that actually produced output worth parsing. Both
#           worker-dispatch protections are therefore switched off over a
#           worker-dispatch payload:
#             N1a  the veto never runs      → `status: fail` completes run_tests
#             N1d  the scoping never runs   → an indented contract inside the
#                                             untrusted `log_tail: |` block is
#                                             promoted to the authoritative
#                                             contract (NEW-M2 reopened through
#                                             the side door)
#           Building the command costs nothing: `bash tests/run-all.sh --help`
#           is a no-op prefix, and both paths are the repo's REAL files, so the
#           round-3 identity check (H2/M1) verifies both and blocks neither.
#
# THE INTENDED POST-FIX BEHAVIOUR (spec for write-code). The hook cannot
# attribute a byte of stdout to a segment: the shell concatenated them and the
# tool response carries one flat string. So when a command holds TWO DISTINCT
# verifying emitters, "which emitter produced this contract?" has no answer, and
# an unanswerable provenance question must resolve to NOT TRUSTED. Concretely:
#   - resolveTestProvenance() must stop returning the first match as if it were
#     the only one. It must see all verifying positions, and when they name more
#     than one DISTINCT emitter the run must be demoted to `pending`.
#   - An implementation that instead attributes the compound run to
#     `worker-dispatch` (last-position-wins, or dispatcher-precedence) and then
#     applies the veto + scoping is equally acceptable to this file: every
#     hook-level row below asserts the DEMOTION, which both shapes produce, and
#     the classifier-level rows assert only `emitter != run-all`, which both
#     shapes satisfy. The rows are deliberately not pinned to one fix shape.
#   - The ambiguity verdict must NOT depend on what the payload claims: N1d
#     carries `status: pass` and still must demote. A payload's self-report is
#     the very thing whose attribution is in doubt.
#
# Layering: N1a/N1d classifier rows are TL1 (exec-model.js required directly);
# every `*-must-not-complete-run-tests` row is TL2 (real hook process, real
# workflow-state file), mirroring the H2a/M1 TL2 pattern in
# tests/fix-1273-round3-provenance-identity.sh.
#
# RED-FIRST: rows named `*-must-*` assert the SAFE / post-fix outcome and report
# FAIL against pre-fix code. `control-*` rows were GREEN before the fix and pin
# behaviour that must survive it.
#
# TL3 gap (what this test does NOT catch):
#   - Whether a real Bash tool call actually delivers a compound command's two
#     stdouts concatenated in the order these fixtures assume; here the stdout is
#     synthesised, because the hook's provenance decision — not the shell — is
#     under test. tests/TL3-worker-dispatch-run-tests.sh is the gated tier for
#     the real-invocation shape.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
AGENTS_WIN="$(nodepath "$AGENTS_DIR")"
RUN_TESTS_HOOK="$AGENTS_DIR/hooks/workflow-run-tests.js"
EXEC_MODEL_JS="$AGENTS_WIN/hooks/workflow-run-tests/exec-model.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
# Used where the fix has two acceptable shapes: the row must not pin either one,
# only rule out today's wrong answer.
assert_ne() {
    local name="$1" unwanted="$2" got="$3"
    if [ "$unwanted" != "$got" ]; then pass "$name"
    else fail "$name" "must-not-be=$(printf '%q' "$unwanted") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$RUN_TESTS_HOOK" ] || [ ! -f "$AGENTS_DIR/hooks/workflow-run-tests/exec-model.js" ]; then
    fail "0/prerequisites" "hook=$RUN_TESTS_HOOK model=$EXEC_MODEL_JS"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/rt-amb4-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): dual-pin the workflow dir
# and the plans dir, and clear the inherited live session ids so the hook can
# never resolve — and mutate — the session running this suite.
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# --- drivers ---------------------------------------------------------------

# provenance <command> <cwd> → run-all | worker-dispatch | (none) | ERR
provenance() {
    run_with_timeout 30 node -e '
try {
  const m = require(process.argv[1]);
  if (typeof m.resolveTestProvenance !== "function") { process.stdout.write("ERR"); process.exit(0); }
  const r = m.resolveTestProvenance(process.argv[2], process.argv[3]);
  process.stdout.write(r === null ? "(none)" : String(r.emitter));
} catch (e) { process.stdout.write("ERR"); }
' "$EXEC_MODEL_JS" "$1" "$2" 2>/dev/null
}

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

# The two authorised emitters, each spelled at a REAL path in THIS repo so the
# round-2/round-3 filesystem identity check verifies both. Nothing here attacks
# identity — the ambiguity of the RESOLVED ROUTE is what is under test.
RUNALL_CMD="bash $AGENTS_WIN/tests/run-all.sh"
DISPATCH_CMD="node $AGENTS_WIN/bin/worker-dispatch.js test-runner $AGENTS_WIN $TMPD/s-worker-test-runner.json"
# The exploit shape: a no-op run-all position placed BEFORE the real dispatcher.
# `--help` makes the prefix genuinely harmless, which is the point — the attacker
# pays nothing for it and the stdout that follows is still the worker's payload.
EXPLOIT_CMD="bash $AGENTS_WIN/tests/run-all.sh --help; $DISPATCH_CMD"
# Same two positions, order swapped. Kept as evidence that first-match-wins is
# the mechanism, not a property of either emitter.
SWAPPED_CMD="$DISPATCH_CMD; bash $AGENTS_WIN/tests/run-all.sh --help"

# A worker payload in emit.js's real shape (contract first, then status /
# exit_code / duration / summary / failing_tests, then the indented log_tail
# block scalar that runs to end-of-output).
FAILING_PAYLOAD="RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3
status: fail
exit_code: 1
duration_seconds: 4
summary: 'suite failed after the contract line was printed'
failing_tests:
  - 'tests/broken.sh'
log_tail: |
  FAIL: broken
  worker: harness died after summary"

# Header claims nothing; the ONLY contract line sits inside the untrusted
# log_tail block, indented exactly the way emit.js indents suite output.
TAIL_ONLY_PAYLOAD="status: pass
exit_code: 0
duration_seconds: 2
summary: 'ok'
failing_tests: []
log_tail: |
  RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"

# ===========================================================================
# N1a — the veto is gated off by an earlier, unrelated verifying position
#
# The worker said `status: fail` / `exit_code: 1`. That verdict is the ONLY place
# the worker-dispatch route can report failure (the OS exit code is 0 by
# construction there — "I produced a result"), which is exactly why round 3 made
# it a veto. Prefixing the command with a no-op run-all position moves `emitter`
# to "run-all", and `vetoed = emitter === "worker-dispatch" && …` is then false
# without the veto predicate ever being evaluated.
# ===========================================================================

# Pre-fix this command resolved to `run-all` (first-match-wins), which is what
# made the exploit work. The evidence row that pinned that answer was removed
# once the fix landed and flipped it — the `must-not-resolve` row below is its
# post-fix counterpart and the standing regression guard.
#
# Post-fix the resolved route must not be plain `run-all`. Two fix shapes
# are acceptable (ambiguous → `(none)`, or correctly attributed →
# `worker-dispatch`), so the row rules out only today's wrong answer.
assert_ne "N1a/compound-run-all-then-dispatch-must-not-resolve-run-all" "run-all" \
    "$(provenance "$EXPLOIT_CMD" "$AGENTS_WIN")"

# RED / TL2 — the complete exploit through the real hook: a worker payload that
# says it FAILED marks run_tests complete.
SID="n1a-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
drive_hook "$EXPLOIT_CMD" 0 "$SID" "$FAILING_PAYLOAD" "$AGENTS_WIN"
assert_eq "N1a/failing-worker-payload-behind-run-all-prefix-must-not-complete-run-tests" \
    "pending" "$(run_tests_status "$SID")"

# RED / TL2 — same exploit, but run_tests was ALREADY complete. Round 3's demotion
# is an ACTIVE one (it must clear a stale complete), so the passing-looking
# variant of this row would be indistinguishable from "the hook did nothing".
SID="n1a2-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
seed_step "$SID" "run_tests" "complete"
drive_hook "$EXPLOIT_CMD" 0 "$SID" "$FAILING_PAYLOAD" "$AGENTS_WIN"
assert_eq "N1a/failing-worker-payload-behind-run-all-prefix-must-actively-demote" \
    "pending" "$(run_tests_status "$SID")"

# ===========================================================================
# N1b — CONTROL: the veto itself is intact (round 3 NEW-L2 regression guard)
#
# The identical payload, delivered by the dispatcher ALONE, must still veto. This
# row separates "the veto is broken" from "the veto is bypassed" (CPR-SC): it is
# GREEN today, so N1a is a routing failure, not a veto failure.
# ===========================================================================
assert_eq "N1b/control-dispatch-alone-resolves-worker-dispatch" "worker-dispatch" \
    "$(provenance "$DISPATCH_CMD" "$AGENTS_WIN")"

SID="n1b-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
seed_step "$SID" "run_tests" "complete"
drive_hook "$DISPATCH_CMD" 0 "$SID" "$FAILING_PAYLOAD" "$AGENTS_WIN"
assert_eq "N1b/control-dispatch-alone-failing-payload-still-vetoes" "pending" \
    "$(run_tests_status "$SID")"

# CONTROL, order swapped (CPR-ORTH): dispatcher FIRST, run-all second. The veto
# survives purely because the dispatcher happens to be reached first — the
# asymmetry between this row and N1a is the bug's signature, and this side of it
# must stay green through the fix.
assert_eq "N1b/control-dispatch-first-order-still-vetoes-provenance" "worker-dispatch" \
    "$(provenance "$SWAPPED_CMD" "$AGENTS_WIN")"

SID="n1b2-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
drive_hook "$SWAPPED_CMD" 0 "$SID" "$FAILING_PAYLOAD" "$AGENTS_WIN"
assert_eq "N1b/control-dispatch-first-order-failing-payload-must-not-complete" "pending" \
    "$(run_tests_status "$SID")"

# ===========================================================================
# N1c — CONTROL: legitimate plain run-all is untouched
#
# The fix must key on the presence of a SECOND, DIFFERENT verifying emitter —
# never on "the command has more than one segment" and never on "a
# worker-dispatch-shaped string appears somewhere". A run-all run that has
# nothing to do with worker-dispatch keeps completing.
# ===========================================================================
SID="n1c-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
drive_hook "$RUNALL_CMD" 0 "$SID" "Running tests/foo.sh
PASS: everything
RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5" "$AGENTS_WIN"
assert_eq "N1c/control-plain-run-all-with-valid-contract-completes" "complete" \
    "$(run_tests_status "$SID")"

assert_eq "N1c/control-plain-run-all-resolves-run-all" "run-all" \
    "$(provenance "$RUNALL_CMD" "$AGENTS_WIN")"

# CONTROL — the SAME emitter twice is not ambiguity. Both positions name run-all,
# so attribution is unaffected and the existing exactly-one-contract rule still
# decides. This is the cost side of the recommended narrow rule: a fix that
# instead demotes on "more than one verifying POSITION" breaks this row, and that
# trade must then be made deliberately rather than by accident.
SID="n1c2-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
drive_hook "$RUNALL_CMD; bash $AGENTS_WIN/tests/run-all.sh --help" 0 "$SID" \
    "RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5" "$AGENTS_WIN"
assert_eq "N1c/control-same-emitter-twice-is-not-ambiguous" "complete" \
    "$(run_tests_status "$SID")"

# CONTROL — a worker-dispatch-shaped token that is NOT in an execution position
# (an argument VALUE) must not turn a plain run-all run into an ambiguous one.
# Without this row, a fix written as a substring probe over the command text
# would pass every N1a row and reintroduce #1273's original defect.
SID="n1c3-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
drive_hook "$RUNALL_CMD --note bin/worker-dispatch.js" 0 "$SID" \
    "RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5" "$AGENTS_WIN"
assert_eq "N1c/control-dispatcher-name-as-argument-value-is-not-a-position" "complete" \
    "$(run_tests_status "$SID")"

# ===========================================================================
# N1d — the log_tail scoping is gated off by the same scalar (NEW-M2 side door)
#
# Independent of the veto (CPR-SC): here the payload claims `status: pass` and
# `exit_code: 0`, so the veto would not have fired even if it had run. What the
# misrouting costs is the SCOPING — `responseHeader()` returns the whole stdout
# on any non-worker-dispatch route, so the indented `RUN_CONTRACT` line inside
# the untrusted `log_tail: |` block becomes the run's authoritative contract.
# That is exactly the property round 3 (NEW-M2) established for this route.
#
# Post-fix expectation: pending — and specifically NOT because of the payload's
# claimed status, which is green here. Ambiguous execution shape is itself the
# reason: the hook cannot know which segment wrote which bytes, so a payload's
# self-report has no attributable author.
# ===========================================================================
SID="n1d-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
drive_hook "$EXPLOIT_CMD" 0 "$SID" "$TAIL_ONLY_PAYLOAD" "$AGENTS_WIN"
assert_eq "N1d/log-tail-contract-behind-run-all-prefix-must-not-complete-run-tests" \
    "pending" "$(run_tests_status "$SID")"

# CONTROL (GREEN today) — the same payload on the dispatcher-alone route is
# correctly scoped away and demotes. The differential against the row above is
# the whole finding.
SID="n1d2-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
seed_step "$SID" "run_tests" "complete"
drive_hook "$DISPATCH_CMD" 0 "$SID" "$TAIL_ONLY_PAYLOAD" "$AGENTS_WIN"
assert_eq "N1d/control-dispatch-alone-scopes-log-tail-contract-away" "pending" \
    "$(run_tests_status "$SID")"

# ===========================================================================
# N1e — end-to-end through the REAL hook process, with a payload that is green in
# every field the hook inspects EXCEPT the worker's own verdict.
#
# The row a reviewer should read first: no forged path, no forged repo, no forged
# contract arithmetic. Every ingredient is authentic — the real run-all.sh, the
# real worker-dispatch.js, a payload in emit.js's real shape — and the only thing
# the caller supplies is the ORDER of two segments.
# ===========================================================================
E2E_PAYLOAD="usage: run-all.sh [--list] [--filter <pat>]
RUN_CONTRACT: PASS=42 FAIL=0 SKIP=0 EXECUTED=42
status: fail
exit_code: 2
duration_seconds: 61
summary: 'runner aborted; results below are partial'
failing_tests:
  - 'tests/main-workflow-run-tests.sh'
log_tail: |
  FAIL: main-workflow-run-tests
  worker: aborted"

SID="n1e-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
seed_step "$SID" "run_tests" "complete"
drive_hook "$EXPLOIT_CMD" 0 "$SID" "$E2E_PAYLOAD" "$AGENTS_WIN"
assert_eq "N1e/e2e-ordered-segments-must-not-complete-run-tests" "pending" \
    "$(run_tests_status "$SID")"

# The same end-to-end payload with the segments swapped is already safe. Pinned
# so the fix is measured as "both orders now agree", not "one order changed".
SID="n1e2-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
seed_step "$SID" "run_tests" "complete"
drive_hook "$SWAPPED_CMD" 0 "$SID" "$E2E_PAYLOAD" "$AGENTS_WIN"
assert_eq "N1e/control-e2e-swapped-order-already-safe" "pending" \
    "$(run_tests_status "$SID")"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
