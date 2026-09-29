#!/usr/bin/env node
// Claude Code PostToolUse hook: mark run_tests from the run-all.sh contract.
//
// Trust model (#1242, Approach C′): completion is driven ONLY by the RUN_CONTRACT
// line tests/run-all.sh emits, never by a raw exit code:
//   non-zero exit                                   → pending (fail-safe)
//   trusted provenance + exactly one valid contract → complete (if write_tests satisfied)
//   any other test command / no contract            → pending (active demotion)
// The run_tests sentinel is the other completion authority. Detection and
// provenance both come from ./workflow-run-tests/exec-model.js (#1273), the single
// judgement source; this file holds no substring matcher of its own.

const fs = require("fs");
const { resolveSessionId, markStep, readState } = require("./workflow-state");
const { isTestCommand, resolveTestProvenance } = require("./workflow-run-tests/exec-model");
const {
  WORKER_PASS_STATUS,
  parseWorkerVerdict,
  isContractTrusted,
  resolveRunOutcome,
} = require("./workflow-run-tests/outcome");
const { extractFailingTests, emitterRoot } = require("./workflow-run-tests/failing-list");
const { sanitizeLine, collapseControl, redactSecrets } = require("./lib/output-sanitize");
const { normalizeCwd } = require("./lib/path-normalize");

const MAX_TRIGGER_LEN = 300;

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {}
  return Buffer.concat(chunks).toString("utf8");
}

// `payload` is the PostToolUse hook response. Only `systemMessage` is ever put
// there, and it is HUMAN-FACING DIAGNOSTICS ONLY: nothing in this hook, and
// nothing downstream, may read it back as an input to a judgement (detail plan
// W-3 / Risk 10). The workflow-state file remains the sole machine-readable
// output.
function done(payload) {
  console.log(JSON.stringify(payload || {}));
  process.exit(0);
}

// The demoting command is recorded so a demotion is attributable (#1378). It is
// untrusted, durable text: collapse control bytes first, elide credentials next
// (`--token=…` must not outlive the session), and let sanitizeLine redact
// sentinels and cap length last so truncation never leaves a secret's prefix.
function sanitizeTrigger(command) {
  return sanitizeLine(redactSecrets(collapseControl(String(command || ""))), MAX_TRIGGER_LEN);
}

// --- payload scoping -------------------------------------------------------
//
// emit.js renderTestRunnerYaml() writes the authoritative fields FIRST, then
// `log_tail: |` and suite-chosen bytes. On the worker-dispatch route only the
// header before that marker is authoritative (position, not indentation, is
// what emit.js guarantees). The run-all route is raw suite output and is read
// WHOLE (#1273 round 3 / NEW-M2). `status:` and `run_outcome` read the header too.
const LOG_TAIL_MARKER_RE = /^log_tail:[ \t]*\|.*$/m;

function payloadHeader(stdout) {
  const m = LOG_TAIL_MARKER_RE.exec(stdout);
  return m === null ? stdout : stdout.slice(0, m.index);
}

function responseStdout(toolResponse) {
  return (toolResponse && typeof toolResponse.stdout === "string")
    ? toolResponse.stdout : "";
}

// `emitter` is the resolved provenance emitter (null when there is none).
function responseHeader(toolResponse, emitter) {
  const stdout = responseStdout(toolResponse);
  return emitter === "worker-dispatch" ? payloadHeader(stdout) : stdout;
}

// --- stdout attribution (#1273 round 5 / H1) --------------------------------
//
// Round 4 answered WHICH EMITTER; this answers WHICH BYTES. A compound command
// can put other segments' output before or after the emitter, so position is
// checked: worker-dispatch → exactly one `log_tail: |` marker and at most one
// contract, at offset 0; run-all → the contract is the last non-empty output.
// Failing either means no byte is attributable → NOT TRUSTED, unconditionally.
// Zero contract lines is not an attribution failure (contract-absent decides).
const LOG_TAIL_MARKER_SCAN_RE = /^log_tail:[ \t]*\|.*$/gm;
const CONTRACT_SCAN_RE =
  /^[ \t]*RUN_CONTRACT: PASS=\d+ FAIL=\d+ SKIP=\d+ EXECUTED=\d+/gm;

function scanAll(re, s) {
  return [...s.matchAll(new RegExp(re.source, re.flags))];
}

function stdoutAttributed(toolResponse, emitter) {
  const stdout = responseStdout(toolResponse);
  if (stdout === "") return true; // nothing to attribute; contract-absent decides
  const contracts = scanAll(CONTRACT_SCAN_RE, stdout);

  if (emitter === "worker-dispatch") {
    if (scanAll(LOG_TAIL_MARKER_SCAN_RE, stdout).length !== 1) return false;
    if (contracts.length === 0) return true;
    return contracts.length === 1 && contracts[0].index === 0;
  }

  if (emitter === "run-all") {
    if (contracts.length === 0) return true;
    if (contracts.length !== 1) return false;
    const m = contracts[0];
    return stdout.slice(m.index + m[0].length).trim() === "";
  }

  return true;
}

// The worker's OWN verdict fields VETO completion on the worker route, where
// the OS exit code is 0 by construction. ALLOWLIST (#1273 round 3 / NEW-L2):
// only `status: pass` is green; a missing, misspelled or clipped status vetoes.
// The parse lives in ./workflow-run-tests/outcome.js (R7) so the veto and
// `run_outcome` can never read the same line through two regexes.
function workerVerdictVetoes(toolResponse) {
  const header = responseHeader(toolResponse, "worker-dispatch");
  if (header === "") return false;
  const { status, exitCode } = parseWorkerVerdict(header);
  if (status !== WORKER_PASS_STATUS) return true;
  if (exitCode !== null && exitCode !== 0) return true;
  return false;
}

// The worker's own status word, or null off the worker route / when the line is
// absent. Same single parse site; the allowlist judgement stays with the caller.
function workerStatusOf(toolResponse, emitter) {
  if (emitter !== "worker-dispatch") return null;
  return parseWorkerVerdict(responseHeader(toolResponse, "worker-dispatch")).status;
}

// Count and parse RUN_CONTRACT lines in tool_response.stdout.
// Returns null in all non-success cases:
//   - stdout absent or not a string
//   - zero well-formed contract lines (absent)
//   - two or more well-formed contract lines (ambiguous: forged append or fixture collision)
//   - any field is NaN (malformed integer in the single line)
// Contract format is fixed: PASS FAIL SKIP EXECUTED (in this order). Extension
// via #1241 requires lockstep changes to both run-all.sh and this parser.
function parseContract(toolResponse, emitter) {
  const header = responseHeader(toolResponse, emitter);
  if (!header) return null;

  // Leading whitespace is tolerated — and ONLY that (#1378's payload shape).
  // The tolerance is safe here because `header` already excludes the untrusted
  // `log_tail: |` block, where indentation is the renderer's own doing.
  // Everything after the keyword stays exact.
  const CONTRACT_LINE_RE =
    /^[ \t]*RUN_CONTRACT: PASS=(\d+) FAIL=(\d+) SKIP=(\d+) EXECUTED=(\d+)/gm;
  const matches = [...header.matchAll(CONTRACT_LINE_RE)];

  // Exactly-one rule: zero → absent, two or more → ambiguous. Both → null.
  if (matches.length !== 1) return null;

  const m = matches[0];
  const p = parseInt(m[1], 10);
  const f = parseInt(m[2], 10);
  const s = parseInt(m[3], 10);
  const e = parseInt(m[4], 10);
  if ([p, f, s, e].some((n) => isNaN(n))) return null;
  return { pass: p, fail: f, skip: s, executed: e };
}

// Which of the four failure modes caused this demotion. Diagnostics only — the
// value is never read back by any code path.
function demotionReason(hasProvenance, ambiguous, contract, toolResponse, vetoed, emitter, attributed) {
  if (!hasProvenance) return "provenance-absent";
  if (ambiguous) return "provenance-ambiguous";
  if (!attributed) return "stdout-unattributed";
  if (vetoed) return "worker-status-veto";
  if (contract !== null) return "contract-invalid";
  const header = responseHeader(toolResponse, emitter);
  const count = (header.match(/^[ \t]*RUN_CONTRACT: PASS=\d+ FAIL=\d+ SKIP=\d+ EXECUTED=\d+/gm) || []).length;
  return count >= 2 ? "contract-ambiguous" : "contract-absent";
}

let input;
try {
  input = JSON.parse(readStdin());
} catch (e) {
  done(); // fail-open on malformed stdin
}

if (!input || input.tool_name !== "Bash") done();

const rawCommand = input.tool_input && input.tool_input.command;
const command = (typeof rawCommand === "string" ? rawCommand : "").trim();
if (!command) done();

if (!isTestCommand(command)) done();

const toolResponse = input.tool_response || {};
const exitCode =
  toolResponse.exit_code ??
  toolResponse.exitCode ??
  (toolResponse.success === false ? 1 : 0);

const sessionId = input.session_id || resolveSessionId();
if (!sessionId) done();

// Baseline evidence (#2431) belongs to ONE observed failing run: any new run
// clears it, so a later completion can never inherit an older classification.
const BASELINE_TOMBSTONES = { baseline_classification: null, completion_basis: null };

try {
  // Trust is evaluated BEFORE the exit-code fast path (#1665 / C1): run-all.sh
  // prints a valid contract and THEN exits 1 on FAIL>0, so the OUTCOME axis reads
  // the contract while the STATUS axis keeps its fail-safe. The local catch
  // (#1665 / R2) exists because provenance I/O can now throw; it falls back to
  // contract-absent defaults so the status demotions below still run.
  let hasProvenance = false;
  let ambiguous = false;
  let emitter = null;
  let contract = null;
  let attributed = false;
  let vetoed = false;
  let workerStatus = null;
  let failingRoot = null;

  try {
    // Trust conditions (C′, all must hold): (a) provenance names an authorised
    // emitter that IS this repo's file (#1273 H2, #1798); (b) exactly one
    // well-formed RUN_CONTRACT line; (c) executed>0, (PASS+FAIL)>0, FAIL==0.
    // Anything else → ACTIVE DEMOTION. A relative execution position resolves
    // against the Bash tool cwd (normalizeCwd), process.cwd() as fallback.
    const toolCwd = input.tool_input && typeof input.tool_input.cwd === "string"
      ? input.tool_input.cwd : undefined;
    const commandCwd = normalizeCwd(toolCwd) || process.cwd();

    const provenance = resolveTestProvenance(command, commandCwd);
    hasProvenance = provenance !== null;
    // (a′) two DISTINCT emitters in one command → no byte is attributable →
    //      NOT TRUSTED, unconditionally (#1273 round 4 / NEW-N1).
    ambiguous = hasProvenance && provenance.ambiguous === true;
    emitter = hasProvenance ? provenance.emitter : null;
    contract = hasProvenance ? parseContract(toolResponse, emitter) : null;
    // (a″) unattributed stdout (#1273 round 5 / H1) — see stdoutAttributed().
    attributed = !hasProvenance || stdoutAttributed(toolResponse, emitter);
    // (d) the worker's own status/exit_code veto, worker route only.
    vetoed = emitter === "worker-dispatch" && workerVerdictVetoes(toolResponse);
    workerStatus = workerStatusOf(toolResponse, emitter);
    failingRoot = hasProvenance ? emitterRoot(provenance.path, commandCwd) : null;
  } catch (e) {
    // Unanswered trust questions resolve to NOT TRUSTED; outcome is withheld.
    hasProvenance = false;
    ambiguous = false;
    emitter = null;
    contract = null;
    attributed = false;
    vetoed = false;
    workerStatus = null;
    failingRoot = null;
  }

  // The OUTCOME axis, decided once from already-computed scalars only — never
  // from raw stdout (risk (i); see ./workflow-run-tests/outcome.js). `null` is a
  // TOMBSTONE: no trustworthy observation exists, so any prior annotation is
  // cleared rather than left to read as current.
  const outcomeInput = { emitter, ambiguous, attributed, vetoed, contract, workerStatus };
  const runOutcome = resolveRunOutcome(outcomeInput);

  // The failing list is recorded only from trusted, attributed emitter bytes;
  // failing-list.js withholds it (null) unless every entry is a real test path.
  let failingTests = null;
  try {
    if (hasProvenance && !ambiguous && attributed && contract !== null && contract.fail > 0) {
      failingTests = extractFailingTests({
        stdout: responseStdout(toolResponse),
        isWorker: emitter === "worker-dispatch",
        worktreeRoot: failingRoot,
        contract,
      });
    }
  } catch (e) {
    failingTests = null;
  }

  // Fast path: non-zero exit code always reverts to pending regardless of
  // contract. Unconditional — it runs whether or not the local catch above fired,
  // because the STATUS fail-safe never depended on the trust computation.
  if (exitCode !== 0) {
    markStep(sessionId, "run_tests", "pending", {
      last_run_failed: true,
      last_exit_code: exitCode,
      trigger_command: sanitizeTrigger(command),
      run_outcome: runOutcome,
      failing_tests: failingTests,
      ...BASELINE_TOMBSTONES,
    });
    done();
  }

  // Derived from the ONE trust predicate (R3), never re-listed term by term.
  const contractValid = isContractTrusted(outcomeInput) && contract.fail === 0;

  if (!contractValid) {
    // ACTIVE DEMOTION: a test command ran but no trusted valid contract arrived.
    // Covers: ad-hoc commands, piped run-all.sh, no-match (executed=0),
    // all-skip, FAIL>0, compound-forge (>=2 contract lines), fixture collision.
    const contractAbsent = !hasProvenance || contract === null;
    markStep(sessionId, "run_tests", "pending", {
      last_run_failed: false,
      contract_absent: contractAbsent,
      trigger_command: sanitizeTrigger(command),
      run_outcome: runOutcome,
      failing_tests: failingTests,
      ...BASELINE_TOMBSTONES,
    });
    // A silent demotion is why #1378 cost a session to diagnose; the reason goes
    // only to the human channel, and the valid-contract path stays quiet.
    done({
      systemMessage:
        `run_tests demoted to pending (${demotionReason(hasProvenance, ambiguous, contract, toolResponse, vetoed, emitter, attributed)}). ` +
        "Completion requires tests/run-all.sh (or the worker-dispatch test-runner) " +
        "and exactly one valid RUN_CONTRACT line in its output.",
    });
  }

  // Contract is valid. Preserve the PR #1165 write_tests guard: only mark
  // run_tests complete when write_tests is already complete or skipped.
  const state = readState(sessionId);
  const writeTestsStatus = state && state.steps && state.steps.write_tests
    ? state.steps.write_tests.status
    : undefined;
  if (writeTestsStatus === "complete" || writeTestsStatus === "skipped") {
    // Null-valued annotations are tombstones (#1733): a stale demotion note must
    // not read as current on a step that has since completed. The origin override
    // marks this as pattern-detection, not a deliberate action (#1794).
    markStep(sessionId, "run_tests", "complete", {
      last_run_failed: null,
      last_exit_code: null,
      contract_absent: null,
      trigger_command: null,
      run_outcome: "pass",
      failing_tests: null,
      ...BASELINE_TOMBSTONES,
    }, { origin: "workflow-run-tests-auto-detect" });
  }
  // else: write_tests not yet satisfied → fail-open (do not mark complete).
} catch (e) {
  // fail-open — gate will block on next commit if state was not written
}

done();
