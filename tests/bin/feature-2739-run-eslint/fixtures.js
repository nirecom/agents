"use strict";
// Tests: bin/run-eslint
// Tags: TL2, bin, eslint, lint, fixtures, fake-package, npm-stub, scope:issue-specific
// Fixtures for tests/bin/feature-2739-run-eslint.js, built at run time under one temp root
// (node_modules/ is gitignored, so a fake eslint package cannot live in the repo). Loading it
// isolates the workflow dirs and pins the temp dir and home of every wrapper run to that root.
const { gitInit, isolate } = require("../../lib/harness");

const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const REPO = path.join(__dirname, "..", "..", "..");
const WRAPPER = path.join(REPO, "bin", "run-eslint");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2739-run-eslint-"));
const SYS_TMP = path.join(TMP, "systmp");
const HOME_DIR = path.join(TMP, "home");
const NEUTRAL = path.join(TMP, "cwd");
const STUBS = path.join(TMP, "stubs");
const FAKE_ESLINT_SRC = path.join(STUBS, "fake-eslint");
for (const d of [SYS_TMP, HOME_DIR, NEUTRAL, FAKE_ESLINT_SRC]) fs.mkdirSync(d, { recursive: true });
process.on("exit", () => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

// The fake ESLint answers from FAKE_ESLINT_* variables and appends each call to FAKE_ESLINT_LOG.
const FAKE_ESLINT_INDEX = `"use strict";
const fs = require("fs");
const num = (k, d) => (process.env[k] ? Number(process.env[k]) : d);
const log = (e) => { if (process.env.FAKE_ESLINT_LOG) fs.appendFileSync(process.env.FAKE_ESLINT_LOG, JSON.stringify(e) + "\\n"); };
class ESLint {
  constructor(opts) {
    if (process.env.FAKE_ESLINT_THROW === "1") throw new Error("fake eslint: config load failed");
    this.opts = opts || {};
    log({ op: "new", cwd: this.opts.cwd, overrideConfigFile: this.opts.overrideConfigFile });
  }
  async isPathIgnored() { return process.env.FAKE_ESLINT_IGNORED === "1"; }
  async calculateConfigForFile() {
    if (process.env.FAKE_ESLINT_NO_CONFIG === "1") return undefined;
    const rules = { "fake-off-number": [0], "fake-off-word": ["off"] };
    for (let i = 0; i < num("FAKE_ESLINT_ACTIVE_RULES", 1); i++) rules["fake-on-" + i] = [2];
    return { languageOptions: { sourceType: "commonjs" }, rules };
  }
  async lintFiles(patterns) {
    const list = Array.isArray(patterns) ? patterns : [patterns];
    log({ op: "lintFiles", cwd: this.opts.cwd, patterns: list });
    return list.map((p, i) => ({ filePath: p, messages: [], suppressedMessages: [],
      errorCount: i === 0 ? num("FAKE_ESLINT_ERRORS", 0) : 0, fatalErrorCount: 0,
      warningCount: i === 0 ? num("FAKE_ESLINT_WARNINGS", 0) : 0, fixableErrorCount: 0, fixableWarningCount: 0 }));
  }
  async loadFormatter(name) {
    log({ op: "loadFormatter", name });
    return { format: (rs) => "FAKE-FORMAT " + name + " errors=" + rs.reduce((a, r) => a + r.errorCount, 0) + "\\n" };
  }
}
ESLint.version = "0.0.0-fake";
module.exports = { ESLint };
`;
fs.writeFileSync(path.join(FAKE_ESLINT_SRC, "package.json"), JSON.stringify({ name: "eslint", version: "0.0.0-fake", main: "index.js" }));
fs.writeFileSync(path.join(FAKE_ESLINT_SRC, "index.js"), FAKE_ESLINT_INDEX);

// npm stand-ins for RUN_ESLINT_NPM_CLI: both record the call in FAKE_NPM_MARKER; the ok one
// rebuilds node_modules with the fake eslint the way npm ci does, the failing one exits 1.
const NPM_OK = path.join(STUBS, "npm-ok.js");
const NPM_FAIL = path.join(STUBS, "npm-fail.js");
const RECORD = `const fs = require("fs"); const path = require("path");
fs.appendFileSync(process.env.FAKE_NPM_MARKER, JSON.stringify({ cwd: process.cwd(), argv: process.argv.slice(2) }) + "\\n");
`;
fs.writeFileSync(NPM_OK, `${RECORD}const nm = path.join(process.cwd(), "node_modules");
fs.rmSync(nm, { recursive: true, force: true });
fs.cpSync(process.env.FAKE_ESLINT_SRC, path.join(nm, "eslint"), { recursive: true });
`);
fs.writeFileSync(NPM_FAIL, `${RECORD}process.stderr.write("npm ERR! code E404\\nnpm ERR! simulated npm failure\\n");
process.exit(1);
`);

const lockBody = (transitive) => `${JSON.stringify({
  name: "fixture", lockfileVersion: 3, requires: true,
  packages: {
    "": { devDependencies: { eslint: "10.13.0" } },
    "node_modules/eslint": { version: "10.13.0", dev: true },
    "node_modules/transitive-dep": { version: transitive, dev: true },
  },
}, null, 2)}\n`;

let seq = 0;
// project({ config, lock, eslint, git }) — a lint root (directory holding eslint.config.*) with src/a.js; lock writes a lockfile,
// eslint pre-installs the fake package, git makes it its own fixture repository.
function project(name, opts = {}) {
  const dir = path.join(TMP, "projects", `${++seq}-${name}`);
  fs.mkdirSync(path.join(dir, "src"), { recursive: true });
  fs.writeFileSync(path.join(dir, "src", "a.js"), "\"use strict\";\nmodule.exports = 1;\n");
  if (opts.config !== false) fs.writeFileSync(path.join(dir, "eslint.config.js"), "module.exports = [];\n");
  if (opts.lock) fs.writeFileSync(path.join(dir, "package-lock.json"), lockBody("1.0.0"));
  if (opts.eslint) fs.cpSync(FAKE_ESLINT_SRC, path.join(dir, "node_modules", "eslint"), { recursive: true });
  if (opts.git) gitInit(dir);
  return {
    dir,
    file: path.join(dir, "src", "a.js"),
    lock: path.join(dir, "package-lock.json"),
    stamp: path.join(dir, "node_modules", ".run-eslint-lock.sha256"),
    marker: path.join(TMP, `npm-marker-${seq}.jsonl`),
    log: path.join(TMP, `eslint-log-${seq}.jsonl`),
  };
}

// wrapperRepo(name) — a fixture repo holding a COPY of the wrapper (provision.js keys the same-repo
// check on its own location), committed, plus a linked worktree; returns { main, wt } checkouts.
function wrapperRepo(name) {
  const base = path.join(TMP, "repos", `${++seq}-${name}`);
  const mainDir = path.join(base, "main");
  for (const d of ["bin", path.join("hooks", "lib"), "src"]) fs.mkdirSync(path.join(mainDir, d), { recursive: true });
  fs.copyFileSync(WRAPPER, path.join(mainDir, "bin", "run-eslint"));
  fs.cpSync(path.join(REPO, "bin", "run-eslint.d"), path.join(mainDir, "bin", "run-eslint.d"), { recursive: true });
  fs.writeFileSync(path.join(mainDir, "hooks", "lib", "branch-diff.js"), "\"use strict\";\nmodule.exports = { toWindowsPath: (p) => p };\n");
  fs.writeFileSync(path.join(mainDir, "eslint.config.js"), "module.exports = [];\n");
  fs.writeFileSync(path.join(mainDir, "package-lock.json"), lockBody("1.0.0"));
  fs.writeFileSync(path.join(mainDir, "src", "a.js"), "\"use strict\";\nmodule.exports = 1;\n");
  gitInit(mainDir);
  git(mainDir, "add", "-A");
  git(mainDir, "commit", "-q", "-m", "init");
  const wtDir = path.join(base, "wt");
  git(mainDir, "worktree", "add", "-q", wtDir);
  const checkout = (dir, tag) => ({
    dir,
    wrapper: path.join(dir, "bin", "run-eslint"),
    file: path.join(dir, "src", "a.js"),
    lock: path.join(dir, "package-lock.json"),
    stamp: path.join(dir, "node_modules", ".run-eslint-lock.sha256"),
    marker: path.join(base, `npm-marker-${tag}.jsonl`),
    log: path.join(base, `eslint-log-${tag}.jsonl`),
  });
  return { main: checkout(mainDir, "main"), wt: checkout(wtDir, "wt") };
}

// Changes only the transitive entry (1.0.0 -> 1.0.1): one byte, direct pins untouched.
const bumpTransitive = (p) => fs.writeFileSync(p.lock, lockBody("1.0.1"));
const sha256 = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const readJsonl = (file) => (fs.existsSync(file) ? fs.readFileSync(file, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
const lockDirs = () => fs.readdirSync(SYS_TMP).filter((n) => /^run-eslint-.*\.lock$/.test(n));

// run(p, args, env) — the real wrapper in a child node, no shell. Every variable a branch under
// test reads is pinned here; a value of null removes it (RUN_ESLINT_PROVISION is unset unless given).
// A p carrying `wrapper` (from wrapperRepo) runs that copy instead of the repository's own.
function run(p, args, env = {}) {
  const base = { ...process.env };
  for (const k of Object.keys(base)) if (/^(RUN_ESLINT_|FAKE_)/.test(k)) delete base[k];
  Object.assign(base, {
    TMPDIR: SYS_TMP, TMP: SYS_TMP, TEMP: SYS_TMP, HOME: HOME_DIR, USERPROFILE: HOME_DIR,
    RUN_ESLINT_NPM_CLI: NPM_OK, FAKE_ESLINT_SRC,
    FAKE_NPM_MARKER: p ? p.marker : path.join(TMP, "npm-marker-none.jsonl"),
    FAKE_ESLINT_LOG: p ? p.log : path.join(TMP, "eslint-log-none.jsonl"),
  }, env);
  for (const [k, v] of Object.entries(base)) if (v === null || v === undefined) delete base[k];
  const done = spawnSync(process.execPath, [(p && p.wrapper) || WRAPPER, ...args], { cwd: NEUTRAL, env: base, encoding: "utf8", timeout: 120000 });
  return { status: done.status, stdout: done.stdout || "", stderr: done.stderr || "", error: done.error };
}

// git(cwd, ...args) — git inside a fixture repository, identity given on the command line.
function git(cwd, ...args) {
  const done = spawnSync("git", ["-C", cwd, "-c", "user.name=fixture", "-c", "user.email=fixture@example.com", ...args], { encoding: "utf8" });
  if (done.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${done.stderr}`);
  return done.stdout.trim();
}

module.exports = {
  REPO, TMP, SYS_TMP, NPM_OK, NPM_FAIL,
  project, wrapperRepo, bumpTransitive, sha256, readJsonl, lockDirs, run, git, gitInit,
};
