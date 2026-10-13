"use strict";
// tests/fixtures/spawn-record-preload.js — `node -r` preload: records every child_process call
// (spawn, spawnSync, exec, execSync, execFile, execFileSync, fork), one record per outermost call.
// Read from the environment of the process it is loaded into, at call time:
//   SPAWN_RECORD_OUT   JSONL file, one line per call (required)
//   SPAWN_RECORD_MODE  run-real (default): record, then run the child; record-only: run nothing
//   SPAWN_RECORD_HOLD  comma-separated substrings of "<command> <args...>"; a match is held
//   SPAWN_RECORD_TAG   free label copied into each record
//   SPAWN_RECORD_ALLOW comma-separated command names; when set, any other command is held too
//   SPAWN_RECORD_EXPECT_COUNT  when set, this process exits non-zero unless it recorded that many
// A held call never starts: sync calls get an empty success, async calls a child that exits 0.

const fs = require("fs");
const childProcess = require("child_process");
const { baseName, effectiveCommands } = require("./spawn-record-preload/command-words");
const { emptyOutput, spawnSyncResult, fakeChild } = require("./spawn-record-preload/held-results");

// A network-reaching call is never run: these commands, these git verbs, and git remote/submodule update.
const NETWORK_COMMANDS = ["gh", "glab", "codex", "docker", "uv", "curl", "wget", "ssh", "scp"];
const NETWORK_GIT_VERBS = ["push", "fetch", "pull", "clone", "ls-remote"];
const NETWORK_GIT_SUBVERBS = { remote: ["update"], submodule: ["update"] };
const GIT_OPTIONS_WITH_VALUE = ["-C", "-c", "--git-dir", "--work-tree", "--namespace"];
const SECRET_NAME_RE = /TOKEN|SECRET|PASSWORD|CREDENTIAL|AUTH|_KEY$/i;
const REDACTED = "<redacted>";
const FAMILY = ["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"];
const SYNC = ["spawnSync", "execSync", "execFileSync"];

if (!process.env.SPAWN_RECORD_OUT) {
  throw new Error("spawn-record-preload: SPAWN_RECORD_OUT is required");
}

// The git subcommand and the first plain word after it (options of the subcommand skipped).
function gitVerbs(args) {
  for (let i = 0; i < args.length; i += 1) {
    if (GIT_OPTIONS_WITH_VALUE.includes(args[i])) {
      i += 1;
    } else if (!args[i].startsWith("-")) {
      const sub = args.slice(i + 1).find((a) => !a.startsWith("-"));
      return { verb: args[i], sub: sub === undefined ? null : sub };
    }
  }
  return { verb: null, sub: null };
}

function reachesNetwork({ cmd, args }) {
  if (NETWORK_COMMANDS.includes(cmd)) return true;
  if (cmd !== "git") return false;
  const { verb, sub } = gitVerbs(args);
  if (NETWORK_GIT_VERBS.includes(verb)) return true;
  return Object.prototype.hasOwnProperty.call(NETWORK_GIT_SUBVERBS, verb) && NETWORK_GIT_SUBVERBS[verb].includes(sub);
}

function outsideAllowList({ cmd }) {
  const allow = String(process.env.SPAWN_RECORD_ALLOW || "")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter((s) => s !== "");
  return allow.length > 0 && !allow.includes(cmd);
}

function heldByRequest(command, args) {
  const line = [String(command)].concat(args).join(" ");
  return String(process.env.SPAWN_RECORD_HOLD || "")
    .split(",")
    .filter((s) => s !== "")
    .some((s) => line.includes(s));
}

function recordedEnv(env) {
  const out = {};
  for (const name of Object.keys(env)) {
    out[name] = SECRET_NAME_RE.test(name) ? REDACTED : String(env[name]);
  }
  return out;
}

// { file, args, options, callback, shell } for one call of <fn>.
function callShape(fn, a) {
  const callback = Array.prototype.slice.call(a, 1).find((x) => typeof x === "function");
  const isObj = (x) => x !== null && typeof x === "object" && !Array.isArray(x);
  if (fn === "exec" || fn === "execSync") {
    return { file: String(a[0]), args: [], options: isObj(a[1]) ? a[1] : undefined, callback, shell: true };
  }
  const hasArgs = Array.isArray(a[1]);
  const args = hasArgs ? a[1].map(String) : [];
  const rest = hasArgs || a[1] == null ? a[2] : a[1];
  const options = isObj(rest) ? rest : undefined;
  if (fn === "fork") return { file: process.execPath, args: [String(a[0])].concat(args), options, callback, shell: false };
  return { file: String(a[0]), args, options, callback, shell: Boolean(options && options.shell) };
}

let depth = 0;
let recorded = 0;

function wrap(fn) {
  const real = childProcess[fn];
  return function recordedCall(...a) {
    if (depth > 0) return real.apply(this, a);
    const shape = callShape(fn, a);
    const mode = process.env.SPAWN_RECORD_MODE === "record-only" ? "record-only" : "run-real";
    const words = effectiveCommands(shape.file, shape.args, shape.shell);
    const commands = words.length > 0 ? words : [{ cmd: baseName(shape.file), args: shape.args }];
    const trigger = commands.find((c) => reachesNetwork(c) || outsideAllowList(c));
    const held = mode === "record-only" || trigger !== undefined || heldByRequest(shape.file, shape.args);
    const options = shape.options;
    const envExplicit = Boolean(options && options.env && typeof options.env === "object");
    const record = {
      mode,
      held,
      tag: process.env.SPAWN_RECORD_TAG || null,
      fn,
      cmd: (trigger || commands[0]).cmd,
      command: shape.file,
      args: shape.args,
      cwd: options && typeof options.cwd === "string" ? options.cwd : null,
      envExplicit,
      env: envExplicit ? recordedEnv(options.env) : null,
    };
    fs.appendFileSync(process.env.SPAWN_RECORD_OUT, `${JSON.stringify(record)}\n`);
    recorded += 1;
    if (held) {
      if (fn === "spawnSync") return spawnSyncResult(options);
      if (SYNC.includes(fn)) return emptyOutput(options);
      return fakeChild(shape.callback, options);
    }
    depth += 1;
    try {
      return real.apply(this, a);
    } finally {
      depth -= 1;
    }
  };
}

for (const fn of FAMILY) childProcess[fn] = wrap(fn);

if (process.env.SPAWN_RECORD_EXPECT_COUNT !== undefined) {
  const want = Number(process.env.SPAWN_RECORD_EXPECT_COUNT);
  process.on("exit", () => {
    if (recorded === want) return;
    process.stderr.write(`spawn-record-preload: SPAWN_RECORD_EXPECT_COUNT=${process.env.SPAWN_RECORD_EXPECT_COUNT} but this process recorded ${recorded} call(s)\n`);
    if (!process.exitCode) process.exitCode = 1;
  });
}
