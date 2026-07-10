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
// completion authority. Read-only commands are excluded (echo is a member, so
// workflow sentinel echoes are excluded via that rule).

const fs = require("fs");
const { resolveSessionId, markStep, readState } = require("./lib/workflow-state");
const { parse, resolveEffectiveSegment } = require("./lib/command-ir");

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

function done() {
  console.log(JSON.stringify({}));
  process.exit(0);
}

// Read-only command set — commands that read files but don't run tests.
// These are excluded from test detection regardless of path references.
const READ_ONLY_CMDS = new Set([
  "ls", "cat", "head", "tail", "grep", "rg", "find", "wc", "file", "stat",
  "echo", "printf", "which", "type", "pwd"
]);

// Git subcommands that do not execute tests. `grep` is included: `git grep
// tests/foo` is a read-only search that merely references a test path and must
// not demote run_tests (the same read-only-mention class this hook guards).
const GIT_NON_EXEC_SUBCMDS = new Set([
  "diff", "log", "show", "status", "blame", "ls-files", "ls-tree",
  "cat-file", "rev-parse", "fetch", "remote", "add", "commit", "push",
  "merge", "rebase", "pull", "stash", "tag", "grep"
]);

// Git global options that consume the following token as their value
// (e.g. `git -C <path> ...`, `git -c <name>=<value> ...`).
const GIT_VALUE_OPTS = new Set([
  "-C", "-c", "--git-dir", "--work-tree", "--namespace",
  "--exec-path", "--super-prefix"
]);

// Resolve the git subcommand, skipping any leading global options
// (e.g. `git -C path --no-pager diff` -> "diff"). Value-taking options
// consume their following token; `--opt=value` and bare flags are single tokens.
function resolveGitSubcommand(argv) {
  let i = 0;
  while (i < argv.length) {
    const tok = argv[i];
    if (tok.startsWith("-")) {
      i += GIT_VALUE_OPTS.has(tok) ? 2 : 1;
      continue;
    }
    return tok;
  }
  return "";
}

function isTestCommand(command) {
  const trimmed = command.trim();
  if (!trimmed) return false;

  const ir = parse(trimmed);
  if (ir.parseFailure) return false;

  for (const seg of ir.segments) {
    const effective = resolveEffectiveSegment(seg);
    if (effective === null) continue;
    if (effective.cmd0 === "") continue;

    // Read-only command exclusion — check resolved effective cmd0. `echo` is a
    // member, so workflow sentinel echoes (`echo "<<...`) are excluded here too;
    // this also covers env-prefixed forms (`FOO=1 echo "<<...`) that a raw-text
    // prefix match would miss, since cmd0 is resolved past the assignment.
    if (READ_ONLY_CMDS.has(effective.cmd0)) continue;

    // Git non-exec command exclusion — resolve the subcommand past any
    // leading global options (-C <path>, -c <k=v>, --no-pager, --git-dir=…).
    if (effective.cmd0 === "git") {
      // Empty subcommand (only global options, e.g. `git -C tests/` or bare
      // `git`) executes nothing — treat as non-exec so a bare test-path
      // reference in the global-option value cannot demote run_tests.
      const gitSub = resolveGitSubcommand(effective.argv);
      if (gitSub === "" || GIT_NON_EXEC_SUBCMDS.has(gitSub)) continue;
    }

    // Test detection — check effective segment (cmd0 + argv joined)
    const effectiveText = effective.cmd0 + " " + effective.argv.join(" ");

    // Test path reference: tests/ or test/ anywhere in the segment
    if (/\btests?\//.test(effectiveText)) return true;

    // Test runner commands
    if (/\b(pytest|jest|vitest|mocha|pester|invoke-pester)\b/i.test(effectiveText)) return true;
    if (/\buv\s+run\s+pytest\b/.test(effectiveText)) return true;
    if (/\b(bash|sh|node|pwsh|powershell(?:\.[a-z]+)?)\s+\S*tests?\//i.test(effectiveText)) return true;
    if (/\.Tests\.ps1\b/i.test(effectiveText)) return true;
  }
  return false;
}

// True iff the command string invokes run-all.sh (the only authorised contract
// emitter). Provenance-only check — does not analyse pipe/compound structure.
// Matches: tests/run-all.sh, ./tests/run-all.sh, bash tests/run-all.sh, etc.
const RUN_ALL_SH_RE = /(?:^|[\s;|&])(?:[./\w-]*\/)?tests\/run-all\.sh\b/;
function isRunAllSh(command) {
  return RUN_ALL_SH_RE.test(command);
}

// Count and parse RUN_CONTRACT lines in tool_response.stdout.
// Returns null in all non-success cases:
//   - stdout absent or not a string
//   - zero well-formed contract lines (absent)
//   - two or more well-formed contract lines (ambiguous: forged append or fixture collision)
//   - any field is NaN (malformed integer in the single line)
// Contract format is fixed: PASS FAIL SKIP EXECUTED (in this order). Extension
// via #1241 requires lockstep changes to both run-all.sh and this parser.
function parseContract(toolResponse) {
  const stdout = (toolResponse && typeof toolResponse.stdout === "string")
    ? toolResponse.stdout : "";
  if (!stdout) return null;

  const CONTRACT_LINE_RE =
    /^RUN_CONTRACT: PASS=(\d+) FAIL=(\d+) SKIP=(\d+) EXECUTED=(\d+)/gm;
  const matches = [...stdout.matchAll(CONTRACT_LINE_RE)];

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
    });
    done();
  }

  // C′ contract-trust model with provenance gating and exactly-one rule.
  // Trust conditions (all must hold):
  //   (a) provenance: command contains a run-all.sh invocation (isRunAllSh)
  //   (b) stdout has exactly one well-formed RUN_CONTRACT: line (parseContract)
  //       — zero → absent; >=2 → ambiguous (forged append or fixture collision)
  //   (c) validity: executed>0, (PASS+FAIL)>0, FAIL==0
  // Any failure → ACTIVE DEMOTION to pending (clears a stale complete).
  const hasProvenance = isRunAllSh(command);
  const contract = hasProvenance ? parseContract(toolResponse) : null;

  const contractValid = contract !== null
    && contract.executed > 0
    && (contract.pass + contract.fail) > 0  // all-SKIP guard
    && contract.fail === 0;

  if (!contractValid) {
    // ACTIVE DEMOTION: a test command ran but no trusted valid contract arrived.
    // Covers: ad-hoc commands, piped run-all.sh, no-match (executed=0),
    // all-skip, FAIL>0, compound-forge (>=2 contract lines), fixture collision.
    markStep(sessionId, "run_tests", "pending", {
      last_run_failed: false,
      contract_absent: !hasProvenance || contract === null,
    });
    done();
  }

  // Contract is valid. Preserve the PR #1165 write_tests guard: only mark
  // run_tests complete when write_tests is already complete or skipped.
  const state = readState(sessionId);
  const writeTestsStatus = state && state.steps && state.steps.write_tests
    ? state.steps.write_tests.status
    : undefined;
  if (writeTestsStatus === "complete" || writeTestsStatus === "skipped") {
    markStep(sessionId, "run_tests", "complete");
  }
  // else: write_tests not yet satisfied → fail-open (do not mark complete).
} catch (e) {
  // fail-open — gate will block on next commit if state was not written
}

done();
