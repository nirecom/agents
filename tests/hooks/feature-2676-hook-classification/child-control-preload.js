"use strict";
// Test-only preload (node --require=<this file> hooks/<hook>.js) for the heavy-hook cases of
// tests/hooks/feature-2676-hook-classification.js, driven by F2540_* variables that only those
// cases set. It stands in for the plan's PATH shim: a node copy named git on PATH would read
// git's own options (-C) as node options on Windows.

const Module = require("module");
const childProcess = require("child_process");
const fs = require("fs");
const path = require("path");

// F2540_LIMIT_MS: decision-time-limit.js loads with DECISION_TIME_LIMIT_MS set to this value; a
// module without that declaration fails the load (as feature-2460-jev-shadow's preload does).
// The module is this checkout's, or that of the checkout copy AGENTS_MAIN_ROOT names (registration.js).
const LIMIT_REL = path.join("hooks", "lib", "decision-time-limit.js");
const TARGETS = [path.resolve(__dirname, "..", "..", "..", LIMIT_REL)]
  .concat(process.env.AGENTS_MAIN_ROOT ? [path.resolve(process.env.AGENTS_MAIN_ROOT, LIMIT_REL)] : []);
const LIMIT_LINE = /((?:const|let|var)\s+DECISION_TIME_LIMIT_MS\s*=\s*)[^;\n]+/;
const SLEEP_SCRIPT = "setTimeout(() => {}, 20000)";
const same = (left, right) => (process.platform === "win32" ? left.toLowerCase() === right.toLowerCase() : left === right);

if (process.env.F2540_LIMIT_MS) {
  const compile = Module.prototype._compile;
  Module.prototype._compile = function limitCompile(content, filename) {
    if (!TARGETS.some((target) => same(path.resolve(filename), target))) return compile.call(this, content, filename);
    if (!LIMIT_LINE.test(content)) throw new Error("child-control-preload: DECISION_TIME_LIMIT_MS declaration not found");
    return compile.call(this, content.replace(LIMIT_LINE, `$1${Number(process.env.F2540_LIMIT_MS)}`), filename);
  };
}

// Per-call modes, chosen by regexes over the command line (argv joined by spaces, git / gh /
// bash / node paths shortened to their names: "node gh api user" for a gh shebang script).
// F2540_FAIL: the call fails to start. F2540_SLOW: a node child sleeps instead, with the
// caller's options, so the caller's timeout is honored by a real process. F2540_CAPTURE: the
// call's stdin input goes to F2540_CAPTURE_FILE and it succeeds with exit 0. F2540_LOG: every
// call is appended there as one JSON line.
const regexOf = (name) => (process.env[name] ? new RegExp(process.env[name]) : null);
const SLOW = regexOf("F2540_SLOW");
const FAIL = regexOf("F2540_FAIL");
const CAPTURE = regexOf("F2540_CAPTURE");
const SHORT_NAMES = new Set(["git", "gh", "bash", "node"]);

function shorten(token) {
  const text = String(token);
  if (!/[\\/]/.test(text)) return text;
  const name = path.basename(text).replace(/\.(exe|cmd|bat)$/i, "").toLowerCase();
  return SHORT_NAMES.has(name) ? name : text;
}
function commandLine(fnName, args) {
  if (fnName === "execSync") return String(args[0]);
  const argv = Array.isArray(args[1]) ? args[1] : [];
  return [args[0]].concat(argv).map(shorten).join(" ");
}
function optionsOf(fnName, args) {
  const found = fnName === "execSync" ? args[1] : (Array.isArray(args[1]) ? args[2] : args[1]);
  return found && typeof found === "object" ? found : {};
}
function log(entry) {
  if (!process.env.F2540_LOG) return;
  try { fs.appendFileSync(process.env.F2540_LOG, JSON.stringify(entry) + "\n"); } catch (_e) { /* best effort */ }
}
function spawnFailure() {
  return Object.assign(new Error("spawn ENOENT (F2540_FAIL)"), { code: "ENOENT" });
}
function modeOf(line) {
  if (FAIL && FAIL.test(line)) return "fail";
  if (SLOW && SLOW.test(line)) return "slow";
  if (CAPTURE && CAPTURE.test(line)) return "capture";
  return "real";
}

const original = {};
for (const fnName of ["spawnSync", "execSync", "execFileSync"]) {
  original[fnName] = childProcess[fnName];
  childProcess[fnName] = function controlled(...args) {
    const line = commandLine(fnName, args);
    const options = optionsOf(fnName, args);
    const mode = modeOf(line);
    log({ fn: fnName, line, mode, timeout: options.timeout });
    if (mode === "real") return original[fnName].apply(this, args);
    if (mode === "fail") {
      if (fnName === "spawnSync") return { pid: 0, status: null, signal: null, output: null, stdout: null, stderr: null, error: spawnFailure() };
      throw spawnFailure();
    }
    if (mode === "capture") {
      // Under the armed limit file-stdio hands stdin over as a file descriptor instead of `input`.
      const stdin = Array.isArray(options.stdio) ? options.stdio[0] : undefined;
      if (options.input !== undefined) fs.writeFileSync(process.env.F2540_CAPTURE_FILE, options.input);
      else if (typeof stdin === "number") fs.writeFileSync(process.env.F2540_CAPTURE_FILE, fs.readFileSync(stdin));
      const empty = options.encoding && options.encoding !== "buffer" ? "" : Buffer.alloc(0);
      if (fnName === "spawnSync") return { pid: 0, status: 0, signal: null, output: [null, empty, empty], stdout: empty, stderr: empty, error: undefined };
      return empty;
    }
    // Pipes only, so no sleeper outlives the hook while holding the test's stderr open. No shell
    // (file-stdio's execSync passes shell: true): the timeout must kill the sleeper itself.
    const sleepOptions = Object.assign({}, options, { stdio: ["pipe", "pipe", "pipe"], shell: false });
    delete sleepOptions.input;
    if (fnName === "execSync") return original.execSync(`"${process.execPath}" -e "${SLEEP_SCRIPT}"`, Object.assign(sleepOptions, { shell: undefined }));
    return original[fnName](process.execPath, ["-e", SLEEP_SCRIPT], sleepOptions);
  };
}
