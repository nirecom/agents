"use strict";
// exec-model.js — execution-position model for workflow-run-tests (#1273 / #1798).
//
// WHY (CPR-WPH): the previous classifier asked "does the text `tests/` appear
// anywhere in this segment?". That question has no notion of WHERE a token sits,
// so `node bin/supervisor-report --detail "ran tests/foo.sh"` was classified as a
// test run and demoted run_tests. The replacement asks a structural question
// instead: WHICH TOKENS CAN THIS COMMAND EXECUTE?
//
// Only three token positions can be executed:
//   P0  the resolved cmd0 itself
//   P1  an interpreter's script/module operand (`bash <p1>`, `python -m <p1>`,
//       `pwsh -File <p1>`)
//   P2  the worker name after a known dispatcher script sitting at P1
//       (`node .../worker-dispatch.js <p2> …`)
// A token that appears only as an argument VALUE is never in an execution
// position, so it cannot demote regardless of what it spells.
//
// This module is the SINGLE judgement source. There is deliberately no substring
// fallback anywhere: a second judgement axis is what made #1273's predecessor
// (PR #1335) unfixable — two axes disagree, and the disagreement is invisible.
//
// BODY forms are NEVER recursed into (`bash -c "…"`, `pwsh -Command "…"`,
// `git rebase -x "…"`, `git filter-branch --tree-filter '…'`,
// `git submodule foreach '…'`, `perl -e '…'`). Reading inside a single argv
// token would reintroduce exactly that second axis. `git bisect run bash
// tests/foo.sh` IS recursed because there the executed command occupies
// SEPARATE argv tokens — the asymmetry is deliberate, not an oversight.

const { parse, resolveEffectiveSegment } = require("../lib/command-ir");
const { verifyEmitterIdentity } = require("./provenance-identity");

// --- head tables -----------------------------------------------------------
// Matched on basename(token).toLowerCase(); the `.exe` suffix is PRESERVED, so
// `powershell.exe` is its own entry rather than being normalised away.

// Runners that prepend themselves to another command: the real command follows,
// as separate argv tokens, once this runner's own operands are consumed.
const PREFIX_RUNNERS = new Map([
  // name -> { value: options taking a following-token value, operands: count of
  //           non-option operands belonging to the runner itself,
  //           assignments: true when VAR=val tokens precede the command }
  ["timeout", { value: new Set(["-k", "-s", "--signal", "--kill-after"]), operands: 1 }],
  ["env", { value: new Set(["-u", "--unset", "-C", "--chdir", "-S", "--split-string"]), assignments: true }],
  ["time", { value: new Set(["-o", "--output", "-f", "--format"]) }],
  ["nohup", { value: new Set() }],
  ["sudo", { value: new Set(["-u", "--user", "-g", "--group", "-p", "--prompt", "-C", "--close-from", "-h", "--host", "-r", "--role", "-t", "--type", "-U", "--other-user"]) }],
  ["nice", { value: new Set(["-n", "--adjustment"]) }],
  ["stdbuf", { value: new Set(["-i", "--input", "-o", "--output", "-e", "--error"]) }],
  // xargs reads its OPERANDS from stdin, but the command it execs still occupies
  // SEPARATE argv tokens — the same shape as `git bisect run`, not a body string.
  // So it belongs to this table (one entry, no new control flow), and
  // `xargs bash -c "…"` stays a MISS because the recursion lands on `bash`, whose
  // own spec already refuses to read inside `-c`.
  ["xargs", { value: new Set(["-n", "--max-args", "-P", "--max-procs", "-I", "-i", "--replace", "-L", "-l", "--max-lines", "-s", "--max-chars", "-a", "--arg-file", "-d", "--delimiter", "-E", "-e", "--eof"]) }],
  ["command", { value: new Set(), lookupFlags: new Set(["-v", "-V"]) }],
  ["exec", { value: new Set(["-a"]) }],
]);

// Wrappers that require a fixed leading sub-token before the real command.
const WRAPPERS = new Map([
  ["uv", { requires: "run" }],
  ["uvx", {}],
  ["npx", { value: new Set(["-p", "--package", "-c", "--call"]) }],
  ["bunx", { value: new Set() }],
]);

// Interpreters: the operand they execute is P1.
//   value   — option consumes the NEXT token as its value (skip both)
//   body    — option's value is a COMMAND STRING; never recursed into, and the
//             segment has no P1 at all
//   module  — option whose value IS the executed module (that value is P1)
//   file    — option whose value IS the executed script (that value is P1)
//   ci      — compare option tokens case-insensitively (PowerShell family)
const SHELL_SPEC = { value: new Set(["-o", "+o", "--rcfile", "--init-file"]), body: new Set(["-c"]) };
const INTERPRETERS = new Map([
  ["bash", SHELL_SPEC],
  ["sh", SHELL_SPEC],
  ["zsh", SHELL_SPEC],
  ["dash", SHELL_SPEC],
  ["node", {
    value: new Set(["-r", "--require", "--loader", "--experimental-loader", "--conditions", "--max-old-space-size", "--inspect-port", "--title"]),
    body: new Set(["-e", "--eval", "-p", "--print"]),
  }],
  ["python", { value: new Set(["-W", "-X", "--check-hash-based-pycs"]), body: new Set(["-c"]), module: new Set(["-m"]) }],
  ["python3", { value: new Set(["-W", "-X", "--check-hash-based-pycs"]), body: new Set(["-c"]), module: new Set(["-m"]) }],
  ["ruby", { value: new Set(["-r", "-I", "-C"]), body: new Set(["-e"]) }],
  ["perl", { value: new Set(["-I", "-M"]), body: new Set(["-e", "-E"]) }],
  ["pwsh", { ci: true, value: new Set(["-executionpolicy", "-ex", "-configurationname", "-outputformat", "-inputformat", "-workingdirectory", "-wd"]), body: new Set(["-command", "-c", "-encodedcommand", "-e", "-ec"]), file: new Set(["-file", "-f"]) }],
]);
INTERPRETERS.set("powershell", INTERPRETERS.get("pwsh"));
INTERPRETERS.set("powershell.exe", INTERPRETERS.get("pwsh"));
INTERPRETERS.set("pwsh.exe", INTERPRETERS.get("pwsh"));

// Test-runner words. Matched at P0 and at P1 (`python -m pytest`) — never at an
// argument position.
const RUNNER_WORDS = new Set([
  "pytest", "jest", "vitest", "mocha", "pester", "invoke-pester", "unittest", "nose2",
]);

// git subcommands that execute a FOLLOWING command given as separate argv tokens.
// `rebase` (-x) and `filter-branch` (--*-filter) are deliberately absent: their
// command is a single body token.
const GIT_EXEC_SUBCMDS = new Map([
  ["bisect", "run"],
  ["submodule", "foreach"],
]);

// git global options that consume the following token as their value.
const GIT_VALUE_OPTS = new Set([
  "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix",
]);

// Dispatcher scripts whose FIRST operand names the thing actually executed (P2),
// mapped to the worker names that run a test suite.
const DISPATCHER_SCRIPTS = new Map([
  ["worker-dispatch.js", new Set(["test-runner"])],
]);

const TEST_PATH_RE = /(?:^|[/\\])tests?[/\\]/i;
const PESTER_FILE_RE = /\.Tests\.ps1$/i;
const RUN_ALL_SUFFIX = "tests/run-all.sh";

// A shared depth budget: ONE counter per segment, +1 per level actually entered.
// A head-table re-lookup at the same level is not an increment. Overflow is
// fail-SAFE: the result truncates to the outermost P0, so an absurdly nested
// command is a MISS (no demotion), never a false demotion.
const MAX_DEPTH = 5;

function headOf(token) {
  const s = String(token == null ? "" : token).replace(/\\/g, "/");
  const base = s.slice(s.lastIndexOf("/") + 1);
  return base.toLowerCase();
}

function isOption(token) {
  return typeof token === "string" && token.length > 1 && token.startsWith("-");
}

const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// A candidate head that carries whitespace is a BODY STRING that the shell would
// have split, not a command token. Refusing it here makes the body forms absent
// EXPLICITLY rather than incidentally.
function isBodyToken(token) {
  return typeof token !== "string" || token === "" || /\s/.test(token);
}

// A "level" is one command found at one recursion depth.
function makeLevel(value, raw, argv, argvRaw) {
  const cooked = Array.isArray(argv) ? argv : [];
  const rawArgs = Array.isArray(argvRaw) && argvRaw.length === cooked.length ? argvRaw : cooked.slice();
  return { value: String(value == null ? "" : value), raw: String(raw == null ? value : raw), argv: cooked, argvRaw: rawArgs };
}

function sliceLevel(level, from) {
  return makeLevel(level.argv[from], level.argvRaw[from], level.argv.slice(from + 1), level.argvRaw.slice(from + 1));
}

// Resolve the P1 operand index for an interpreter, or -1 when there is none
// (a body option was reached, or the operand list ran out).
function interpreterOperandIndex(spec, argv) {
  const norm = (t) => (spec.ci ? String(t).toLowerCase() : String(t));
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    const key = norm(tok);
    if (spec.body && spec.body.has(key)) return -1;
    if (spec.module && spec.module.has(key)) return i + 1 < argv.length ? i + 1 : -1;
    if (spec.file && spec.file.has(key)) return i + 1 < argv.length ? i + 1 : -1;
    if (spec.value && spec.value.has(key)) { i++; continue; }
    if (isOption(tok)) continue;
    return i;
  }
  return -1;
}

// Index of the first token after a prefix runner's own operands, or -1.
function prefixRunnerNextIndex(spec, argv) {
  let operandsLeft = spec.operands || 0;
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    if (spec.lookupFlags && spec.lookupFlags.has(tok)) return -1; // `command -v x` looks up, never executes
    if (spec.value && spec.value.has(tok)) { i++; continue; }
    if (isOption(tok)) continue;
    if (spec.assignments && ASSIGN_RE.test(tok)) continue;
    if (operandsLeft > 0) { operandsLeft--; continue; }
    return i;
  }
  return -1;
}

function gitSubcommandIndex(argv) {
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    if (isOption(tok)) { i += GIT_VALUE_OPTS.has(tok) ? 1 : 0; continue; }
    return i;
  }
  return -1;
}

function walk(level, out, state) {
  out.push({ value: level.value, raw: level.raw, position: "P0" });

  const head = headOf(level.value);
  const argv = level.argv;

  const recurse = (idx) => {
    if (idx < 0 || idx >= argv.length) return;
    if (isBodyToken(argv[idx])) return;
    if (state.depth >= MAX_DEPTH) { state.overflow = true; return; }
    state.depth++;
    walk(sliceLevel(level, idx), out, state);
  };

  const prefixSpec = PREFIX_RUNNERS.get(head);
  if (prefixSpec) return recurse(prefixRunnerNextIndex(prefixSpec, argv));

  const wrapperSpec = WRAPPERS.get(head);
  if (wrapperSpec) {
    let from = 0;
    if (wrapperSpec.requires) {
      if (argv[0] !== wrapperSpec.requires) return;
      from = 1;
    }
    const rest = argv.slice(from);
    const idx = prefixRunnerNextIndex({ value: wrapperSpec.value || new Set() }, rest);
    return recurse(idx < 0 ? -1 : from + idx);
  }

  const interpSpec = INTERPRETERS.get(head);
  if (interpSpec) {
    const idx = interpreterOperandIndex(interpSpec, argv);
    if (idx < 0) return;
    out.push({ value: String(argv[idx]), raw: String(level.argvRaw[idx]), position: "P1" });
    const workers = DISPATCHER_SCRIPTS.get(headOf(argv[idx]));
    if (workers && idx + 1 < argv.length) {
      out.push({ value: String(argv[idx + 1]), raw: String(level.argvRaw[idx + 1]), position: "P2" });
    }
    return;
  }

  if (head === "git" || head === "git.exe") {
    const subIdx = gitSubcommandIndex(argv);
    if (subIdx < 0) return;
    const keyword = GIT_EXEC_SUBCMDS.get(String(argv[subIdx]).toLowerCase());
    if (!keyword) return;
    if (argv[subIdx + 1] !== keyword) return;
    return recurse(subIdx + 2);
  }
}

/**
 * Execution positions of one RESOLVED segment IR (post resolveEffectiveSegment).
 *
 * @param {object} effectiveSeg - resolved SegmentIR ({cmd0, cmd0Raw, argv, argvRaw})
 * @returns {Array<{value: string, raw: string, position: "P0"|"P1"|"P2"}>}
 */
function execTargets(effectiveSeg) {
  if (!effectiveSeg || typeof effectiveSeg.cmd0 !== "string" || effectiveSeg.cmd0 === "") return [];
  const level = makeLevel(effectiveSeg.cmd0, effectiveSeg.cmd0Raw, effectiveSeg.argv, effectiveSeg.argvRaw);
  const out = [];
  const state = { depth: 0, overflow: false };
  walk(level, out, state);
  if (state.overflow) return out.length > 0 ? [out[0]] : [];
  return out;
}

// Every execution position of every segment of a command string, in order.
function allExecTargets(command) {
  const trimmed = typeof command === "string" ? command.trim() : "";
  if (!trimmed) return [];
  const ir = parse(trimmed);
  if (ir.parseFailure) return null; // fail-closed: caller decides
  const out = [];
  for (const seg of ir.segments) {
    const eff = resolveEffectiveSegment(seg);
    if (eff === null || eff.cmd0 === "") continue;
    for (const t of execTargets(eff)) out.push(t);
  }
  return out;
}

function normalizePath(value) {
  return String(value == null ? "" : value).replace(/\\/g, "/");
}

function isTestTarget(target) {
  if (target.position === "P2") return false; // P2 is judged with its dispatcher
  const norm = normalizePath(target.value);
  if (TEST_PATH_RE.test(norm)) return true;
  if (PESTER_FILE_RE.test(norm)) return true;
  return RUNNER_WORDS.has(headOf(norm));
}

/**
 * True iff some execution position of `command` names a test suite, a test
 * runner, or a dispatcher worker that runs one.
 *
 * @param {string} command
 * @returns {boolean}
 */
function isTestCommand(command) {
  const targets = allExecTargets(command);
  if (targets === null) return false; // parse failure → not a test command (fail-safe)
  for (let i = 0; i < targets.length; i++) {
    const t = targets[i];
    if (t.position === "P2") {
      const workers = DISPATCHER_SCRIPTS.get(headOf(targets[i - 1] ? targets[i - 1].value : ""));
      if (workers && workers.has(String(t.value).toLowerCase())) return true;
      continue;
    }
    if (isTestTarget(t)) return true;
  }
  return false;
}

/**
 * Resolve WHICH authorised contract emitter produced this run, or null.
 *
 * Replaces the old RUN_ALL_SH_RE substring probe. Because it reads the resolved
 * execution positions rather than the raw text, it is spelling-independent:
 * relative, `./`-prefixed, POSIX-absolute, drive-letter (`C:/…`) and
 * prefix-runner-wrapped invocations all resolve to the same suffix.
 *
 * A name is not an identity, so the spelling match is only half the judgement:
 * the matched path is then checked against the real emitter location on disk
 * (./provenance-identity.js). A same-named file elsewhere therefore carries no
 * emitter authority (#1273 H2). The matched path is returned alongside the
 * emitter so a caller can re-verify or attribute it.
 *
 * EVERY verifying position is read, not just the first (#1273 round 4 / NEW-N1).
 * Returning at the first match answered "which authorised emitter appears
 * earliest in this command?", but the caller's real question is "which process
 * wrote this stdout?" — and those diverge the moment a command holds more than
 * one segment. `bash tests/run-all.sh --help; node bin/worker-dispatch.js
 * test-runner …` resolved to run-all while the stdout was the worker's YAML
 * payload, which switched off both worker-dispatch-only protections (the
 * status veto and the log_tail scoping) over exactly the payload they guard.
 *
 * The shell concatenated the segments and the tool response carries one flat
 * string, so no byte of stdout is attributable to a segment. When the verifying
 * positions name MORE THAN ONE DISTINCT emitter the provenance question is
 * therefore unanswerable, and — following the same "unverifiable ⇒ untrusted"
 * rule provenance-identity.js applies to a path that resolves to nothing — the
 * result is flagged `ambiguous`. The caller must demote on that flag alone,
 * regardless of what the output claims. `emitter` is still filled in, by
 * dispatcher precedence (the more constrained route), so a caller that scopes
 * its reading by route keeps doing so on the safer of the two.
 *
 * The SAME emitter appearing twice is not ambiguity: attribution is unaffected,
 * so those runs keep their ordinary single-emitter judgement.
 *
 * @param {string} command
 * @param {string} [cwd] - cwd the command ran in; defaults to process.cwd()
 * @returns {{emitter: "run-all"|"worker-dispatch", path: string, ambiguous: boolean}|null}
 */
function resolveTestProvenance(command, cwd) {
  const targets = allExecTargets(command);
  if (targets === null) return null;

  const found = [];
  for (let i = 0; i < targets.length; i++) {
    const t = targets[i];
    if (t.position === "P2") {
      const dispatcher = targets[i - 1] ? String(targets[i - 1].value) : "";
      const workers = DISPATCHER_SCRIPTS.get(headOf(dispatcher));
      if (workers && workers.has(String(t.value).toLowerCase())
        && verifyEmitterIdentity("worker-dispatch", dispatcher, cwd)) {
        found.push({ emitter: "worker-dispatch", path: dispatcher });
      }
      continue;
    }
    const norm = normalizePath(t.value);
    const isRunAll = norm === RUN_ALL_SUFFIX || norm.endsWith("/" + RUN_ALL_SUFFIX);
    if (isRunAll && verifyEmitterIdentity("run-all", t.value, cwd)) {
      found.push({ emitter: "run-all", path: String(t.value) });
    }
  }

  if (found.length === 0) return null;

  const distinct = new Set(found.map((f) => f.emitter));
  if (distinct.size === 1) return { emitter: found[0].emitter, path: found[0].path, ambiguous: false };

  // Dispatcher precedence: of the two routes, worker-dispatch is the one whose
  // payload shape is renderer-owned, so it carries the stricter reading rules.
  const preferred = found.find((f) => f.emitter === "worker-dispatch") || found[0];
  return { emitter: preferred.emitter, path: preferred.path, ambiguous: true };
}

module.exports = {
  execTargets,
  isTestCommand,
  resolveTestProvenance,
  // exported for tests / future callers of the same tables
  RUNNER_WORDS,
  DISPATCHER_SCRIPTS,
};
