#!/usr/bin/env node
// Claude Code PostToolUse hook: mark run_tests from the run-all.sh contract.
// Completion is driven ONLY by the RUN_CONTRACT line tests/run-all.sh (or the
// worker-dispatch test-runner) emits, never by a raw exit code (#1242, C′):
// non-zero exit or no trusted valid contract → pending; exactly one trusted
// contract with executed>0, fail==0 → complete (if write_tests is satisfied).
// The run_tests sentinel is the other completion authority. Detection and
// provenance are delegated wholly to ./workflow-run-tests/exec-model.js (#1273):
// no substring matcher lives here, so echoes and read-only mentions stay excluded
// by the general rule. Trust model summary: docs/architecture/claude-code/settings/hooks.md.

const fs = require("fs");
const { resolveSessionId, markStep, readState } = require("./workflow-state");
const { isTestCommand, resolveTestProvenance } = require("./workflow-run-tests/exec-model");
const {
  WORKER_PASS_STATUS,
  parseWorkerVerdict,
  isContractTrusted,
  resolveRunOutcome,
} = require("./workflow-run-tests/outcome");
const { stampTestFailureRisk } = require("./workflow-run-tests/test-failure-risk");
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

// The demoting command is recorded so a demotion is attributable later (#1378).
// It is untrusted AND durable text: sentinel-redacted (an unredacted `<<WORKFLOW…`
// in state text reads as a real sentinel) and credential-elided (the state file
// outlives the session, so `--token=…` must not survive the copy). Order matters:
// collapse control bytes first (they hide a secret's shape), redact secrets next,
// sanitizeLine's sentinel pass and length cap last — so truncation can never
// leave a credential's prefix behind.
function sanitizeTrigger(command) {
  return sanitizeLine(redactSecrets(collapseControl(String(command || ""))), MAX_TRIGGER_LEN);
}

// --- payload scoping (#1273 round 3 / NEW-M2) --------------------------------
// The worker-dispatch payload (bin/worker-dispatch/emit.js renderTestRunnerYaml)
// emits its authoritative fields — contract, `status:`, `exit_code:` — first and
// unindented, then `log_tail: |` with suite-chosen bytes; a contract after that
// marker is log text. So on THAT route only, reads are scoped to the header — by
// position, which emit.js guarantees, not indentation, which it does not. Run-all
// stdout is raw suite output (`log_tail: |` may legitimately appear in it), so it
// is read WHOLE under the exactly-one rule. The same positional scope bounds
// `status:` and, since #1665, the derived `run_outcome` (risk (i)).
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

// --- stdout attribution (#1273 round 5 / H1) ---------------------------------
// Every window above is cut from the CONCATENATED stdout of one Bash call, and a
// compound command may put other segments' bytes before or after the emitter
// (round 4 answered WHICH EMITTER; this answers WHICH BYTES — CPR-SC). By position:
//   worker-dispatch — at most one unindented contract, at offset 0, and exactly
//     one unindented `log_tail: |` marker (a second means a second payload);
//   run-all — the single contract is the last non-empty thing in stdout.
// Failing either means no byte is attributable → NOT TRUSTED, unconditional
// demotion (the payload's own `status:` is the doubted claim). Zero contracts is
// not an attribution failure: contract-absent demotes with its own reason.
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

// The worker's OWN verdict fields. On the worker-dispatch route the OS exit code
// is 0 by construction, so these are the runner's only way to say it failed, and
// they VETO a contract computed from raw stdout (the process is more authoritative).
// ALLOWLIST, not denylist (#1273 round 3 / NEW-L2): the renderer's vocabulary is
// pass | fail | timeout | runner-error, so only `pass` is green and anything else —
// a typo, a value clipped by emit.js's 64-char cap, a missing line — vetoes.
// The parse lives in ./workflow-run-tests/outcome.js parseWorkerVerdict() (R7),
// shared with run_outcome so the veto and the recorded outcome cannot disagree.
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

try {
  // --- trust conditions, evaluated BEFORE the exit-code fast path ------------
  // ORDER (#1665 / C1): run-all.sh prints a valid contract THEN exits 1 when
  // FAIL>0, so parsing must precede the exit-code check or the commonest failure
  // records "no observation". OUTCOME axis reads only the contract; STATUS axis
  // keeps its fail-safe (non-zero exit → pending) unchanged (CPR-SC).
  // LOCAL CATCH (#1665 / R2): resolveTestProvenance() does realpath/stat/read on
  // the emitter, so hoisted above the fast path it can throw. Without this catch
  // the outer fail-open would skip BOTH writes and leave a stale `complete`; the
  // fallback is contract-absent defaults (outcome withheld, demotions still run).
  let hasProvenance = false;
  let ambiguous = false;
  let emitter = null;
  let contract = null;
  let attributed = false;
  let vetoed = false;
  let workerStatus = null;

  try {
    // C′ contract-trust model; all must hold, else ACTIVE DEMOTION to pending:
    //   (a) provenance: an execution position names an authorised emitter —
    //       tests/run-all.sh however spelled, or the worker-dispatch test-runner
    //       (#1798: that form carries no run-all.sh literal at all)
    //   (b) exactly one well-formed RUN_CONTRACT: line (parseContract)
    //   (c) validity: executed>0, (PASS+FAIL)>0, FAIL==0
    // Relative execution positions resolve against the Bash tool's cwd, falling
    // back to process.cwd() like the sibling hooks (enforce-worktree.js et al.);
    // normalizeCwd handles the POSIX drive-letter form Git Bash delivers.
    const toolCwd = input.tool_input && typeof input.tool_input.cwd === "string"
      ? input.tool_input.cwd : undefined;
    const commandCwd = normalizeCwd(toolCwd) || process.cwd();

    // (a) also carries a filesystem identity check now: the emitter must BE this
    //     repo's tests/run-all.sh or bin/worker-dispatch.js, not merely share its
    //     name (#1273 H2 — a same-named file plus a hand-written contract line was
    //     otherwise a complete run_tests completion).
    const provenance = resolveTestProvenance(command, commandCwd);
    hasProvenance = provenance !== null;
    // (a′) AMBIGUOUS PROVENANCE (#1273 round 4 / NEW-N1). When the command holds
    //      two DISTINCT authorised emitters, the shell concatenated their output
    //      into one flat string and no byte of it is attributable to a segment.
    //      "Which emitter produced this contract?" then has no answer, and an
    //      unanswerable provenance question resolves to NOT TRUSTED — the same
    //      rule provenance-identity.js applies to a path it cannot verify. The
    //      demotion is unconditional: the payload's own `status:` is precisely the
    //      claim whose author is in doubt, so it may not rescue the run.
    ambiguous = hasProvenance && provenance.ambiguous === true;
    // The RESOLVED route. Everything that reads stdout is scoped by it: only the
    // worker-dispatch route has a renderer-owned payload shape to scope to.
    emitter = hasProvenance ? provenance.emitter : null;
    contract = hasProvenance ? parseContract(toolResponse, emitter) : null;
    // (a″) UNATTRIBUTED STDOUT (#1273 round 5 / H1). See stdoutAttributed() for
    //      why position — not presence, not indentation — is the property each
    //      emitter actually guarantees.
    attributed = !hasProvenance || stdoutAttributed(toolResponse, emitter);

    // (d) the worker's own status/exit_code veto, scoped to the route where the OS
    //     exit code carries no verdict.
    vetoed = emitter === "worker-dispatch" && workerVerdictVetoes(toolResponse);
    // The worker's own word, for the OUTCOME axis only. The veto above is the
    // STATUS axis's reading of the very same parse (R7).
    workerStatus = workerStatusOf(toolResponse, emitter);
  } catch (e) {
    // Contract-absent defaults. `attributed = false` is the conservative reading:
    // the question "are these bytes the emitter's own?" was never answered, and an
    // unanswered attribution question resolves to NOT TRUSTED, so the outcome is
    // withheld rather than guessed. The status demotions below still run.
    hasProvenance = false;
    ambiguous = false;
    emitter = null;
    contract = null;
    attributed = false;
    vetoed = false;
    workerStatus = null;
  }

  // The OUTCOME axis, decided once from already-computed scalars only — never
  // from raw stdout (risk (i); see ./workflow-run-tests/outcome.js). `null` is a
  // TOMBSTONE: no trustworthy observation exists, so any prior annotation is
  // cleared rather than left to read as current.
  const outcomeInput = { emitter, ambiguous, attributed, vetoed, contract, workerStatus };
  const runOutcome = resolveRunOutcome(outcomeInput);

  // Fast path: non-zero exit code always reverts to pending regardless of
  // contract. Unconditional — it runs whether or not the local catch above fired,
  // because the STATUS fail-safe never depended on the trust computation.
  if (exitCode !== 0) {
    markStep(sessionId, "run_tests", "pending", {
      last_run_failed: true,
      last_exit_code: exitCode,
      trigger_command: sanitizeTrigger(command),
      run_outcome: runOutcome,
    });
    // #2430: a red suite outside the red-expected steps is a handoff risk. Never throws.
    stampTestFailureRisk(sessionId);
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
    });
    // A silent demotion is why #1378 cost a session to diagnose. The reason goes
    // to the ONE channel a human reads directly — and only here: the valid-contract
    // path stays quiet, because a message on every green run trains the reader to
    // ignore the channel.
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
    // A null-valued annotation is a tombstone (#1733 projection): the key
    // disappears while the event stays in the stream. Without this, a demotion
    // recorded earlier in the session keeps its "demoted because X" note visible
    // on a step that has since actually completed — a stale reason is read as a
    // current one.
    //
    // origin override: this is PostToolUse pattern-detection on a Bash
    // command, not a deliberate user/skill action — must not count as
    // "this session genuinely started the workflow" (#1794 ADOPTION_ORIGINS).
    markStep(sessionId, "run_tests", "complete", {
      last_run_failed: null,
      last_exit_code: null,
      contract_absent: null,
      trigger_command: null,
      run_outcome: "pass",
    }, { origin: "workflow-run-tests-auto-detect" });
  }
  // else: write_tests not yet satisfied → fail-open (do not mark complete).
} catch (e) {
  // fail-open — gate will block on next commit if state was not written
}

done();
