# shellcheck shell=bash
# tests/lib/dispatch-outcome-fixture.sh — places a trusted worker outcome in a session control dir.
# Tests: tests/lib/dispatch-outcome-fixture.sh
# Tags: test-infrastructure, shared-lib, fixture, run-tests, dispatch-outcome, scope:common
# One owner for the file set the run_tests hook ingests (#2544): the payload, its
# dispatch marker and an outcome whose digest matches the payload bytes.
# Needs WORKFLOW_STATE_DIR pinned by the caller; defines no pass/fail helpers.

DOF_REPO_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then DOF_REPO_DEFAULT="$(cygpath -m "$DOF_REPO_DEFAULT")"; fi

# State-side names, kept here so a rename is a one-line change for every caller.
# shellcheck disable=SC2034
DOF_INGEST_ANNOTATION="outcome_source"
# A command that is no test run: driving the hook with it exercises ingest alone.
# shellcheck disable=SC2034
DOF_INGEST_TRIGGER_CMD="git status"

# dispatch_outcome_place <sid> <seq> <status> <pass> <fail> <skip> [<cwd>] [<failing-tests-json>] [<log-tail-json>]
# Writes worker-test-runner-<seq>.json, .dispatched and .outcome.json; prints the stem.
# <cwd> defaults to the checkout holding this helper (an empty value means the default);
# <log-tail-json> is a JSON array of lines, defaulting to one Results line. Returns
# non-zero, with a message on stderr, when the fixture could not be written.
dispatch_outcome_place() {
  local sid="${1:?dispatch_outcome_place: <sid> required}" seq="${2:?<seq> required}"
  local status="${3:?<status> required}" pass="${4:?<pass> required}"
  local fail="${5:?<fail> required}" skip="${6:?<skip> required}"
  local cwd="${7:-$DOF_REPO_DEFAULT}" failing="${8:-[]}" tail="${9:-}"
  if [[ -z "${WORKFLOW_STATE_DIR:-}" ]]; then
    echo "dispatch_outcome_place: WORKFLOW_STATE_DIR is not pinned" >&2
    return 1
  fi
  node -e '
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const [sid, seq, status, pass, fail, skip, cwd, failing, tail] = process.argv.slice(1);
const n = (v) => { const x = Number(v); if (!Number.isInteger(x) || x < 0) throw new Error("bad count " + v); return x; };
const stem = "worker-test-runner-" + seq;
const dir = path.join(process.env.WORKFLOW_STATE_DIR, sid + ".control");
fs.mkdirSync(dir, { recursive: true });
const bytes = Buffer.from(JSON.stringify({ test_args: [], cwd, timeout_seconds: 300, nonce: stem }) + "\n");
fs.writeFileSync(path.join(dir, stem + ".json"), bytes);
fs.writeFileSync(path.join(dir, stem + ".dispatched"), new Date().toISOString() + "\n");
const outcome = {
  schema_version: 1,
  worker: "test-runner",
  stem,
  session_id: sid,
  payload_sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
  cwd,
  status,
  exit_code: status === "pass" ? 0 : 1,
  duration_ms: 1200,
  worker_result: {
    run_contract: { pass: n(pass), fail: n(fail), skip: n(skip), executed: n(pass) + n(fail) + n(skip) },
    failing_tests: JSON.parse(failing),
    log_tail: tail ? JSON.parse(tail) : ["Results: PASS=" + pass + "  FAIL=" + fail + "  SKIP=" + skip],
    summary: "PASS=" + pass + " FAIL=" + fail + " SKIP=" + skip,
  },
};
fs.writeFileSync(path.join(dir, stem + ".outcome.json"), JSON.stringify(outcome) + "\n");
process.stdout.write(stem + "\n");
' "$sid" "$seq" "$status" "$pass" "$fail" "$skip" "$cwd" "$failing" "$tail"
}
