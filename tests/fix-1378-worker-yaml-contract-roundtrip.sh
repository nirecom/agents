#!/usr/bin/env bash
# tests/fix-1378-worker-yaml-contract-roundtrip.sh
# Tests: bin/worker-dispatch/emit.js, bin/worker-dispatch/workers/test-runner.js, hooks/workflow-run-tests.js
# Tags: worker-dispatch, test-runner, yaml, contract, hook, TL2, scope:common
#
# Issue #1378 — the generator and the detector were each self-consistent and
# still could not talk to each other. `renderTestRunnerYaml()` emits the worker's
# YAML; `hooks/workflow-run-tests.js` reads that same text back as
# `tool_response.stdout` and looks for a RUN_CONTRACT line. Every existing test
# covers exactly one side of that seam, so a contract the renderer never emits —
# or emits in a shape the parser's anchor rejects — passes both suites and fails
# in production. This file is the ROUND TRIP: the real renderer produces the
# string, and the real hook consumes it, in one process chain.
#
# The fix originally had two halves, exercised independently on purpose:
#   C3 = relax the parser's line anchor to accept an INDENTED contract line
#        (the shape a contract inside `log_tail: |` necessarily has).
#   C4 = have the renderer emit the contract as its own TOP-LEVEL first line.
# Case (1) pins C4; case (3) pins that C4 does not produce TWO contract lines —
# which the parser's exactly-one rule turns into `ambiguous` → demotion, i.e.
# #1378 wearing a different face (detail plan Risk 5).
#
# C3 was subsequently RETIRED by #1273 round 3 (NEW-L1 + NEW-M2): trusting a
# contract that appears only inside `log_tail` means treating untrusted log text
# as a verdict, so neither the renderer (promotion helper unwired) nor the hook
# (contract read scoped away from the block scalar) will honour it. Case (2) is
# re-authored as the negative that now holds; see its own header.
#
# TL3/TL4 gap (what this TL2 round trip does NOT catch):
#   - What real Claude Code actually puts in `tool_response.stdout`: newline
#     normalisation, truncation, or stderr merged into stdout. This file obtains
#     the YAML by calling the renderer directly, so the delivered payload is
#     assumed, not observed. tests/TL3-worker-dispatch-run-tests.sh narrows that
#     by one step (real dispatcher, real suite output).
#   - Real PostToolUse delivery and whether `systemMessage` reaches the model's
#     context (detail plan W-3) — TL4, out of scope, tracked as #1543.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
AGENTS_WIN="$(nodepath "$AGENTS_DIR")"
EMIT_JS="$AGENTS_WIN/bin/worker-dispatch/emit.js"
RUN_TESTS_HOOK="$AGENTS_DIR/hooks/workflow-run-tests.js"

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

# Fixture isolation (rules/test/fixture-isolation.md): dual-pin, neutral temp
# state, and no inherited live session ID that a hook could resolve and mutate.
TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-rt-$$")"
mkdir -p "$TMPD/workflow-state" "$TMPD/workflow-plans"
trap 'rm -rf "$TMPD"' EXIT
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# The real WD-3 dispatch command string, exactly as /run-tests RNT-1 spells it.
# It contains no `tests/run-all.sh` literal — that absence is the whole of #1798
# and the reason this round trip needs its own provenance premise (case 6).
#
# The dispatcher path is THIS checkout's real one, not a synthetic
# `/srv/checkout/...` literal. Since #1273 round 3 / NEW-H2 an unresolvable path
# scores as UNVERIFIED and demotes on provenance alone, which would make every
# row below pend for a reason that has nothing to do with the generator/detector
# seam this file exists to test — case 6's falsifiability guard included. Only a
# resolvable, canonical emitter path lets the contract itself decide the verdict.
# (Rejection of unresolvable/impostor emitter paths is covered by
# tests/fix-1273-round3-provenance-identity.sh and
# tests/main-workflow-run-tests/quoted-arg-and-provenance.sh.)
DISPATCH_CMD="node \"$AGENTS_WIN/bin/worker-dispatch.js\" test-runner \"$AGENTS_WIN\" \"$TMPD/sid-worker-test-runner.json\""

# render_yaml <result-json> → the renderer's own output, verbatim.
render_yaml() {
    run_with_timeout 30 node -e '
try {
  const { renderTestRunnerYaml } = require(process.argv[1]);
  process.stdout.write(renderTestRunnerYaml(JSON.parse(process.argv[2])));
} catch (e) { process.stdout.write("RENDER_ERROR: " + e.message + "\n"); }
' "$EMIT_JS" "$1" 2>/dev/null
}

# fallback_yaml → the literal emitted when the rendered text is sentinel-tainted.
fallback_yaml() {
    run_with_timeout 30 node -e '
try {
  const emit = require(process.argv[1]);
  // The taint path is reached through the public write(). A sentinel confined to
  // ONE line is merely redacted in place, so it does not get here; the fallback
  // is reserved for what per-line sanitising cannot see — a sentinel SPLIT
  // across two log_tail lines, which only the whole-string rescan catches.
  emit.write({ renderer: "test-runner-yaml" }, {
    status: "pass", exitCode: 0, durationSeconds: 1,
    summary: "PASS=1 FAIL=0 SKIP=0", failingTests: [],
    logTail: ["run finished <<", "WORKFLOW_MARK_STEP_run_tests_complete>>"],
  });
} catch (e) { process.stdout.write("FALLBACK_ERROR: " + e.message + "\n"); }
' "$EMIT_JS" 2>/dev/null
}

# seed <sid> <step> <status>
seed() {
    run_with_timeout 30 node -e '
const m = require(process.argv[1] + "/hooks/workflow-state");
m.markStep(process.argv[2], process.argv[3], process.argv[4]);
' "$AGENTS_WIN" "$1" "$2" "$3" >/dev/null 2>&1 || true
}

# feed_hook <command> <exit_code> <sid> <stdout>
feed_hook() {
    local json
    json=$(run_with_timeout 30 node -e '
process.stdout.write(JSON.stringify({
  tool_name: "Bash",
  tool_input: { command: process.argv[1] },
  tool_response: { exit_code: parseInt(process.argv[2], 10), stdout: process.argv[3] },
  session_id: process.argv[4],
}));
' "$1" "$2" "$4" "$3" 2>/dev/null)
    printf '%s' "$json" | run_with_timeout 30 node "$RUN_TESTS_HOOK" >/dev/null 2>&1
}

# status_of <sid>
status_of() {
    run_with_timeout 30 node -e '
try {
  const s = require(process.argv[1] + "/hooks/workflow-state").readState(process.argv[2]);
  console.log(s && s.steps && s.steps.run_tests ? s.steps.run_tests.status : "absent");
} catch (e) { console.log("absent"); }
' "$AGENTS_WIN" "$1" 2>/dev/null || echo "absent"
}

# roundtrip <label> <result-json> <expected-status>
# Seeds write_tests=complete (the #1139 guard) and run_tests=complete, so the
# expected outcome distinguishes "left complete" from "actively demoted".
roundtrip() {
    local label="$1" result="$2" want="$3"
    local sid yaml
    sid="rt-$$-$RANDOM"
    seed "$sid" write_tests complete
    seed "$sid" run_tests complete
    yaml="$(render_yaml "$result")"
    feed_hook "$DISPATCH_CMD" 0 "$sid" "$yaml"
    assert_eq "$label" "$want" "$(status_of "$sid")"
    LAST_YAML="$yaml"
}
LAST_YAML=""

# contract_line_count <text> — counts contract lines under the RELAXED anchor,
# i.e. what the parser will see once C3 lands. Written independently of the
# implementation so it cannot inherit the implementation's own mistake.
contract_line_count() {
    printf '%s\n' "$1" | grep -c -E '^[[:space:]]*RUN_CONTRACT: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+ EXECUTED=[0-9]+' | tr -d ' '
}

if [ ! -f "$AGENTS_DIR/bin/worker-dispatch/emit.js" ] || [ ! -f "$RUN_TESTS_HOOK" ]; then
    fail "0/prerequisites" "emit.js or workflow-run-tests.js missing"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

# ===========================================================================
# (6) PREMISE — the dispatch command string must be classified as a test run.
#
# This case runs FIRST and is the non-discrimination guard for the whole file:
# if the hook early-returns on this command, cases (1)-(5) can only observe the
# seeded state, and a renderer that emits no contract at all would still show
# `complete` for (1)-(3). Without this row the suite is unfalsifiable.
# ===========================================================================
PREMISE_SID="rtpremise-$$-$RANDOM"
seed "$PREMISE_SID" write_tests complete
seed "$PREMISE_SID" run_tests complete
# Contract-free stdout: the ONLY way this demotes is if the command reached the
# detector, so the demotion itself proves detection.
feed_hook "$DISPATCH_CMD" 0 "$PREMISE_SID" "status: pass
exit_code: 0
log_tail: |
  no contract here"
assert_eq "6/premise-dispatch-command-is-detected-as-a-test-run" "pending" "$(status_of "$PREMISE_SID")"

# ===========================================================================
# (1) C4 alone — the renderer emits a top-level contract line; log_tail has none.
# ===========================================================================
roundtrip "1/top-level-contract-completes-the-step" '{
  "status": "pass", "exitCode": 0, "durationSeconds": 12,
  "summary": "PASS=5 FAIL=0 SKIP=1",
  "failingTests": [],
  "runContract": { "pass": 5, "fail": 0, "skip": 1, "executed": 6 },
  "logTail": ["PASS: tests/alpha.sh", "Results: PASS=5  FAIL=0  SKIP=1"]
}' "complete"
assert_eq "1/renderer-emits-exactly-one-contract-line" "1" "$(contract_line_count "$LAST_YAML")"
case "$(printf '%s\n' "$LAST_YAML" | head -1)" in
    "RUN_CONTRACT: PASS=5 FAIL=0 SKIP=1 EXECUTED=6")
        pass "1/contract-is-the-very-first-line" ;;
    *)
        fail "1/contract-is-the-very-first-line" "got=$(printf '%s\n' "$LAST_YAML" | head -1)" ;;
esac

# ===========================================================================
# (2) PREMISE CHANGED (#1273 round 3 / NEW-L1 + NEW-M2) — a contract that exists
#     ONLY inside log_tail must NOT complete the step.
#
# This row used to assert the opposite ("C3 alone rescues the indented shape").
# Two fixes retired that premise together: NEW-L1 unwired
# `promoteContractFromTail()` from `renderTestRunnerYaml()` (lifting log text
# into the authoritative top-level slot was laundering untrusted bytes into a
# verdict), and NEW-M2 scoped the hook's contract read away from the log_tail
# block so a line that only appears inside it carries no authority either.
#
# So the row is re-authored as the NEGATIVE it now is. The assertions are
# deliberately three, because the status alone cannot distinguish "not promoted"
# from "the renderer dropped the line": the contract text must still be PRESENT
# in the rendered YAML (indented, inside log_tail — nothing is being hidden), it
# must NOT have been promoted to the top-level slot, and the step must pend with
# contract-absent rather than complete.
# ===========================================================================
roundtrip "2/log_tail-only-contract-does-not-complete-the-step" '{
  "status": "pass", "exitCode": 0, "durationSeconds": 9,
  "summary": "PASS=4 FAIL=0 SKIP=0",
  "failingTests": [],
  "logTail": ["Results: PASS=4  FAIL=0  SKIP=0", "RUN_CONTRACT: PASS=4 FAIL=0 SKIP=0 EXECUTED=4"]
}' "pending"
# Present, but only where the suite itself put it: still inside the block scalar.
case "$(printf '%s\n' "$LAST_YAML" | grep -E '^[ \t]+RUN_CONTRACT: PASS=4 FAIL=0 SKIP=0 EXECUTED=4')" in
    "") fail "2/log_tail-keeps-the-suite-contract-line-verbatim" "$LAST_YAML" ;;
    *)  pass "2/log_tail-keeps-the-suite-contract-line-verbatim" ;;
esac
# Not promoted: the top-level slot is written from structured worker data alone,
# and this result carries no `runContract`, so line 1 must still be `status:`.
assert_eq "2/contract-not-promoted-to-the-top-level-slot" "status: pass" \
    "$(printf '%s\n' "$LAST_YAML" | head -1)"

# ===========================================================================
# (3) C3 AND C4 — both halves landed and the suite output also carried its own
#     contract line. Two visible contract lines would trip the exactly-one rule
#     (ambiguous → null → demotion), so the renderer must suppress the log_tail
#     copy when it emits the top-level one. The status assertion alone cannot
#     tell "one line" from "zero lines" here, so the count is asserted too.
# ===========================================================================
roundtrip "3/double-source-does-not-break-exactly-one" '{
  "status": "pass", "exitCode": 0, "durationSeconds": 11,
  "summary": "PASS=7 FAIL=0 SKIP=2",
  "failingTests": [],
  "runContract": { "pass": 7, "fail": 0, "skip": 2, "executed": 9 },
  "logTail": ["Results: PASS=7  FAIL=0  SKIP=2", "RUN_CONTRACT: PASS=7 FAIL=0 SKIP=2 EXECUTED=9"]
}' "complete"
assert_eq "3/still-exactly-one-contract-line" "1" "$(contract_line_count "$LAST_YAML")"
# Suppression must be surgical: the diagnostic lines around the contract stay.
case "$LAST_YAML" in
    *"Results: PASS=7  FAIL=0  SKIP=2"*) pass "3/log_tail-keeps-the-Results-line" ;;
    *) fail "3/log_tail-keeps-the-Results-line" "$LAST_YAML" ;;
esac

# ===========================================================================
# (4) A failing suite must demote even though the contract is well-formed.
#     Validity is fail===0, not merely "parseable" — the contract is a report,
#     not a permission slip.
# ===========================================================================
roundtrip "4/failing-suite-demotes" '{
  "status": "fail", "exitCode": 1, "durationSeconds": 14,
  "summary": "PASS=3 FAIL=2 SKIP=0",
  "failingTests": ["tests/alpha.sh", "tests/beta.sh"],
  "runContract": { "pass": 3, "fail": 2, "skip": 0, "executed": 5 },
  "logTail": ["FAIL: tests/alpha.sh (exit 1)", "Results: PASS=3  FAIL=2  SKIP=0"]
}' "pending"

# ===========================================================================
# (5) FALLBACK_YAML — the renderer discarded its output because the worker's
#     text was sentinel-tainted. It carries no contract by construction, so the
#     hook must demote: an unreadable run is an unverified run (fail-safe).
# ===========================================================================
FB_SID="rtfb-$$-$RANDOM"
seed "$FB_SID" write_tests complete
seed "$FB_SID" run_tests complete
FB_YAML="$(fallback_yaml)"
feed_hook "$DISPATCH_CMD" 0 "$FB_SID" "$FB_YAML"
assert_eq "5/fallback-yaml-demotes" "pending" "$(status_of "$FB_SID")"
assert_eq "5/fallback-yaml-carries-no-contract" "0" "$(contract_line_count "$FB_YAML")"
# The fallback must also still be a fallback — if the taint scan stopped firing,
# case 5 would be asserting nothing about the fallback path at all.
case "$FB_YAML" in
    *"sentinel-like content detected"*) pass "5/taint-path-actually-taken" ;;
    *) fail "5/taint-path-actually-taken" "$FB_YAML" ;;
esac
# And it must not itself smuggle an unredacted sentinel back into the transcript.
case "$FB_YAML" in
    *"<<WORKFLOW"*) fail "5/fallback-leaks-an-unredacted-sentinel" "$FB_YAML" ;;
    *) pass "5/fallback-carries-no-unredacted-sentinel" ;;
esac

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
