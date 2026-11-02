"use strict";
// Test-only scaffolding for tests/bin/feature-2820-retired-tokens.js. Holds no cases of its own.
// Builds fixture repos inside one temp root and runs the PR's checker on them in both modes,
// so every case reads the --staged and the --all verdict side by side.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { gitInit } = require("../../lib/harness");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const CHECKER = path.join(ROOT, "bin", "lib", "check-migration-blocks.js");
const REG_REL = "bin/lib/check-migration-blocks/retired-tokens.txt";
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2820-retired-"));
const TODAY = new Date().toISOString().slice(0, 10);

// The demo migration every fixture registry declares; the real stage-to-step registry
// knows none of these tokens, so a fall-through to it never turns a demo case green.
const DEMO_ID = "demo-tok";
const DEMO_DESC = "demo old -> demo new migration";
const REAL_DESC = "workflow stage -> workflow step migration";

let seq = 0;

function registry(lines) {
  return ["# retired-tokens:begin", ...lines, "# retired-tokens:end", ""].join("\n");
}

function demoRegistry(extra = []) {
  return registry([
    `# migration ${DEMO_ID} ${DEMO_DESC}`,
    `# scope ${DEMO_ID} hooks/**`,
    `# scope ${DEMO_ID} bin/**`,
    `# scope ${DEMO_ID} rules/**`,
    `# word ${DEMO_ID} OLD_TOKEN`,
    `# re ${DEMO_ID} \\bold_call\\(`,
    ...extra,
  ]);
}

// block(body, opts) — a `//` temporary block; added / cond false drops that field.
function block(body, { desc = DEMO_DESC, added = true, cond = true } = {}) {
  const begin = `// --- BEGIN temporary: ${desc}${added ? ` added ${TODAY}` : ""} ---`;
  return [begin, ...(cond ? ["// deletion-condition: remove once no caller remains"] : []), ...body, `// --- END temporary: ${desc} ---`, ""].join("\n");
}

function git(dir, args) {
  const done = spawnSync("git", ["-C", dir, ...args], { encoding: "utf8", timeout: 30000 });
  if (done.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${done.stderr || done.error}`);
  return done.stdout;
}

// makeRepo(files, { registry }) — files is { rel: content }; registry text lands at REG_REL,
// null leaves the repo without one. Everything is staged.
function makeRepo(files, { registry: reg = demoRegistry() } = {}) {
  const dir = path.join(TMP, `r${++seq}`);
  fs.mkdirSync(dir, { recursive: true });
  gitInit(dir);
  const all = reg === null ? files : { ...files, [REG_REL]: reg };
  for (const [rel, content] of Object.entries(all)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), content);
  }
  git(dir, ["add", "-A"]);
  return dir;
}

function childEnv() {
  const env = { ...process.env };
  delete env.CLAUDE_CODE_SESSION_ID;
  return env;
}

function run(argv, cwd) {
  const done = spawnSync(process.execPath, [CHECKER, ...argv], { cwd, env: childEnv(), encoding: "utf8", timeout: 60000 });
  return { rc: done.status, stdout: done.stdout || "", stderr: done.stderr || "", error: done.error };
}

// extra goes before the mode so the flag never mixes with the --staged file list.
function runAll(dir, extra = []) {
  return run([...extra, "--all", dir], TMP);
}

function runStaged(dir, extra = []) {
  const files = git(dir, ["ls-files"]).split("\n").filter(Boolean);
  return run([...extra, "--staged", ...files], dir);
}

function both(dir, extra = []) {
  return { staged: runStaged(dir, extra), all: runAll(dir, extra) };
}

function show(r) {
  return `rc=${r.rc} stdout=${JSON.stringify(r.stdout)} stderr=${JSON.stringify(r.stderr)}`;
}

function writeOutside(name, content) {
  const file = path.join(TMP, name);
  fs.writeFileSync(file, content);
  return file;
}

function finish() {
  fs.rmSync(TMP, { recursive: true, force: true });
}

module.exports = { ROOT, CHECKER, REG_REL, TODAY, DEMO_ID, DEMO_DESC, REAL_DESC, registry, demoRegistry, block, git, makeRepo, runAll, runStaged, both, show, writeOutside, finish };
