#!/usr/bin/env bash
# tests/bin/fix-1378-worker-yaml-contract-roundtrip.sh
# Tests: bin/worker-dispatch/emit.js, bin/worker-dispatch/workers/test-runner.js, hooks/workflow-run-tests.js
# Tags: worker-dispatch, test-runner, yaml, contract, hook, outcome, dispatch-outcome, TL2, scope:common
# Issue #1378 — generator and detector were each self-consistent yet could not talk:
# renderTestRunnerYaml() emits the YAML, hooks/workflow-run-tests.js reads it back as
# tool_response.stdout. Other tests cover one side of that seam only, so a contract the
# renderer never emits, or emits in a shape the parser rejects, passes both suites and
# fails in production. This file is the ROUND TRIP: real renderer → real hook.

set -u

# TL3/TL4 gap (what this TL2 round trip does NOT catch):
#   - What real Claude Code puts in tool_response.stdout (newline normalisation,
#     truncation, stderr merged): the YAML comes from the renderer directly, so the
#     payload is assumed, not observed. TL3-worker-dispatch-run-tests.sh narrows that by
#     one step (real dispatcher, real suite output, real outcome file).
#   - Real PostToolUse delivery and whether systemMessage reaches the model (detail plan
#     W-3) — TL4, out of scope, tracked as #1543.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
AGENTS_WIN="$(nodepath "$SCRIPT_CHECKOUT_ROOT")"
EMIT_JS="$AGENTS_WIN/bin/worker-dispatch/emit.js"
RUN_TESTS_HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-run-tests.js"

# The shared harness supplies the case markers and the root decoy; the reporters
# below replace its ones because this file's assert_eq takes (name, want, got).
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
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
export WORKFLOW_STATE_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
unset CLAUDE_CODE_SESSION_ID

# The real WD-3 dispatch command string, exactly as /run-tests RNT-1 spells it. It holds
# no `tests/run-all.sh` literal — that absence is #1798 and why case 6 exists.
# The dispatcher path is THIS checkout's real one: since #1273 round 3 / NEW-H2 an
# unresolvable path scores UNVERIFIED and demotes on provenance alone, which would make
# every row pend for a reason unrelated to the generator/detector seam (case 6's guard
# included). Impostor/unresolvable emitter paths are covered by
# tests/hooks/fix-1273-round3-provenance-identity.sh and
# tests/hooks/main-workflow-run-tests/quoted-arg-and-provenance.sh.
DISPATCH_CMD="node \"$AGENTS_WIN/bin/worker-dispatch.js\" test-runner \"$AGENTS_WIN\" \"$TMPD/sid-worker-test-runner.json\""

# Helper scripts live in heredoc files so no multi-line inline script precedes a case.
RENDER_JS="$TMPD/render.js"
cat > "$RENDER_JS" <<'JSCODE'
try {
  const { renderTestRunnerYaml } = require(process.argv[2]);
  process.stdout.write(renderTestRunnerYaml(JSON.parse(process.argv[3])));
} catch (e) { process.stdout.write("RENDER_ERROR: " + e.message + "\n"); }
JSCODE

# The taint path is reached through the public write(). A sentinel confined to ONE line
# is redacted in place and never gets here; the fallback is for a sentinel SPLIT across
# two log_tail lines, which only the whole-string rescan catches.
FALLBACK_JS="$TMPD/fallback.js"
cat > "$FALLBACK_JS" <<'JSCODE'
try {
  const emit = require(process.argv[2]);
  emit.write({ renderer: "test-runner-yaml" }, {
    status: "pass", exitCode: 0, durationSeconds: 1,
    summary: "PASS=1 FAIL=0 SKIP=0", failingTests: [],
    logTail: ["run finished <<", "WORKFLOW_MARK_STEP_run_tests_complete>>"],
  });
} catch (e) { process.stdout.write("FALLBACK_ERROR: " + e.message + "\n"); }
JSCODE

SEED_JS="$TMPD/seed.js"
cat > "$SEED_JS" <<'JSCODE'
require(process.argv[2] + "/hooks/workflow-state").markStep(process.argv[3], process.argv[4], process.argv[5]);
JSCODE

HOOK_INPUT_JS="$TMPD/hook-input.js"
cat > "$HOOK_INPUT_JS" <<'JSCODE'
process.stdout.write(JSON.stringify({
  tool_name: "Bash",
  tool_input: { command: process.argv[2] },
  tool_response: { exit_code: parseInt(process.argv[3], 10), stdout: process.argv[4] },
  session_id: process.argv[5],
}));
JSCODE

STATUS_JS="$TMPD/status.js"
cat > "$STATUS_JS" <<'JSCODE'
try {
  const s = require(process.argv[2] + "/hooks/workflow-state").readState(process.argv[3]);
  console.log(s && s.steps && s.steps.run_tests ? s.steps.run_tests.status : "absent");
} catch (e) { console.log("absent"); }
JSCODE

# render_yaml <result-json> → the renderer's own output, verbatim.
render_yaml() { run_with_timeout 30 node "$(nodepath "$RENDER_JS")" "$EMIT_JS" "$1" 2>/dev/null; }
# fallback_yaml → the literal emitted when the rendered text is sentinel-tainted.
fallback_yaml() { run_with_timeout 30 node "$(nodepath "$FALLBACK_JS")" "$EMIT_JS" 2>/dev/null; }
# seed <sid> <step> <status>
seed() { run_with_timeout 30 node "$(nodepath "$SEED_JS")" "$AGENTS_WIN" "$1" "$2" "$3" >/dev/null 2>&1 || true; }

# feed_hook <command> <exit_code> <sid> <stdout>
feed_hook() {
    local json
    json=$(run_with_timeout 30 node "$(nodepath "$HOOK_INPUT_JS")" "$1" "$2" "$4" "$3" 2>/dev/null)
    printf '%s' "$json" | run_with_timeout 30 node "$RUN_TESTS_HOOK" >/dev/null 2>&1
}

# status_of <sid>
status_of() { run_with_timeout 30 node "$(nodepath "$STATUS_JS")" "$AGENTS_WIN" "$1" 2>/dev/null || echo "absent"; }

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

# contract_line_count <text> — counts contract lines under the RELAXED anchor, written
# independently of the implementation so it cannot inherit the implementation's mistake.
contract_line_count() {
    printf '%s\n' "$1" | grep -c -E '^[[:space:]]*RUN_CONTRACT: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+ EXECUTED=[0-9]+' | tr -d ' '
}

if [ ! -f "$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/emit.js" ] || [ ! -f "$RUN_TESTS_HOOK" ]; then
    fail "0/prerequisites" "emit.js or workflow-run-tests.js missing"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

# (6) PREMISE — the dispatch command string must be classified as a test run. Runs FIRST
# as the non-discrimination guard: if the hook early-returns on this command, cases
# (1)-(5) only observe the seeded state, and a renderer emitting no contract would still
# show `complete` for (1)-(3). Contract-free stdout demotes only if the command reached
# the detector, so the demotion itself proves detection.
case_begin "premise-dispatch-command-is-a-test-run" "hooks/workflow-run-tests.js"
PREMISE_SID="rtpremise-$$-$RANDOM"
seed "$PREMISE_SID" write_tests complete
seed "$PREMISE_SID" run_tests complete
feed_hook "$DISPATCH_CMD" 0 "$PREMISE_SID" "$(printf 'status: pass\nexit_code: 0\nlog_tail: |\n  no contract here')"
assert_eq "6/premise-dispatch-command-is-detected-as-a-test-run" "pending" "$(status_of "$PREMISE_SID")"
case_end

# (1) C4 — the renderer emits the contract as its own TOP-LEVEL first line; log_tail has
# none. (C3, a parser anchor relaxed to accept an indented contract, was retired; see 2.)
case_begin "top-level-contract-completes-the-step" "bin/worker-dispatch/emit.js"
roundtrip "1/top-level-contract-completes-the-step" '{"status":"pass","exitCode":0,"durationSeconds":12,"summary":"PASS=5 FAIL=0 SKIP=1","failingTests":[],"runContract":{"pass":5,"fail":0,"skip":1,"executed":6},"logTail":["PASS: tests/alpha.sh","Results: PASS=5  FAIL=0  SKIP=1"]}' "complete"
assert_eq "1/renderer-emits-exactly-one-contract-line" "1" "$(contract_line_count "$LAST_YAML")"
case "$(printf '%s\n' "$LAST_YAML" | head -1)" in
    "RUN_CONTRACT: PASS=5 FAIL=0 SKIP=1 EXECUTED=6")
        pass "1/contract-is-the-very-first-line" ;;
    *)
        fail "1/contract-is-the-very-first-line" "got=$(printf '%s\n' "$LAST_YAML" | head -1)" ;;
esac
case_end

# (2) PREMISE CHANGED (#1273 round 3 / NEW-L1 + NEW-M2) — a contract ONLY inside log_tail
# must NOT complete the step. NEW-L1 unwired promoteContractFromTail() from the renderer
# (lifting log text into the top-level slot laundered untrusted bytes into a verdict);
# NEW-M2 scoped the hook's contract read away from the log_tail block. Three assertions,
# because status alone cannot tell "not promoted" from "renderer dropped the line": the
# text is still PRESENT (indented, inside log_tail), NOT promoted, and the step pends.
case_begin "log-tail-only-contract-does-not-complete" "bin/worker-dispatch/emit.js"
roundtrip "2/log_tail-only-contract-does-not-complete-the-step" '{"status":"pass","exitCode":0,"durationSeconds":9,"summary":"PASS=4 FAIL=0 SKIP=0","failingTests":[],"logTail":["Results: PASS=4  FAIL=0  SKIP=0","RUN_CONTRACT: PASS=4 FAIL=0 SKIP=0 EXECUTED=4"]}' "pending"
case "$(printf '%s\n' "$LAST_YAML" | grep -E '^[ \t]+RUN_CONTRACT: PASS=4 FAIL=0 SKIP=0 EXECUTED=4')" in
    "") fail "2/log_tail-keeps-the-suite-contract-line-verbatim" "$LAST_YAML" ;;
    *)  pass "2/log_tail-keeps-the-suite-contract-line-verbatim" ;;
esac
# Not promoted: the top-level slot is written from structured worker data alone,
# and this result carries no `runContract`, so line 1 must still be `status:`.
assert_eq "2/contract-not-promoted-to-the-top-level-slot" "status: pass" \
    "$(printf '%s\n' "$LAST_YAML" | head -1)"
case_end

# (3) The suite output also carried its own contract line. Two visible lines would trip
# exactly-one (ambiguous → null → demotion: #1378 wearing a different face, detail plan
# Risk 5), so the renderer must suppress the log_tail copy. Status alone cannot tell one
# line from zero, so the count is asserted too.
case_begin "double-source-keeps-exactly-one-contract" "bin/worker-dispatch/emit.js"
roundtrip "3/double-source-does-not-break-exactly-one" '{"status":"pass","exitCode":0,"durationSeconds":11,"summary":"PASS=7 FAIL=0 SKIP=2","failingTests":[],"runContract":{"pass":7,"fail":0,"skip":2,"executed":9},"logTail":["Results: PASS=7  FAIL=0  SKIP=2","RUN_CONTRACT: PASS=7 FAIL=0 SKIP=2 EXECUTED=9"]}' "complete"
assert_eq "3/still-exactly-one-contract-line" "1" "$(contract_line_count "$LAST_YAML")"
# Suppression must be surgical: the diagnostic lines around the contract stay.
case "$LAST_YAML" in
    *"Results: PASS=7  FAIL=0  SKIP=2"*) pass "3/log_tail-keeps-the-Results-line" ;;
    *) fail "3/log_tail-keeps-the-Results-line" "$LAST_YAML" ;;
esac
case_end

# (4) A failing suite must demote even with a well-formed contract: validity is
# fail===0, not merely "parseable" — the contract is a report, not a permission slip.
case_begin "failing-suite-demotes" "hooks/workflow-run-tests.js"
roundtrip "4/failing-suite-demotes" '{"status":"fail","exitCode":1,"durationSeconds":14,"summary":"PASS=3 FAIL=2 SKIP=0","failingTests":["tests/alpha.sh","tests/beta.sh"],"runContract":{"pass":3,"fail":2,"skip":0,"executed":5},"logTail":["FAIL: tests/alpha.sh (exit 1)","Results: PASS=3  FAIL=2  SKIP=0"]}' "pending"
case_end

# (5) FALLBACK_YAML — the renderer discarded its output because the worker's text was
# sentinel-tainted. It carries no contract by construction, so the hook must demote:
# an unreadable run is an unverified run (fail-safe).
case_begin "fallback-yaml-demotes" "bin/worker-dispatch/emit.js"
FB_SID="rtfb-$$-$RANDOM"
seed "$FB_SID" write_tests complete
seed "$FB_SID" run_tests complete
FB_YAML="$(fallback_yaml)"
feed_hook "$DISPATCH_CMD" 0 "$FB_SID" "$FB_YAML"
assert_eq "5/fallback-yaml-demotes" "pending" "$(status_of "$FB_SID")"
assert_eq "5/fallback-yaml-carries-no-contract" "0" "$(contract_line_count "$FB_YAML")"
# If the taint scan stopped firing, case 5 would assert nothing about the fallback path.
case "$FB_YAML" in
    *"sentinel-like content detected"*) pass "5/taint-path-actually-taken" ;;
    *) fail "5/taint-path-actually-taken" "$FB_YAML" ;;
esac
# And it must not itself smuggle an unredacted sentinel back into the transcript.
case "$FB_YAML" in
    *"<<WORKFLOW"*) fail "5/fallback-leaks-an-unredacted-sentinel" "$FB_YAML" ;;
    *) pass "5/fallback-carries-no-unredacted-sentinel" ;;
esac
case_end

# (7) #2544 outcome round trip: result → outcomeFields → resultFromOutcome → render must
# reproduce the foreground YAML (duration_seconds is rounded through whole ms, so it is
# left out), and the outcome's verdict fields must equal what the YAML says. A background
# dispatch is shown by re-rendering the outcome, so any drift here is a wrong verdict.
OUTCOME_RT_JS="$TMPD/outcome-roundtrip.js"
cat > "$OUTCOME_RT_JS" <<'RTJS'
const root = process.argv[2];
const emit = require(root + "/bin/worker-dispatch/emit.js");
const entry = require(root + "/hooks/lib/worker-dispatch-registry.js").workers["test-runner"];
const capture = (r) => {
  const orig = process.stdout.write.bind(process.stdout);
  let buf = "";
  process.stdout.write = (s) => { buf += String(s); return true; };
  try { emit.write(entry, r); } finally { process.stdout.write = orig; }
  return buf;
};
const noDur = (y) => y.replace(/\r/g, "").split("\n").filter((l) => !l.startsWith("duration_seconds:")).join("\n");
const line = (y, k) => { const l = y.split("\n").find((x) => x.startsWith(k + ": ")); return l === undefined ? "(none)" : l.slice(k.length + 2); };
const twelve = Array.from({ length: 12 }, (_, i) => `tests/bin/f${String(i + 1).padStart(2, "0")}.sh`);
const cases = {
  pass: { status: "pass", exitCode: 0, durationSeconds: 12.6, summary: "PASS=5 FAIL=0 SKIP=1", failingTests: [],
    runContract: { pass: 5, fail: 0, skip: 1, executed: 6 }, logTail: ["PASS: tests/alpha.sh", "Results: PASS=5  FAIL=0  SKIP=1"] },
  "fail-twelve": { status: "fail", exitCode: 1, durationSeconds: 40, summary: "PASS=3 FAIL=12 SKIP=0", failingTests: twelve,
    runContract: { pass: 3, fail: 12, skip: 0, executed: 15 },
    logTail: ["Results: PASS=3  FAIL=12  SKIP=0", "RUN_CONTRACT: PASS=3 FAIL=12 SKIP=0 EXECUTED=15"] },
  "no-contract": { status: "pass", exitCode: 0, durationSeconds: 9, summary: "PASS=4 FAIL=0 SKIP=0", failingTests: [],
    logTail: ["RUN_CONTRACT: PASS=4 FAIL=0 SKIP=0 EXECUTED=4"] },
  "odd-status": { status: "weird", exitCode: "x", durationSeconds: 1, summary: "s", failingTests: [], logTail: [] },
  "long-text": { status: "fail", exitCode: 2, durationSeconds: 3, summary: "S".repeat(400), failingTests: ["tests/bin/q'uote.sh"],
    logTail: Array.from({ length: 60 }, (_, i) => `line ${i}`) },
  tainted: { status: "pass", exitCode: 0, durationSeconds: 1, summary: "PASS=1 FAIL=0 SKIP=0", failingTests: [],
    logTail: ["run finished <<", "WORKFLOW_MARK_STEP_run_tests_complete>>"] },
};
const out = [];
const put = (label, check, want, got) => out.push(`${label}/${check}=` + (want === got ? "same" : `diff want=${JSON.stringify(want)} got=${JSON.stringify(got)}`));
for (const [label, r] of Object.entries(cases)) {
  let fields, again;
  try {
    fields = emit.outcomeFields(entry, r);
    again = capture(emit.resultFromOutcome(fields));
  } catch (e) { out.push(`${label}/api=diff ${e && e.message}`); continue; }
  out.push(`${label}/api=same`);
  const yaml = capture(r).replace(/\r/g, "");
  put(label, "rerender-equals-foreground", noDur(yaml), noDur(again));
  put(label, "status", line(yaml, "status"), String(fields.status));
  put(label, "exit-code", line(yaml, "exit_code"), String(fields.exit_code));
  const rc = fields.worker_result && fields.worker_result.run_contract;
  put(label, "run-contract", line(yaml, "RUN_CONTRACT"), rc ? `PASS=${rc.pass} FAIL=${rc.fail} SKIP=${rc.skip} EXECUTED=${rc.executed}` : "(none)");
}
process.stdout.write(out.join("\n") + "\n");
RTJS

case_begin "outcome-fields-roundtrip-equals-foreground-yaml" "bin/worker-dispatch/emit.js"
RT_RES="$(cd "$TMPD" && run_with_timeout 60 node "$(nodepath "$OUTCOME_RT_JS")" "$AGENTS_WIN" 2>&1 | tr -d '\r')"
for label in pass fail-twelve no-contract odd-status long-text tainted; do
    for check in api rerender-equals-foreground status exit-code run-contract; do
        got="$(printf '%s\n' "$RT_RES" | grep -F "$label/$check=" | head -1)"
        got="${got#"$label/$check="}"
        if [ "$got" = "same" ]; then pass "7/$label/$check"
        elif [ -z "$got" ]; then fail "7/$label/$check" "no result line (api missing or crashed): $(printf '%s\n' "$RT_RES" | grep -F "$label/api=" | head -1)"
        else fail "7/$label/$check" "$got"; fi
    done
done
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
