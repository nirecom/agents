"use strict";
// Fixtures for tests/hooks/feature-2676-merged-allow-deny.js: the pre-merge registration facts
// (the test oracle, copied from settings.json before the merge), a hook-process driver, the
// output classifier, and the fault-injection preloads.
// The entry calls isolate() before requiring this module, so every spawned hook inherits the
// pinned WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR and has no CLAUDE_CODE_SESSION_ID.

const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const REPO = path.resolve(__dirname, "..", "..", "..");
const HOOKS = path.join(REPO, "hooks");
const MERGED = path.join(HOOKS, "merged-allow-deny.js");

// Pre-merge matchers of the five allow-deny hooks (settings.json before #2676). Hardcoded on
// purpose: after the merge the registrations are gone, and members.js must not be its own oracle.
const DOTENV_SET = ["Bash", "Read", "Grep", "Glob", "Edit", "Write", "MultiEdit", "editFiles",
  "runInTerminal", "runCommands", "mcp__codegraph__codegraph_explore"];
const MEMBERS = Object.freeze([
  { name: "block-dotenv", tools: DOTENV_SET },
  { name: "block-credentials", tools: DOTENV_SET },
  { name: "bash-guard", tools: ["Bash"] },
  { name: "block-capture-echo", tools: ["Bash", "runInTerminal", "runCommands"] },
  { name: "preuse-auto-approve", tools: ["Monitor", "EnterWorktree", "Bash", "runInTerminal", "runCommands"] },
]);
const GROUPS = Object.freeze({ primary: DOTENV_SET, "monitor-worktree": ["Monitor", "EnterWorktree"] });
// Pre-merge failure results, read off each standalone hook today ("silent" = no output at all).
const FAILURE = Object.freeze({
  "read-error": { "block-dotenv": "deny", "block-credentials": "deny", "bash-guard": "deny",
    "block-capture-echo": "none", "preuse-auto-approve": "none" },
  "json-invalid": { "block-dotenv": "approve", "block-credentials": "approve", "bash-guard": "silent",
    "block-capture-echo": "none", "preuse-auto-approve": "none" },
});

const RANK = Object.freeze({ none: 0, silent: 0, approve: 1, allow: 2, ask: 3, deny: 4 });
const mergeClasses = (classes) => classes.reduce((best, cls) => (RANK[cls] > RANK[best] ? cls : best), "none");
const membersFor = (tool) => MEMBERS.filter((member) => member.tools.includes(tool)).map((member) => member.name);
const groupOf = (tool) => Object.keys(GROUPS).find((group) => GROUPS[group].includes(tool));

// The decision a hook's stdout carries: deny / ask / allow / approve / none, or silent for none
// that printed nothing.
function classify(stdout) {
  const text = String(stdout || "").trim();
  if (text === "") return "silent";
  let out;
  try { out = JSON.parse(text); } catch (_e) { return `not-json:${text.slice(0, 60)}`; }
  const permission = out.hookSpecificOutput && out.hookSpecificOutput.permissionDecision;
  if (out.decision === "block" || permission === "deny") return "deny";
  if (permission === "ask") return "ask";
  if (permission === "allow") return "allow";
  if (out.decision === "approve") return "approve";
  return "none";
}
const parseOut = (stdout) => { try { return JSON.parse(String(stdout).trim()); } catch (_e) { return null; } };

function makeFixture(tag) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `${tag}-`));
  const work = path.join(root, "work");
  const wtBase = path.join(root, "wtbase");
  // The scratchpad allow needs a root under <tmp>/claude, outside any repo.
  fs.mkdirSync(path.join(os.tmpdir(), "claude"), { recursive: true });
  const scratchRoot = fs.mkdtempSync(path.join(os.tmpdir(), "claude", `${tag}-`));
  const scratchpad = path.join(scratchRoot, "scratchpad");
  for (const dir of [work, path.join(wtBase, "w1"), path.join(root, "transcripts"), scratchpad]) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(path.join(scratchpad, "a.sh"), "echo fixture\n");
  const env = { ...process.env, CLAUDE_TRANSCRIPT_BASE_DIR: path.join(root, "transcripts"),
    SCRATCHPAD: scratchpad, WORKTREE_BASE_DIR: wtBase };
  for (const name of ["CLAUDE_CODE_SESSION_ID", "CLAUDECODE", "NODE_OPTIONS", "AUTO_APPROVE_TOOLS"]) delete env[name];
  const cleanup = () => {
    for (const dir of [root, scratchRoot]) {
      try { fs.rmSync(dir, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
    }
  };
  return { root, work, wtBase, scratchpad, env, cleanup };
}

// runHook(fx, script, args, stdinText, {env, readError}) -> {status, stdout, stderr}.
// readError hands the child a write-only fd as stdin, so its read fails with EBADF
// (the same fault as `0>file` in tests/hooks/stdin-read-failure-policy.sh).
function runHook(fx, script, args, stdinText, opts = {}) {
  const env = { ...fx.env, ...(opts.env || {}) };
  const base = { env, cwd: fx.work, encoding: "utf8", timeout: 60000 };
  if (opts.readError) {
    const sink = path.join(fx.root, `fd0-sink-${process.hrtime.bigint()}.txt`);
    const fd = fs.openSync(sink, "w");
    try {
      return spawnSync(process.execPath, [script, ...args], { ...base, stdio: [fd, "pipe", "pipe"] });
    } finally {
      fs.closeSync(fd);
    }
  }
  return spawnSync(process.execPath, [script, ...args], { ...base, input: stdinText });
}

const standalone = (fx, member, input, opts) =>
  runHook(fx, path.join(HOOKS, `${member}.js`), [], JSON.stringify(input), opts);
const merged = (fx, group, input, opts) =>
  runHook(fx, MERGED, ["--matcher-group", group], typeof input === "string" ? input : JSON.stringify(input), opts);

// preload(fx, name, body) writes a --require preload and returns the env that loads it.
function preload(fx, name, body) {
  const file = path.join(fx.root, `${name}.js`);
  fs.writeFileSync(file, `"use strict";\n${body}\n`);
  return { NODE_OPTIONS: `--require "${file.replace(/\\/g, "/")}"` };
}
// patchJudge(rel, exportName, fnSource) -> preload body that swaps one judge export, inert when
// the module is absent.
const patchJudge = (rel, exportName, fnSource) =>
  `try { const m = require(${JSON.stringify(path.join(HOOKS, rel).replace(/\\/g, "/"))}); ` +
  `m[${JSON.stringify(exportName)}] = ${fnSource}; } catch (_e) { /* module absent */ }`;

// readMembersModule() -> { groups: {name: sorted tools}, members: {name: sorted tools} } read from
// hooks/merged-allow-deny/members.js. The export names are not fixed by the plan, so this looks
// for the group table (an object keyed by every GROUPS name) and the member table (an array of
// objects with a name and a tool set) among the module's exports.
const toolList = (value) => {
  const raw = value && !Array.isArray(value) && !(value instanceof Set) && typeof value === "object"
    ? (value.tools || value.toolNames || value.matcher) : value;
  if (typeof raw === "string") return raw.split("|").sort();
  return raw ? [...raw].map(String).sort() : null;
};
function readMembersModule() {
  const mod = require(path.join(HOOKS, "merged-allow-deny", "members.js"));
  const exportsList = Object.values(mod);
  const groupTable = exportsList.find((value) => value && typeof value === "object" && !Array.isArray(value)
    && Object.keys(GROUPS).every((name) => name in value));
  const memberTable = exportsList.find((value) => Array.isArray(value) && value.length > 0
    && value.every((entry) => entry && typeof entry.name === "string"));
  return {
    groups: groupTable ? Object.fromEntries(Object.keys(groupTable).map((name) => [name, toolList(groupTable[name])])) : null,
    members: memberTable ? Object.fromEntries(memberTable.map((entry) => [entry.name, toolList(entry)])) : null,
  };
}

module.exports = {
  REPO, HOOKS, MERGED, MEMBERS, GROUPS, FAILURE, DOTENV_SET,
  RANK, mergeClasses, membersFor, groupOf, classify, parseOut,
  makeFixture, runHook, standalone, merged, preload, patchJudge, readMembersModule,
};
