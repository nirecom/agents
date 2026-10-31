"use strict";
// Tests: bin/check-test-frontmatter.sh
// Tags: TL1, TL2, bin, golden, fixture, test-lang-exception:symmetry, scope:issue-specific
// Fixture runner of the test-gates corpus (#2507 S4). Holds no case markers. Builds each corpus
// tree once in a temp git repo, runs a CLI there (the bin/ .sh path, or run() of the Node
// adapter in-process), and normalizes the result so the golden holds no host path.
// Assumed adapter contract: bin/check-<name>/cli.js exports run({ argv, cwd, env, stdout, stderr })
// -> rc (or a promise of it); stdout / stderr are { write(s) } sinks. Same shape as #2507 D7's
// bin/check-session-id-ssot/main.js.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { gitInit } = require("../../lib/harness");
const C = require("./content");
const FM = require("./corpus-frontmatter");
const GT = require("./corpus-gates");

const REPO = path.resolve(__dirname, "..", "..", "..");
const GOLDEN = path.join(__dirname, "golden", "cli.json");
const TREES = { ...FM.trees, ...GT.trees };
const RUNS = [...FM.runs, ...GT.runs];
const CLI = {
  frontmatter: "check-test-frontmatter",
  markers: "check-case-markers",
  langmatch: "check-test-language-match",
  selfimpl: "check-self-impl",
};
const fwd = (p) => p.replace(/\\/g, "/");
const IS_WIN = process.platform === "win32";

const built = new Map();
const roots = [];
function write(root, rel, text) {
  const abs = path.join(root, rel);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, text);
}
function git(cwd, ...args) {
  const r = spawnSync("git", ["-c", "user.name=t", "-c", "user.email=t@example.invalid", ...args], { cwd, encoding: "utf8", timeout: 60000 });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr || r.error}`);
}

// tree(id) — the built repo of one corpus tree: base files and head committed (no commit when
// head is null), index staged, work left unstaged.
function tree(id) {
  if (built.has(id)) return built.get(id);
  const t = TREES[id];
  if (!t) throw new Error(`unknown corpus tree ${id}`);
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `test-gates-2507-${id}-`));
  roots.push(root);
  gitInit(root);
  for (const [rel, text] of Object.entries({ ...C.BASE, ...(t.head || {}) })) write(root, rel, text);
  git(root, "add", "-A");
  if (t.head) git(root, "commit", "-q", "-m", "head");
  for (const [rel, text] of Object.entries(t.index)) write(root, rel, text);
  if (Object.keys(t.index).length) git(root, "add", "--", ...Object.keys(t.index));
  for (const [rel, text] of Object.entries(t.work)) write(root, rel, text);
  built.set(id, root);
  return root;
}
function cleanup() {
  for (const d of roots.splice(0)) fs.rmSync(d, { recursive: true, force: true });
  built.clear();
}

const PATH_KEY = Object.keys(process.env).find((k) => k.toUpperCase() === "PATH") || "PATH";
const exe = (dir, name) => [name, `${name}.exe`].some((n) => fs.existsSync(path.join(dir, n)));
// The bash that runs the CLIs: the first on PATH, past the WSL launchers of Windows.
function findBash() {
  for (const dir of String(process.env[PATH_KEY] || "").split(path.delimiter)) {
    if (/system32|windowsapps/i.test(dir) || !exe(dir, "bash")) continue;
    return path.join(dir, IS_WIN ? "bash.exe" : "bash");
  }
  return "bash";
}
const BASH = findBash();

// pathFor(kind) — the PATH of a run: full; noRuntime without the dirs holding pwsh / uv; noNode
// without the dirs holding node. null when a dropped dir also holds a tool the CLIs need, so the
// run cannot be made on this host.
const DROP = { full: [], noRuntime: ["pwsh", "uv"], noNode: ["node"] };
const NEEDED = ["bash", "awk", "grep", "git", "sed"];
function pathFor(kind) {
  const dirs = String(process.env[PATH_KEY] || "").split(path.delimiter);
  const keep = [];
  for (const dir of dirs) {
    if (DROP[kind].some((n) => exe(dir, n))) {
      if (NEEDED.some((n) => exe(dir, n))) return null;
      continue;
    }
    keep.push(dir);
  }
  return keep.join(path.delimiter);
}

function childEnv(kind) {
  const p = pathFor(kind);
  if (p === null) return null;
  const env = { ...process.env, LC_ALL: "C.UTF-8" };
  for (const k of Object.keys(env)) if (k.toUpperCase() === "PATH") delete env[k];
  env[PATH_KEY] = p;
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env["CLAUDE_" + "SESSION_ID"];
  delete env["CLAUDE_" + "ENV_FILE"];
  return env;
}

// The forms a host path takes in the output: native, forward-slash, and MSYS /c/... .
function forms(p) {
  const f = fwd(p);
  const out = [p, f];
  const m = /^([A-Za-z]):\/(.*)$/.exec(f);
  if (m) out.push(`/${m[1].toLowerCase()}/${m[2]}`, `/${m[1].toUpperCase()}/${m[2]}`);
  return [...new Set(out)].sort((a, b) => b.length - a.length);
}
function normalize(text, root) {
  let s = String(text || "").replace(/\r\n/g, "\n");
  for (const f of forms(root)) s = s.split(f).join("@ROOT@");
  for (const f of forms(REPO)) s = s.split(f).join("@REPO@");
  return s;
}

// bashRun(run) — the run through bin/<cli>.sh; { skipped } when its PATH cannot be made here.
function bashRun(run) {
  const env = childEnv(run.path);
  if (env === null) return { skipped: `${run.path} PATH cannot be built on this host` };
  const root = tree(run.tree);
  const script = fwd(path.join(REPO, "bin", `${CLI[run.cli]}.sh`));
  const r = spawnSync(BASH, [script, ...run.args], { cwd: root, env, encoding: "utf8", timeout: 120000 });
  if (r.error) throw new Error(`${run.id}: bash did not run: ${r.error}`);
  return { rc: r.status, stdout: normalize(r.stdout, root), stderr: normalize(r.stderr, root) };
}

// nodeRun(run) — the run through run() of bin/<cli>/cli.js in this process.
async function nodeRun(run) {
  const env = childEnv(run.path);
  if (env === null) return { skipped: `${run.path} PATH cannot be built on this host` };
  const root = tree(run.tree);
  const mod = require(path.join(REPO, "bin", CLI[run.cli], "cli.js"));
  if (typeof mod.run !== "function") throw new Error(`bin/${CLI[run.cli]}/cli.js exports no run()`);
  let stdout = "";
  let stderr = "";
  const rc = await mod.run({
    argv: run.args, cwd: root, env,
    stdout: { write: (s) => { stdout += String(s); return true; } },
    stderr: { write: (s) => { stderr += String(s); return true; } },
  });
  return { rc, stdout: normalize(stdout, root), stderr: normalize(stderr, root) };
}

const golden = () => JSON.parse(fs.readFileSync(GOLDEN, "utf8"));

module.exports = { REPO, GOLDEN, RUNS, TREES, CLI, BASH, tree, cleanup, bashRun, nodeRun, golden, childEnv, pathFor, normalize, write, git };
