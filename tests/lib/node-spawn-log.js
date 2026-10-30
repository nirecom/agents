"use strict";
// Records process starts of a Node process tree to a log, so a bash test can count them where a
// PATH shim cannot reach Node (Windows spawnSync never runs a bash shim). Two roles:
//   preload: NODE_OPTIONS=--require <this> with TEST_NODE_SPAWN_LOG=<log> appends one JSON line per
//     Node process start ("main") and per child_process call; NODE_OPTIONS reaches Node children.
//   CLI: node node-spawn-log.js count <log> <spawn|main|any> <regex> — prints how many records
//     match <regex> against "<cmd> <args...>" (backslashes read as slashes; a missing log is 0).
const fs = require("fs");

const FNS = ["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"];

function argList(rest) {
  return Array.isArray(rest[0]) ? rest[0].map(String) : [];
}

function install(log) {
  const cp = require("child_process");
  const write = (fn, cmd, args) => {
    try {
      fs.appendFileSync(log, `${JSON.stringify({ pid: process.pid, fn, cmd: String(cmd), args })}\n`);
    } catch {
      // A test that finds no record fails closed, so a write error needs no handling here.
    }
  };
  write("main", process.execPath, process.argv.slice(1));
  for (const fn of FNS) {
    const orig = cp[fn];
    cp[fn] = function logged(command, ...rest) {
      write(fn, fn === "fork" ? `${process.execPath} ${command}` : command, argList(rest));
      return orig.call(this, command, ...rest);
    };
  }
}

function count(log, kind, pattern) {
  let text = "";
  try {
    text = fs.readFileSync(log, "utf8");
  } catch {
    return 0;
  }
  const re = new RegExp(pattern);
  return text.split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((r) => {
    if (kind === "main" && r.fn !== "main") return false;
    if (kind === "spawn" && r.fn === "main") return false;
    return re.test([r.cmd, ...r.args].join(" ").replace(/\\/g, "/"));
  }).length;
}

if (require.main === module) {
  const [op, log, kind, pattern] = process.argv.slice(2);
  if (op !== "count" || !log || !["spawn", "main", "any"].includes(kind) || pattern === undefined) {
    process.stderr.write("usage: node-spawn-log.js count <log> <spawn|main|any> <regex>\n");
    process.exit(2);
  }
  process.stdout.write(`${count(log, kind, pattern)}\n`);
} else if (process.env.TEST_NODE_SPAWN_LOG) {
  install(process.env.TEST_NODE_SPAWN_LOG);
}
