"use strict";
// Fixtures for tests/hooks/feature-2940-protect-user-block.js: runHook() starts the real
// hooks/protect-user-block.js under cli-stub-preload.js (the CLI never runs; F2940_UBG_VERDICTS
// scripts its rc) and reads back the decision plus one record per CLI call.

const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const REPO = path.resolve(__dirname, "..", "..", "..");
const HOOK = path.join(REPO, "hooks", "protect-user-block.js");
const PRELOAD = path.join(__dirname, "cli-stub-preload.js");
const WAIT_CAP_MS = 20000;

const forward = (dir) => dir.replace(/\\/g, "/");
const created = [];
function cleanup() {
  for (const dir of created.splice(0)) {
    try { fs.rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch (_e) { /* OS temp */ }
  }
}
function tempDir(label) {
  const dir = forward(fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `f2940-${label}-`))));
  created.push(dir);
  return dir;
}
const hookPresent = () => fs.existsSync(HOOK);

// runHook(command, { verdicts, env, cwd, toolName, files }) -> { status, stdout, stderr, decision,
// reason, calls }. files ({ rel: content }) are written into the neutral cwd before the run.
function runHook(command, { verdicts = { default: 0 }, env = {}, cwd, toolName = "Bash", files = {} } = {}) {
  const work = tempDir("run");
  const dir = cwd || work;
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), content);
  }
  const logFile = path.join(work, "cli-calls.jsonl");
  const overridden = new Set(Object.keys(env).map((n) => n.toUpperCase()));
  const inherited = Object.entries(process.env).filter(([n]) => !overridden.has(n.toUpperCase()));
  const childEnv = {
    ...Object.fromEntries(inherited),
    AGENTS_STATE_DIR: path.join(work, "agents-state"),
    F2940_UBG_LOG: logFile,
    F2940_UBG_VERDICTS: JSON.stringify(verdicts),
    ...env,
  };
  for (const name of ["CLAUDE_CODE_SESSION_ID", "CLAUDECODE", "CLAUDE_PROJECT_DIR", "GH_REPO"]) {
    if (!Object.prototype.hasOwnProperty.call(env, name)) delete childEnv[name];
  }
  childEnv.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(work, "transcripts");
  fs.mkdirSync(childEnv.CLAUDE_TRANSCRIPT_BASE_DIR);
  const toolInput = toolName === "Bash" ? { command } : { file_path: command };
  const done = childProcess.spawnSync(process.execPath, ["--require", PRELOAD, HOOK], {
    input: JSON.stringify({ tool_name: toolName, tool_input: toolInput, cwd: dir }),
    env: childEnv, cwd: dir, encoding: "utf8", timeout: WAIT_CAP_MS,
  });
  const calls = fs.existsSync(logFile)
    ? fs.readFileSync(logFile, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
  return { ...done, ...decisionOf(done.stdout), calls, cwd: dir };
}

function decisionOf(stdout) {
  const text = String(stdout || "").trim();
  if (!text) return { decision: "none", reason: "" };
  let parsed = null;
  try { parsed = JSON.parse(text.split("\n").filter(Boolean).pop()); } catch (_e) { return { decision: "unparsed", reason: text }; }
  const specific = parsed && parsed.hookSpecificOutput;
  if (specific && specific.permissionDecision) {
    return { decision: specific.permissionDecision, reason: String(specific.permissionDecisionReason || "") };
  }
  return { decision: "none", reason: "" };
}

// flag(call, name) -> the value after the last `name` in the CLI argv (undefined when absent).
function flag(call, name) {
  const i = call.args.lastIndexOf(name);
  return i < 0 ? undefined : call.args[i + 1];
}
const has = (call, name) => call.args.includes(name);

module.exports = { REPO, WAIT_CAP_MS, cleanup, tempDir, hookPresent, runHook, decisionOf, flag, has };
