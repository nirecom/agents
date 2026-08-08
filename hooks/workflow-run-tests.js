#!/usr/bin/env node
// Claude Code PostToolUse hook: mark run_tests from the run-all.sh contract.
//
// Fires on every Bash tool call. Trust model (#1242, Approach C′): completion
// is driven ONLY by the machine-readable RUN_CONTRACT line that tests/run-all.sh
// emits — never inferred from a raw exit code. For a detected test command:
//   non-zero exit                          → run_tests: pending (fail-safe)
//   run-all.sh provenance + exactly one
//     valid RUN_CONTRACT (executed>0,
//     fail==0)                             → run_tests: complete (if write_tests satisfied)
//   any other test command / no contract   → run_tests: pending (active demotion)
//
// The run_tests sentinel (WORKFLOW_MARK_STEP_run_tests_complete) is the other
// completion authority.
//
// Detection and provenance are BOTH delegated to the execution-position model in
// ./workflow-run-tests/exec-model.js — the single judgement source (#1273). This
// file deliberately holds no substring matcher of its own: the read-only command
// list, the git non-exec list and the five runner regexes it used to carry were
// a second, disagreeing axis, and are gone rather than kept as a fallback. A head
// that sits in none of exec-model's tables (`echo`, `cat`, `git diff`, …) simply
// has no execution position that names a test, so sentinel echoes and read-only
// mentions stay excluded by the general rule.

const fs = require("fs");
const { resolveSessionId, markStep, readState } = require("./workflow-state");
const { isTestCommand, resolveTestProvenance } = require("./workflow-run-tests/exec-model");
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

// The demoting command is recorded so a demotion is attributable after the fact
// (#1378's diagnosis cost was exactly this absence). It is untrusted text that a
// later reader may transcribe into a Claude Code context, so it goes through the
// same sentinel redaction the worker dispatcher uses — an unredacted
// `<<WORKFLOW…` in state text is indistinguishable from a real sentinel.
//
// Credentials are elided on the way in for the second reason state text is
// dangerous: it is durable. A command line carries the caller's tokens as
// ordinary argument values, and the state file outlives the session, so
// `--token=…` must not survive the copy. Order matters: collapse first (a
// control byte inside a secret would otherwise hide its shape), redact secrets
// next, and let sanitizeLine do the sentinel pass and the length cap last — so
// truncation can never leave a credential's prefix behind.
function sanitizeTrigger(command) {
  return sanitizeLine(redactSecrets(collapseControl(String(command || ""))), MAX_TRIGGER_LEN);
}

// --- payload scoping -------------------------------------------------------
//
// WHY (CPR-WPH): the worker-dispatch payload has two halves with opposite trust.
// bin/worker-dispatch/emit.js renderTestRunnerYaml() emits the authoritative
// fields — the contract line, `status:`, `exit_code:` — FIRST and unindented,
// then opens `log_tail: |` and hard-indents every remaining line by two spaces.
// Everything after that marker is bytes the SUITE chose, so a `RUN_CONTRACT:`
// line found there is log text, not a verdict.
//
// The `^[ \t]*` tolerance in the contract regex stays (a legitimate contract is
// leading-whitespace-tolerant in the historical payload shape #1378 documents);
// what changes is WHERE it may look. Scoping to the header answers "is this line
// authoritative?" by position, which is the property emit.js actually guarantees,
// instead of by indentation, which it does not.
//
// SCOPED TO ONE ROUTE (#1273 round 3 / NEW-M2). That guarantee is emit.js's, so
// the truncation may only be applied where emit.js wrote the bytes. On the
// run-all route stdout is raw suite output: `log_tail: |` is then eleven
// characters a suite may legitimately print (a test of the payload renderer, a
// YAML fixture, a diff of emit.js), and cutting there both deletes the suite's
// own trailing contract and promotes whatever preceded the marker to sole
// authority. Raw suite output is read WHOLE, so the hook's existing exactly-one
// rule keeps deciding it.
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
// WHY (CPR-WPH): every window above is cut out of the CONCATENATED stdout of a
// whole Bash tool call, and each cut silently assumes stdout BEGINS (or, on the
// run-all route, ENDS) with the trusted emitter's own bytes. The shell
// guarantees no such thing: a compound command may put any number of
// stdout-producing segments in front of — or behind — the emitter, and a
// `printf` adds no execution position, so round 4's emitter-identity check
// (NEW-N1) provably never fires on it. Round 4 answered "WHICH EMITTER"; this
// answers "WHICH BYTES", the orthogonal half (CPR-SC).
//
// The fix is positional, because POSITION is exactly what each emitter
// guarantees and neither indentation nor mere presence does:
//
//   worker-dispatch — bin/worker-dispatch/emit.js renderTestRunnerYaml() emits
//     the contract as the FIRST line of its payload and exactly ONE unindented
//     `log_tail: |` marker, whose block scalar then runs to end-of-output. So a
//     genuine single payload holds at most one unindented contract line, at
//     offset 0, and exactly one unindented marker. A second marker means a
//     second payload's (or a forged prefix's) bytes are in the string, and the
//     hook cannot say which segment wrote which half.
//
//   run-all — tests/run-all.sh prints its RUN_CONTRACT line LAST, after the
//     `Results:` summary, and exits. So a genuine contract is the last non-empty
//     thing in stdout; anything trailing it belongs to some other segment.
//
// Failing either check is NOT "the contract is wrong" — it is "no byte of this
// stdout is attributable to the emitter". Like an unverifiable emitter path
// (round 3 / H2) and an unanswerable emitter identity (round 4 / N1), an
// unanswerable byte-provenance question resolves to NOT TRUSTED, and the
// demotion is unconditional: the payload's own `status:` is precisely the claim
// whose author is in doubt, so it may not rescue the run.
//
// Zero contract lines is deliberately NOT an attribution failure: that is the
// pre-existing contract-absent case, and it already demotes with its own reason.
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
// is 0 by construction ("I produced a result"), never the suite verdict, so the
// non-zero fast path below can structurally never fire there — these two fields
// are the only place the runner gets to say it failed. They VETO: a contract
// computed from raw stdout can disagree with the process that ran the suite (a
// suite that died after printing its summary, a harness that miscounted), and
// the process is the more authoritative of the two.
//
// ALLOWLIST, not denylist (#1273 round 3 / NEW-L2). Enumerating the bad
// spellings waves through everything else, and "not a known failure" is not the
// same claim as "the worker said it passed": a renamed vocabulary word, a typo
// (`passed`), or a value clipped by emit.js's 64-char `plainValue` cap all land
// outside any denylist and read as success. The renderer's vocabulary is
// pass | fail | timeout | runner-error, so the sanctioned green set has exactly
// one member and anything else — including a missing `status:` line — vetoes.
const WORKER_PASS_STATUS = "pass";

function workerVerdictVetoes(toolResponse) {
  const header = responseHeader(toolResponse, "worker-dispatch");
  if (header === "") return false;
  const sm = /^status:[ \t]*(\S+)/m.exec(header);
  if (sm === null || sm[1].toLowerCase() !== WORKER_PASS_STATUS) return true;
  const em = /^exit_code:[ \t]*(-?\d+)/m.exec(header);
  if (em !== null && parseInt(em[1], 10) !== 0) return true;
  return false;
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
  // Fast path: non-zero exit code always reverts to pending regardless of contract.
  if (exitCode !== 0) {
    markStep(sessionId, "run_tests", "pending", {
      last_run_failed: true,
      last_exit_code: exitCode,
      trigger_command: sanitizeTrigger(command),
    });
    done();
  }

  // C′ contract-trust model with provenance gating and exactly-one rule.
  // Trust conditions (all must hold):
  //   (a) provenance: an execution position names an authorised contract emitter
  //       — tests/run-all.sh however it is spelled, or the worker-dispatch
  //       test-runner worker (#1798: that form carries no run-all.sh literal at
  //       all, so the old substring probe was structurally always false)
  //   (b) stdout has exactly one well-formed RUN_CONTRACT: line (parseContract)
  //       — zero → absent; >=2 → ambiguous (forged append or fixture collision)
  //   (c) validity: executed>0, (PASS+FAIL)>0, FAIL==0
  // Any failure → ACTIVE DEMOTION to pending (clears a stale complete).
  // The Bash tool's own cwd is what a relative execution position is relative to;
  // `process.cwd()` is the fallback the sibling hooks (enforce-worktree.js,
  // scan-outbound.js, show-user-verified-context.js) use for exactly this input
  // class. normalizeCwd handles the POSIX drive-letter form Git Bash delivers.
  const toolCwd = input.tool_input && typeof input.tool_input.cwd === "string"
    ? input.tool_input.cwd : undefined;
  const commandCwd = normalizeCwd(toolCwd) || process.cwd();

  // (a) also carries a filesystem identity check now: the emitter must BE this
  //     repo's tests/run-all.sh or bin/worker-dispatch.js, not merely share its
  //     name (#1273 H2 — a same-named file plus a hand-written contract line was
  //     otherwise a complete run_tests completion).
  const provenance = resolveTestProvenance(command, commandCwd);
  const hasProvenance = provenance !== null;
  // (a′) AMBIGUOUS PROVENANCE (#1273 round 4 / NEW-N1). When the command holds
  //      two DISTINCT authorised emitters, the shell concatenated their output
  //      into one flat string and no byte of it is attributable to a segment.
  //      "Which emitter produced this contract?" then has no answer, and an
  //      unanswerable provenance question resolves to NOT TRUSTED — the same
  //      rule provenance-identity.js applies to a path it cannot verify. The
  //      demotion is unconditional: the payload's own `status:` is precisely the
  //      claim whose author is in doubt, so it may not rescue the run.
  const ambiguous = hasProvenance && provenance.ambiguous === true;
  // The RESOLVED route. Everything that reads stdout is scoped by it: only the
  // worker-dispatch route has a renderer-owned payload shape to scope to.
  const emitter = hasProvenance ? provenance.emitter : null;
  const contract = hasProvenance ? parseContract(toolResponse, emitter) : null;
  // (a″) UNATTRIBUTED STDOUT (#1273 round 5 / H1). See stdoutAttributed() for
  //      why position — not presence, not indentation — is the property each
  //      emitter actually guarantees.
  const attributed = !hasProvenance || stdoutAttributed(toolResponse, emitter);

  // (d) the worker's own status/exit_code veto, scoped to the route where the OS
  //     exit code carries no verdict.
  const vetoed = emitter === "worker-dispatch" && workerVerdictVetoes(toolResponse);

  const contractValid = !ambiguous
    && attributed
    && !vetoed
    && contract !== null
    && contract.executed > 0
    && (contract.pass + contract.fail) > 0  // all-SKIP guard
    && contract.fail === 0;

  if (!contractValid) {
    // ACTIVE DEMOTION: a test command ran but no trusted valid contract arrived.
    // Covers: ad-hoc commands, piped run-all.sh, no-match (executed=0),
    // all-skip, FAIL>0, compound-forge (>=2 contract lines), fixture collision.
    const contractAbsent = !hasProvenance || contract === null;
    markStep(sessionId, "run_tests", "pending", {
      last_run_failed: false,
      contract_absent: contractAbsent,
      trigger_command: sanitizeTrigger(command),
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
    }, { origin: "workflow-run-tests-auto-detect" });
  }
  // else: write_tests not yet satisfied → fail-open (do not mark complete).
} catch (e) {
  // fail-open — gate will block on next commit if state was not written
}

done();
