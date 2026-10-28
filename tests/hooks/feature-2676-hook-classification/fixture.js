"use strict";
// Fixtures for the heavy-hook cases of tests/hooks/feature-2676-hook-classification.js (and its
// oracle.js): throwaway repos (core.hooksPath=/dev/null through harness gitInit), a fake gh script,
// and runHook(), which starts one hook under child-control-preload.js and reads back its decision
// and call log.

const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { gitInit } = require("../../lib/harness");

const REPO = path.resolve(__dirname, "..", "..", "..");
const PRELOAD = path.join(__dirname, "child-control-preload.js");
// The longest a hook may run here. Without the limit a slowed hook waits for its own child
// timeouts (2-5 s) or is killed at this cap; either way the case stays bounded.
const WAIT_CAP_MS = 9000;

const forward = (dir) => dir.replace(/\\/g, "/");
const created = [];
// cleanup() removes every directory tempDir() made. Best effort: on Windows a sleeper child of a
// hook killed at the wait cap can still hold its cwd for a few seconds.
function cleanup() {
  for (const dir of created.splice(0)) {
    try { fs.rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 500 }); } catch (_e) { /* left in the OS temp dir */ }
  }
}
function git(dir, args) {
  const done = childProcess.spawnSync("git", ["-C", dir].concat(args), { encoding: "utf8" });
  if (done.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${done.stderr || done.error}`);
  return done.stdout;
}
function tempDir(label) {
  const dir = forward(fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `f2540-${label}-`))));
  created.push(dir);
  return dir;
}
// makeRepo(label, files) -> repo dir with one commit on main and `files` ({ rel: content }) staged.
function makeRepo(label, files = {}) {
  const dir = tempDir(label);
  gitInit(dir);
  git(dir, ["config", "user.email", "fixture@example.com"]);
  git(dir, ["config", "user.name", "Fixture"]);
  git(dir, ["checkout", "-q", "-b", "main"]);
  fs.writeFileSync(path.join(dir, "README.txt"), "fixture\n");
  git(dir, ["add", "README.txt"]);
  git(dir, ["commit", "-q", "-m", "init"]);
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), content);
  }
  if (Object.keys(files).length > 0) git(dir, ["add", "--", "."]);
  return dir;
}
// makeLinkedWorktree(repo) -> a linked worktree of repo on a non-protected branch.
function makeLinkedWorktree(repo) {
  const dir = `${tempDir("wt")}/linked`;
  git(repo, ["worktree", "add", "-q", "-b", "feature/example", dir]);
  return dir;
}
// fakeGhDir() -> a directory holding a `gh` node script that prints nothing and exits 1. On Windows
// it also holds gh.exe, a node copy that fake-gh-preload.js turns into the same fake: a shell-less
// spawn skips the script and would reach the real gh behind it.
const FAKE_GH_PRELOAD = forward(path.join(__dirname, "fake-gh-preload.js"));
function fakeGhDir() {
  const dir = tempDir("gh");
  fs.writeFileSync(path.join(dir, "gh"), "#!/usr/bin/env node\nprocess.exit(1);\n");
  if (process.platform === "win32") {
    const exe = path.join(dir, "gh.exe");
    try { fs.linkSync(process.execPath, exe); } catch (_e) { fs.copyFileSync(process.execPath, exe); }
  }
  return dir;
}
// fakeGhEnv(env) -> env overrides that put the fake gh first on PATH and load its preload.
function fakeGhEnv(env = {}) {
  return { PATH: `${fakeGhDir()}${path.delimiter}${process.env.PATH}`, NODE_OPTIONS: `--require "${FAKE_GH_PRELOAD}"`, ...env };
}

// runHook(hookName, stdin, { env, cwd, launch }) -> { status, signal, stdout, stderr, decision,
// reason, calls, elapsedMs }. env adds F2540_* and other variables to an isolated copy of
// process.env. launch ([file, args]) replaces the default `node --require PRELOAD hooks/<hook>.js`
// (registration.js passes the settings.json command line through bash).
function runHook(hookName, stdin, { env = {}, cwd, launch } = {}) {
  const work = tempDir("run");
  const logFile = path.join(work, "calls.jsonl");
  // Windows names are case-insensitive ("Path"): drop every spelling an override replaces.
  const overridden = new Set(Object.keys(env).map((name) => name.toUpperCase()));
  const inherited = Object.entries(process.env).filter(([name]) => !overridden.has(name.toUpperCase()));
  // AGENTS_STATE_DIR keeps the armed hook's decision-timing log out of the real ~/.agents/logs.
  const childEnv = { ...Object.fromEntries(inherited), F2540_LOG: logFile, AGENTS_STATE_DIR: path.join(work, "agents-state"), ...env };
  delete childEnv.CLAUDE_CODE_SESSION_ID;
  delete childEnv.CLAUDECODE;
  delete childEnv.CLAUDE_PROJECT_DIR;
  if (env.CLAUDE_PROJECT_DIR) childEnv.CLAUDE_PROJECT_DIR = env.CLAUDE_PROJECT_DIR;
  childEnv.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(work, "transcripts");
  fs.mkdirSync(childEnv.CLAUDE_TRANSCRIPT_BASE_DIR);
  const started = Date.now();
  const [file, args] = launch || [process.execPath, ["--require", PRELOAD, path.join(REPO, "hooks", `${hookName}.js`)]];
  const done = childProcess.spawnSync(file, args, {
    input: typeof stdin === "string" ? stdin : JSON.stringify(stdin),
    env: childEnv, cwd: cwd || work, encoding: "utf8", timeout: WAIT_CAP_MS,
  });
  const calls = fs.existsSync(logFile)
    ? fs.readFileSync(logFile, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line)) : [];
  return { ...done, ...decisionOf(done.stdout), calls, elapsedMs: Date.now() - started };
}

// decisionOf(stdout) -> { decision, reason }: "ask" | "allow" | "deny" from hookSpecificOutput,
// "block" | "approve" from the legacy shape, "none" for {} or no output, "unparsed" otherwise.
function decisionOf(stdout) {
  const text = String(stdout || "").trim();
  if (!text) return { decision: "none", reason: "" };
  let parsed = null;
  try { parsed = JSON.parse(text.split("\n").filter(Boolean).pop()); } catch (_e) { return { decision: "unparsed", reason: text }; }
  const specific = parsed && parsed.hookSpecificOutput;
  if (specific && specific.permissionDecision) {
    return { decision: specific.permissionDecision, reason: String(specific.permissionDecisionReason || "") };
  }
  if (parsed && parsed.decision) return { decision: parsed.decision, reason: String(parsed.reason || "") };
  return { decision: "none", reason: "" };
}

module.exports = { WAIT_CAP_MS, cleanup, git, makeRepo, makeLinkedWorktree, fakeGhDir, fakeGhEnv, runHook, tempDir };
