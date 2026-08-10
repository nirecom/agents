# shellcheck shell=bash
# tests/feature-1665-run-outcome/common.sh
# Tests: hooks/workflow-run-tests/outcome.js, hooks/workflow-run-tests.js
# Tags: workflow, run-tests, run-outcome, helpers, TL1, TL2, scope:issue-specific
#
# Shared helpers + fixture isolation for the feature-1665-run-outcome dispatcher.
# Sourced by feature-1665-run-outcome.sh before any case group.

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); return 0; }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_ne() {
    local name="$1" unwanted="$2" got="$3"
    if [ "$unwanted" != "$got" ]; then pass "$name"
    else fail "$name" "must-not-be=$(printf '%q' "$unwanted") got=$(printf '%q' "$got")"; fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name" "missing=$(printf '%q' "$needle") in=$(printf '%q' "$hay")" ;;
    esac
}

# rules/test.md: every test run is wrapped in a timeout so a hang cannot block
# the suite. 120s is the repo default; individual node invocations get 30s.
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Node on Windows cannot require() a Git Bash /c/... path (it maps to C:\c\...).
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
AGENTS_WIN="$(nodepath "$AGENTS_DIR")"

RUN_TESTS_HOOK="$AGENTS_DIR/hooks/workflow-run-tests.js"
OUTCOME_JS="$AGENTS_WIN/hooks/workflow-run-tests/outcome.js"
EXEC_MODEL_JS="$AGENTS_WIN/hooks/workflow-run-tests/exec-model.js"
WD_WRITE_JS="$AGENTS_WIN/hooks/enforce-worktree/worker-dispatch-write.js"
PROBE_JS="$(nodepath "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")/lib-outcome-probe.js"

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/f1665-ro-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): DUAL-PIN the workflow dir
# and the plans dir — pinning only CLAUDE_WORKFLOW_DIR routes hook state into the
# fixture while a supervisor emitter on the same path still appends to the
# developer's real ~/.workflow-plans. Clear the inherited live session ids so a
# hook can never resolve, and mutate, the session running this suite. Exported
# once here so every child `node` inherits both.
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# Neutral fixture repo: hooks that shell out to git must not resolve the real
# worktree. core.hooksPath is disabled so the installed pre-commit hook cannot
# fire inside it.
FIXTURE_REPO="$TMPD/repo"
mkdir -p "$FIXTURE_REPO"
( cd "$FIXTURE_REPO" && git init -q . >/dev/null 2>&1 \
    && git config core.hooksPath /dev/null >/dev/null 2>&1 ) || true

# --- outcome.js probe (TL1) -------------------------------------------------
# probe <mode> <json-input> → the module's answer as a printable string.
# Modes: resolve | trusted | parse | values (see lib-outcome-probe.js).
# Prints ERR:<reason> when outcome.js is missing or does not export the entry —
# which is the EXPECTED RED signal before the module lands.
probe() {
    run_with_timeout 30 node "$PROBE_JS" "$AGENTS_WIN" "$1" "$2" 2>/dev/null \
        || echo "ERR:probe-crashed"
}

# --- real-hook drivers (TL2) ------------------------------------------------

# hook_payload <command> <exit_code> <stdout> <sid> <cwd> → PostToolUse JSON
hook_payload() {
    run_with_timeout 30 node -e '
const payload = {
  tool_name: "Bash",
  tool_input: { command: process.argv[1], cwd: process.argv[5] },
  tool_response: { exit_code: parseInt(process.argv[2], 10), stdout: process.argv[3] },
  session_id: process.argv[4]
};
process.stdout.write(JSON.stringify(payload));
' "$1" "$2" "$3" "$4" "$5" 2>/dev/null
}

# drive_hook <command> <exit_code> <sid> <stdout> [<entry-js>] → hook stdout JSON
# entry-js defaults to the hook itself; i-identity-throw.sh passes a wrapper that
# pre-poisons the provenance-identity module in the require cache.
drive_hook() {
    local entry="${5:-$RUN_TESTS_HOOK}"
    printf '%s' "$(hook_payload "$1" "$2" "$4" "$3" "$AGENTS_WIN")" \
        | run_with_timeout 30 node "$entry" 2>/dev/null || true
}

# --- state readers ----------------------------------------------------------

# step_field <sid> <step> <field> → value | (absent)
# A tombstoned (null-valued) annotation disappears from the projection, so
# `(absent)` is exactly what "outcome cleared" looks like on disk.
step_field() {
    run_with_timeout 30 node -e '
try {
  const s = require(process.argv[1] + "/hooks/workflow-state").readState(process.argv[2]);
  const e = s && s.steps && s.steps[process.argv[3]];
  const v = e ? e[process.argv[4]] : undefined;
  process.stdout.write(v === undefined || v === null ? "(absent)" : String(v));
} catch (err) { process.stdout.write("(absent)"); }
' "$AGENTS_WIN" "$1" "$2" "$3" 2>/dev/null || echo "(absent)"
}

# annotation_provenance <sid> <step> <key> → provenance of the LAST such
# annotation event | (absent). Provenance lives on the event, not the projection.
annotation_provenance() {
    run_with_timeout 30 node -e '
try {
  const s = require(process.argv[1] + "/hooks/workflow-state").readState(process.argv[2]);
  const evs = (s && Array.isArray(s.events)) ? s.events : [];
  let out = "(absent)";
  for (const e of evs) {
    if (e && e.kind === "step_annotation" && e.step === process.argv[3] && e.key === process.argv[4]) {
      out = String(e.provenance);
    }
  }
  process.stdout.write(out);
} catch (err) { process.stdout.write("(absent)"); }
' "$AGENTS_WIN" "$1" "$2" "$3" 2>/dev/null || echo "(absent)"
}

# event_count <sid> → integer count of recorded events (0 when no state file).
event_count() {
    run_with_timeout 30 node -e '
try {
  const s = require(process.argv[1] + "/hooks/workflow-state").readState(process.argv[2]);
  process.stdout.write(String((s && Array.isArray(s.events)) ? s.events.length : 0));
} catch (err) { process.stdout.write("0"); }
' "$AGENTS_WIN" "$1" 2>/dev/null || echo "0"
}

# seed_step <sid> <step> <status> [<annotation-key> <annotation-value>]
seed_step() {
    run_with_timeout 30 node -e '
const extra = {};
if (process.argv[5]) extra[process.argv[5]] = process.argv[6];
require(process.argv[1] + "/hooks/workflow-state")
  .markStep(process.argv[2], process.argv[3], process.argv[4], extra);
' "$AGENTS_WIN" "$1" "$2" "$3" "${4:-}" "${5:-}" >/dev/null 2>&1 || true
}

# --- canonical commands -----------------------------------------------------
# Real paths in THIS repo, so provenance-identity.js's filesystem check verifies
# them. Nothing here attacks emitter identity — the outcome axis is under test.
RUNALL_CMD="bash $AGENTS_WIN/tests/run-all.sh"
DISPATCH_CMD="node $AGENTS_WIN/bin/worker-dispatch.js test-runner $AGENTS_WIN $TMPD/s-worker.json"
