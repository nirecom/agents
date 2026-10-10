"use strict";
// tests/fixtures/spawn-record-preload.js — `node -r` preload: records every child_process.spawnSync call.
// Read from the environment of the process it is loaded into, at call time:
//   SPAWN_RECORD_OUT   JSONL file, one line per call (required)
//   SPAWN_RECORD_MODE  run-real (default): record, then run the child
//                      record-only: record, run nothing, answer a fixed success
//   SPAWN_RECORD_HOLD  comma-separated substrings of "<command> <args...>"; a matching call is
//                      answered like record-only even in run-real mode
//   SPAWN_RECORD_TAG   free label copied into each record
//   SPAWN_RECORD_ALLOW comma-separated command names; when set, any other command is held too

const fs = require("fs");
const childProcess = require("child_process");

const realSpawnSync = childProcess.spawnSync;
// A network-reaching call is never run: these commands, these git verbs, and git remote/submodule update.
const NETWORK_COMMANDS = ["gh", "glab", "docker", "uv", "curl", "wget", "ssh", "scp"];
const NETWORK_GIT_VERBS = ["push", "fetch", "pull", "clone", "ls-remote"];
const NETWORK_GIT_SUBVERBS = { remote: ["update"], submodule: ["update"] };
const GIT_OPTIONS_WITH_VALUE = ["-C", "-c", "--git-dir", "--work-tree", "--namespace"];
const SECRET_NAME_RE = /TOKEN|SECRET|PASSWORD|CREDENTIAL|AUTH|_KEY$/i;
const REDACTED = "<redacted>";

if (!process.env.SPAWN_RECORD_OUT) {
  throw new Error("spawn-record-preload: SPAWN_RECORD_OUT is required");
}

function baseName(command) {
  return String(command).replace(/\\/g, "/").split("/").pop().replace(/\.exe$/i, "").toLowerCase();
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

function reachesNetwork(command, args) {
  const name = baseName(command);
  if (NETWORK_COMMANDS.includes(name)) return true;
  if (name !== "git") return false;
  const { verb, sub } = gitVerbs(args);
  if (NETWORK_GIT_VERBS.includes(verb)) return true;
  return Object.prototype.hasOwnProperty.call(NETWORK_GIT_SUBVERBS, verb) && NETWORK_GIT_SUBVERBS[verb].includes(sub);
}

function outsideAllowList(command) {
  const allow = String(process.env.SPAWN_RECORD_ALLOW || "")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter((s) => s !== "");
  return allow.length > 0 && !allow.includes(baseName(command));
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

function fixedSuccess(options) {
  const text = options && options.encoding && options.encoding !== "buffer";
  const empty = text ? "" : Buffer.alloc(0);
  return { pid: 0, output: [null, empty, empty], stdout: empty, stderr: empty, status: 0, signal: null };
}

childProcess.spawnSync = function recordedSpawnSync(command, argsOrOptions, maybeOptions) {
  const args = Array.isArray(argsOrOptions) ? argsOrOptions.map(String) : [];
  const options = Array.isArray(argsOrOptions) ? maybeOptions : argsOrOptions;
  const mode = process.env.SPAWN_RECORD_MODE === "record-only" ? "record-only" : "run-real";
  const held =
    mode === "record-only" || reachesNetwork(command, args) || outsideAllowList(command) || heldByRequest(command, args);
  const envExplicit = Boolean(options && options.env && typeof options.env === "object");

  fs.appendFileSync(
    process.env.SPAWN_RECORD_OUT,
    `${JSON.stringify({
      mode,
      held,
      tag: process.env.SPAWN_RECORD_TAG || null,
      command: String(command),
      args,
      cwd: options && typeof options.cwd === "string" ? options.cwd : null,
      envExplicit,
      env: envExplicit ? recordedEnv(options.env) : null,
    })}\n`,
  );

  if (held) return fixedSuccess(options);
  return realSpawnSync.call(childProcess, command, argsOrOptions, maybeOptions);
};
