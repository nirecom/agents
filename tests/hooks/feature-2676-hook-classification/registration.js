"use strict";
// Real-registration helpers for the heavy-hook cases of tests/hooks/feature-2676-hook-classification.js:
// the hook is launched by the very command string settings.json registers for it (through bash,
// with AGENTS_MAIN_ROOT expanded as Claude Code does), never by a path the test makes up.
//   registeredCommand(hookName)        -> { matcher, command, timeout } of its Bash PreToolUse entry
//   checkoutCopy(repo)                 -> a copy of this checkout's tracked hooks/ and bin/ that git
//                                         reports as a checkout of `repo` (the hook's "own repo")
//   runRegistered(hookName, stdin, { agentsRoot, env, cwd, warm }) -> the same shape as fixture.runHook
//   runIfPermitted(run, argv, cwd)     -> runs `git argv` only when the decision lets the tool run

const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const fx = require("./fixture");

const REPO = path.resolve(__dirname, "..", "..", "..");
const PRELOAD = path.join(__dirname, "child-control-preload.js").replace(/\\/g, "/");
const SETTINGS = path.join(REPO, "settings.json");
// Decisions after which Claude Code does not run the tool on its own: block / deny refuse it,
// ask waits for a person (a refusal under -p).
const HOLDING = new Set(["block", "deny", "ask"]);

function registeredCommand(hookName) {
  const settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
  const found = [];
  for (const group of (settings.hooks && settings.hooks.PreToolUse) || []) {
    if (!String(group.matcher || "").split("|").includes("Bash")) continue;
    for (const hook of group.hooks || []) {
      if (String(hook.command || "").includes(`/hooks/${hookName}.js`)) found.push({ matcher: group.matcher, command: hook.command, timeout: hook.timeout });
    }
  }
  if (found.length !== 1) throw new Error(`${hookName}: want exactly one Bash PreToolUse registration in settings.json, found ${found.length}`);
  return found[0];
}

function checkoutCopy(repo) {
  const copy = fx.tempDir("checkout");
  const listing = childProcess.execFileSync("git", ["-C", REPO, "ls-files", "-z", "--", "hooks", "bin"], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  for (const rel of listing.split("\0").filter(Boolean)) {
    const from = path.join(REPO, rel);
    if (!fs.existsSync(from) || !fs.statSync(from).isFile()) continue;
    const to = path.join(copy, rel);
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.copyFileSync(from, to);
  }
  const common = path.resolve(repo, fx.git(repo, ["rev-parse", "--git-common-dir"]).trim()).replace(/\\/g, "/");
  fs.writeFileSync(path.join(copy, ".git"), `gitdir: ${common}\n`);
  return copy;
}

// warm: the first launch from a freshly written checkoutCopy() pays a one-off load cost (measured
// ~0.7 s before the first child on Windows) inside the decision time limit; a discarded run first.
function runRegistered(hookName, stdin, { agentsRoot = REPO, env = {}, cwd, warm = false } = {}) {
  const { command } = registeredCommand(hookName);
  // The child-control preload rides NODE_OPTIONS, since the registered command line is used as is.
  const launch = () => fx.runHook(hookName, stdin, {
    cwd, launch: ["bash", ["-c", command]],
    env: { AGENTS_MAIN_ROOT: agentsRoot.replace(/\\/g, "/"), NODE_OPTIONS: `--require "${PRELOAD}"`, ...env },
  });
  if (warm) launch();
  return launch();
}

function commitCount(repo) {
  return Number(fx.git(repo, ["rev-list", "--count", "HEAD"]).trim());
}

function runIfPermitted(run, argv, cwd) {
  if (HOLDING.has(run.decision)) return { ran: false };
  fx.git(cwd, argv);
  return { ran: true };
}

module.exports = { registeredCommand, checkoutCopy, runRegistered, runIfPermitted, commitCount };
