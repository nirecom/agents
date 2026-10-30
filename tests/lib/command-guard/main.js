"use strict";
// tests/lib/command-guard/main.js — the command guard's decision (#2590).
// Usage: node main.js <guard dir> <tool> <args...>   (from bin/<tool> or the Windows launcher)
// gh / glab / codex: record a hit and exit 97, always. git: a network URL is refused, a read runs
// the real git, and a write runs it only when every target sits inside the run root. An ssh URL
// served by the guard.conf `sshstub=` stub is not a network URL (ssh-stub.js).
// Settings come from <guard dir>/guard.conf, never from the environment the test controls.

const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");
const { GUARD_EXIT, NETWORK_TOOLS, splitGlobals, isRead } = require("./classify");
const { toNative, realish, makeGit, networkCheck, checkWrite, effectiveCwd } = require("./resolve-target");
const { recordHit } = require("./record-hit");
const { stubTrust } = require("./ssh-stub");

function readConf(guardDir) {
  const conf = { allowed: [] };
  for (const raw of fs.readFileSync(path.join(guardDir, "guard.conf"), "utf8").split(/\r?\n/)) {
    const eq = raw.indexOf("=");
    if (eq <= 0) continue;
    const key = raw.slice(0, eq);
    const value = raw.slice(eq + 1);
    if (key === "allowed") conf.allowed.push(value);
    else if (!(key in conf)) conf[key] = value;
  }
  return conf;
}

// The git child gets back the NODE_OPTIONS the bin script or launcher held away from this node.
function childEnv() {
  const env = { ...process.env };
  if (env._CG_NODE_OPTIONS_SET === "1") env.NODE_OPTIONS = env._CG_NODE_OPTIONS || "";
  delete env._CG_NODE_OPTIONS_SET;
  delete env._CG_NODE_OPTIONS;
  return env;
}

function runReal(realgit, args) {
  const child = spawn(realgit, args, { stdio: "inherit", env: childEnv(), windowsHide: true });
  const forward = (sig) => {
    try {
      child.kill(sig);
    } catch (_) {}
  };
  const signals = process.platform === "win32" ? [] : ["SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"];
  for (const s of signals) process.on(s, () => forward(s));
  child.on("error", (err) => {
    process.stderr.write(`command guard: cannot run the real git ${realgit}: ${err.message}\n`);
    process.exit(127);
  });
  child.on("exit", (code, sig) => {
    if (sig) {
      for (const s of signals) process.removeAllListeners(s);
      process.kill(process.pid, sig);
      return;
    }
    process.exit(code === null ? 1 : code);
  });
}

function refuse(guardDir, tool, target, args, reason) {
  recordHit(guardDir, tool, target, args, reason);
  process.exit(GUARD_EXIT);
}

function main(argv) {
  const [guardDirArg, tool, ...args] = argv;
  const guardDir = path.resolve(toNative(guardDirArg || "."));
  let conf;
  try {
    conf = readConf(guardDir);
  } catch (err) {
    return refuse(guardDir, tool || "?", process.cwd(), args, `guard.conf unreadable: ${err.code || err.message}`);
  }
  if (tool !== "git") return refuse(guardDir, tool, process.cwd(), args, NETWORK_TOOLS.includes(tool) ? "network CLI" : "unknown tool");
  if (!conf.realgit) return refuse(guardDir, tool, process.cwd(), args, "guard.conf has no realgit");
  const split = splitGlobals(args);
  const ctx = {
    verb: split.verb,
    rest: split.rest,
    gitDir: split.gitDir,
    cwd: effectiveCwd(split.cDirs),
    env: process.env,
    git: makeGit(conf.realgit, split.globals),
    allowed: conf.allowed.map((a) => realish(a)),
  };
  ctx.trustedUrl = stubTrust(conf.sshstub, ctx.env, ctx.git);
  const url = networkCheck(ctx);
  if (url) return refuse(guardDir, tool, url, args, "network URL");
  if (!isRead(split.verb, split.rest)) {
    const verdict = checkWrite(ctx);
    if (verdict.reject) return refuse(guardDir, tool, verdict.target, args, verdict.reject);
  }
  return runReal(conf.realgit, args);
}

main(process.argv.slice(2));
