"use strict";
// Shared test helpers; load with `require("../lib/harness")` at the top of a test file.
// caseBegin(name, target) / caseEnd() are written at column 0 around each case: the static
// reader takes the target from the source text, and this module checks the pairing at run time.
// The built-in test runner is loaded only inside xfail, so a plain script that requires this
// file is still settled by its own exit code.

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const PINNED = { WORKFLOW_STATE_DIR: "workflow-state", WORKFLOW_PLANS_DIR: "plans" };
const REMOVED = ["CLAUDE_CODE_SESSION_ID"];

let openCase = null;

process.on("exit", () => {
  if (openCase === null) return;
  process.stderr.write(`caseBegin("${openCase}") has no caseEnd()\n`);
  process.exitCode = 1;
});

// Rejects exactly the targets the static reader (bin/lib/test-language-parts/js-case-reader.js)
// rejects, so a case that runs is always a case the catalog can read; the checks before the last
// only name the reason.
function targetFault(target) {
  if (typeof target !== "string" || target === "") return "is empty";
  if (target.startsWith("/")) return "is absolute";
  if (/[:\\]/.test(target)) return "has a drive letter or backslash";
  const parts = target.split("/");
  if (parts.includes("..")) return "escapes the tree";
  if (parts[0] === ".") return "starts with ./";
  if (/[;$`|&><()]/.test(target)) return "has shell metacharacters";
  if (/\s/.test(target)) return "has whitespace";
  if (!/^[A-Za-z0-9._/-]+$/.test(target)) return "has a character outside A-Z a-z 0-9 . _ / -";
  return "";
}

function caseBegin(name, target) {
  if (typeof name !== "string" || name === "") throw new Error("caseBegin: name is empty");
  const fault = targetFault(target);
  if (fault) throw new Error(`caseBegin("${name}"): target-path ${fault}`);
  if (openCase !== null) throw new Error(`caseBegin("${name}") while "${openCase}" is still open`);
  openCase = name;
}

function caseEnd() {
  if (openCase === null) throw new Error("caseEnd() without caseBegin()");
  openCase = null;
}

// isolate() — re-points the workflow dirs into a fresh temp directory and removes the session
// variables; returns the function that puts every value back (calling it again does nothing).
function isolate() {
  const names = Object.keys(PINNED).concat(REMOVED);
  let saved = Object.fromEntries(names.map((n) => [n, process.env[n]]));
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "harness-"));
  for (const [name, leaf] of Object.entries(PINNED)) {
    fs.mkdirSync(path.join(root, leaf));
    process.env[name] = path.join(root, leaf);
  }
  for (const name of REMOVED) delete process.env[name];
  return () => {
    if (saved === null) return;
    for (const name of names) {
      if (saved[name] === undefined) delete process.env[name];
      else process.env[name] = saved[name];
    }
    saved = null;
    fs.rmSync(root, { recursive: true, force: true });
  };
}

// gitInit(dir) — a fixture repo where no installed hook fires and no ignore file of the
// developer applies.
function gitInit(dir) {
  const excludes = path.resolve(dir, ".git", "info", "exclude").replace(/\\/g, "/");
  for (const args of [
    ["init", "-q", dir],
    ["-C", dir, "config", "core.hooksPath", "/dev/null"],
    ["-C", dir, "config", "core.excludesFile", excludes],
  ]) {
    const done = spawnSync("git", args, { encoding: "utf8" });
    if (done.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${done.stderr || done.error}`);
  }
}

// xfail(name, fn) — a known failure: passes while fn throws or rejects, fails once it stops.
function xfail(name, fn) {
  require("node:test").test(name, async () => {
    try {
      await fn();
    } catch {
      return;
    }
    throw new Error(`XPASS: ${name} no longer fails; remove the xfail wrapper`);
  });
}

// tl3Enabled() — true only when RUN_TL3 is on; use as `{ skip: !tl3Enabled() }`. The process
// value wins; without one, bin/get-config-var answers. A lookup that fails reads as off.
function tl3Enabled() {
  let value = String(process.env.RUN_TL3 || "");
  if (value === "") {
    try {
      const reader = path.join(__dirname, "..", "..", "bin", "get-config-var").replace(/\\/g, "/");
      const done = spawnSync("bash", [reader, "RUN_TL3", "off"], { encoding: "utf8", timeout: 60000 });
      if (!done.error && done.status === 0) value = String(done.stdout || "").trim();
    } catch {
      value = "";
    }
  }
  return value.toLowerCase() === "on";
}

module.exports = { caseBegin, caseEnd, isolate, gitInit, xfail, tl3Enabled };
