#!/usr/bin/env node
// Claude Code PostToolUse hook: record run_tests from a trusted run report.
// Two routes, one judgement (./workflow-run-tests/record-run.js):
//   file route — the worker-dispatch outcome file in the control dir, ingested on
//     any Bash call (./workflow-run-tests/dispatch-outcome.js, #2544);
//   stdout route — the RUN_CONTRACT line of tests/run-all.sh or the worker in this
//     call's stdout (#1242, C′), which cannot complete while a dispatch is unsettled.
// Only a current-shape contract with executed>0, fail==0, unrunnable==0 completes (#2501).
// Detection and provenance live in ./workflow-run-tests/exec-model.js (#1273).
// Trust model summary: docs/architecture/claude-code/settings/hooks.md.

const fs = require("fs");
const { resolveSessionId } = require("./workflow-state");
const { isTestCommand, resolveTestProvenance } = require("./workflow-run-tests/exec-model");
const { parseWorkerVerdict, workerVerdictVetoes } = require("./workflow-run-tests/outcome");
const { demotionReason } = require("./workflow-run-tests/demotion");
const { extractFailingTests, emitterRoot } = require("./workflow-run-tests/failing-list");
const { applyDispatchOutcome } = require("./workflow-run-tests/dispatch-outcome");
const { recordRun } = require("./workflow-run-tests/record-run");
const { CONTRACT_PREFIX_RE, findSingleContract, runtimeLabels } = require("./lib/run-contract");
const { sanitizeLine, collapseControl, redactSecrets } = require("./lib/output-sanitize");
const { normalizeCwd } = require("./lib/path-normalize");

const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

const HOOK_NAME = "workflow-run-tests";
const MAX_TRIGGER_LEN = 300;

// `systemMessage` is HUMAN-FACING DIAGNOSTICS ONLY: nothing may read it back as a
// judgement input (W-3 / Risk 10). The workflow-state file is the only machine output.
function done(message) {
  console.log(JSON.stringify(message ? { systemMessage: message } : {}));
  process.exit(0);
}

// The trigger is untrusted, durable text (#1378): collapse control bytes, elide
// credentials, then sentinel-redact and cap — so truncation never leaves a secret prefix.
function sanitizeTrigger(command) {
  return sanitizeLine(redactSecrets(collapseControl(String(command || ""))), MAX_TRIGGER_LEN);
}

// --- payload scoping (#1273 round 3) -----------------------------------------
// The worker payload (bin/worker-dispatch/emit.js) puts its authoritative fields
// first and unindented, then `log_tail: |` with suite-chosen bytes; on THAT route
// reads are scoped to the header by position. Run-all stdout is read whole.
const LOG_TAIL_MARKER_RE = /^log_tail:[ \t]*\|.*$/m;
const LOG_TAIL_MARKER_SCAN_RE = /^log_tail:[ \t]*\|.*$/gm;

function payloadHeader(stdout) {
  const m = LOG_TAIL_MARKER_RE.exec(stdout);
  return m === null ? stdout : stdout.slice(0, m.index);
}

function responseStdout(toolResponse) {
  return (toolResponse && typeof toolResponse.stdout === "string") ? toolResponse.stdout : "";
}

function responseHeader(toolResponse, emitter) {
  const stdout = responseStdout(toolResponse);
  return emitter === "worker-dispatch" ? payloadHeader(stdout) : stdout;
}

// --- stdout attribution (#1273 round 5 / H1) ---------------------------------
// Which bytes of a compound command's stdout belong to the emitter, by position:
//   worker-dispatch — at most one contract line, the first line, and exactly
//     one `log_tail: |` marker; run-all — the single contract line is the last
//     non-empty line. Failing either means NOT TRUSTED. Zero contracts is
//     contract-absent instead.
function stdoutAttributed(toolResponse, emitter) {
  const stdout = responseStdout(toolResponse);
  if (stdout === "") return true;
  const lines = stdout.split("\n");
  const at = lines.map((l, i) => (CONTRACT_PREFIX_RE.test(l) ? i : -1)).filter((i) => i !== -1);
  if (emitter === "worker-dispatch") {
    if ([...stdout.matchAll(LOG_TAIL_MARKER_SCAN_RE)].length !== 1) return false;
    return at.length === 0 || (at.length === 1 && at[0] === 0);
  }
  if (emitter === "run-all") {
    if (at.length === 0) return true;
    return at.length === 1 && lines.slice(at[0] + 1).every((l) => l.trim() === "");
  }
  return true;
}

// The worker's own verdict vetoes a contract computed from its stdout (allowlist,
// #1273 round 3 / NEW-L2); the parse and the rule live in ./workflow-run-tests/outcome.js.
function stdoutVerdictVetoes(toolResponse) {
  const header = responseHeader(toolResponse, "worker-dispatch");
  if (header === "") return false;
  const { status, exitCode } = parseWorkerVerdict(header);
  return workerVerdictVetoes(status, exitCode);
}

function workerStatusOf(toolResponse, emitter) {
  if (emitter !== "worker-dispatch") return null;
  return parseWorkerVerdict(responseHeader(toolResponse, "worker-dispatch")).status;
}

// The runtimes a contract-unrunnable run lacks, as "a,b" (D5-7: the accept handler reads this,
// never stdout). run-all prints a line-anchored `Missing runtimes:` line (neutralized child
// lines carry a prefix); the worker leads its header `summary:` with the same text.
const RUNALL_MISSING_RE = /^Missing runtimes: ([^\r\n]+)$/gm;
const WORKER_MISSING_RE = /^summary:[ \t]*'?Missing runtimes: ([^;'\r\n]+)/m;
function missingRuntimes(toolResponse, emitter) {
  const header = responseHeader(toolResponse, emitter);
  if (emitter === "worker-dispatch") {
    const m = WORKER_MISSING_RE.exec(header);
    return m === null ? null : runtimeLabels(m[1]);
  }
  const all = [...header.matchAll(RUNALL_MISSING_RE)];
  return all.length === 0 ? null : runtimeLabels(all[all.length - 1][1]);
}

const UNTRUSTED = {
  hasProvenance: false, ambiguous: false, emitter: null, contract: null, contractMiss: null,
  attributed: false, vetoed: false, workerStatus: null, failingRoot: null,
};

// C′ trust conditions: (a) provenance names an authorised emitter, (a′) only one,
// (a″) attributed stdout, (b) exactly one well-formed contract (hooks/lib/run-contract.js),
// (d) no worker veto. Computed before the exit-code fast path (#1665 / C1); a throw
// resolves to NOT TRUSTED (R2).
function stdoutTrust(command, toolInput, toolResponse) {
  try {
    const toolCwd = toolInput && typeof toolInput.cwd === "string" ? toolInput.cwd : undefined;
    const commandCwd = normalizeCwd(toolCwd) || process.cwd();
    const provenance = resolveTestProvenance(command, commandCwd);
    const hasProvenance = provenance !== null;
    const emitter = hasProvenance ? provenance.emitter : null;
    const found = hasProvenance ? findSingleContract(responseHeader(toolResponse, emitter).split("\n")) : null;
    const contract = found !== null && found.reason === undefined ? found : null;
    return {
      hasProvenance,
      ambiguous: hasProvenance && provenance.ambiguous === true,
      emitter,
      contract,
      contractMiss: found !== null && contract === null ? found : null,
      attributed: !hasProvenance || stdoutAttributed(toolResponse, emitter),
      vetoed: emitter === "worker-dispatch" && stdoutVerdictVetoes(toolResponse),
      workerStatus: workerStatusOf(toolResponse, emitter),
      failingRoot: hasProvenance ? emitterRoot(provenance.path, commandCwd) : null,
    };
  } catch (e) {
    return UNTRUSTED;
  }
}

// Recorded only from trusted, attributed emitter bytes; null unless every entry is real.
function stdoutFailingTests(t, toolResponse) {
  try {
    if (!t.hasProvenance || t.ambiguous || !t.attributed || t.contract === null || t.contract.fail === 0) return null;
    return extractFailingTests({
      stdout: responseStdout(toolResponse),
      isWorker: t.emitter === "worker-dispatch",
      worktreeRoot: t.failingRoot,
      contract: t.contract,
    });
  } catch (e) {
    return null;
  }
}

let input;
const hookInput = readHookInput();
if (hookInput.kind !== "ok") {
  try {
    fs.writeSync(2, readFailOpenDiagnostic(HOOK_NAME, hookInput, "run_tests not recorded") + "\n");
  } catch (e) {}
  done();
} else {
  input = hookInput.input;
}

if (!input || input.tool_name !== "Bash") done();

const rawCommand = input.tool_input && input.tool_input.command;
const command = (typeof rawCommand === "string" ? rawCommand : "").trim();
if (!command) done();

const sessionId = input.session_id || resolveSessionId();
if (!sessionId) done();

const testCommand = isTestCommand(command);

// File route first, on every Bash call: the command string plays no part (#2544).
let dispatch = { ingested: false, unsettledStem: null, message: null };
try {
  dispatch = applyDispatchOutcome({ sessionId, triggerCommand: sanitizeTrigger(command), isTest: testCommand });
} catch (e) {
  // fail-open: an unreadable control dir leaves the stdout route as before
}

if (!testCommand) done(dispatch.message);

const toolResponse = input.tool_response || {};
const exitCode = toolResponse.exit_code ?? toolResponse.exitCode ?? (toolResponse.success === false ? 1 : 0);

try {
  // An ingested outcome file is authoritative; stdout must not overwrite it.
  if (dispatch.ingested) done(dispatch.message);
  const t = stdoutTrust(command, input.tool_input, toolResponse);
  const reason = demotionReason(t);
  const message = recordRun({
    sessionId,
    exitCode,
    triggerCommand: sanitizeTrigger(command),
    outcomeInput: {
      emitter: t.emitter,
      ambiguous: t.ambiguous,
      attributed: t.attributed,
      vetoed: t.vetoed,
      contract: t.contract,
      workerStatus: t.workerStatus,
    },
    failingTests: stdoutFailingTests(t, toolResponse),
    unrunnableRuntimes: reason === "contract-unrunnable" ? missingRuntimes(toolResponse, t.emitter) : null,
    contractAbsent: !t.hasProvenance || t.contract === null,
    reason,
    unsettledStem: dispatch.unsettledStem,
    stampRisk: true,
  });
  done(message || dispatch.message);
} catch (e) {
  // fail-open — gate will block on next commit if state was not written
}

done();
