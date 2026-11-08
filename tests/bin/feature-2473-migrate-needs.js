"use strict";
// Tests: bin/migrate-needs, bin/lib/migrate-needs.js, skills/migrate-tracker/scripts/needs.js, skills/migrate-issues/scripts/needs.js, skills/migrate-tests/scripts/needs.js
// Tags: TL2, bin, skills, migrate, repo-settings, scope:issue-specific
// #2473 — each needs.js exports key and needs(root) and runs as a CLI (exit 0 done, 10 needed),
// reading the repo settings file only. bin/migrate-needs aggregates the three in tracker, issues,
// tests order in one process and prints NEEDED / UNCOMMITTED / UNPUSHED / HOST. It never starts gh or glab;
// all done with the upstream origin/<b> starts git once (status) and the aggregation (bin/lib/migrate-needs.js
// collect(root), called in this process) takes under 3x a bare git status + 50ms (minimum of 3
// runs each, timed side by side so load cancels out); HOST is looked up (git remote get-url
// origin) only when tracker or issues is needed.
// TL3 gap: a real GitHub / GitLab remote; here origin is a URL string that is never contacted.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const cp = require("node:child_process");

const restore = isolate();
after(() => restore());

const CHECKOUT = path.resolve(__dirname, "..", "..");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "mn2473-"));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));
const ORIG = { spawnSync: cp.spawnSync, execFileSync: cp.execFileSync, execSync: cp.execSync };

function git(dir, ...args) {
  const r = ORIG.spawnSync("git", ["-C", dir, ...args], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout;
}
const commitAll = (d) => {
  git(d, "add", "-A");
  git(d, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--no-verify", "--allow-empty", "-m", "fixture");
};

const TESTS_OK = { dir: "tests", categorization: "flat", testHarness: "off", caseMarker: "off" };
const DONE = { tracker: "done", issues: "done", tests: "done" };

// repo(name, settings, origin) — committed repo; settings null = no file, a string = raw text.
function repo(name, settings, origin = "https://github.com/o/r.git") {
  const d = path.join(TMP, name);
  fs.mkdirSync(d, { recursive: true });
  gitInit(d);
  if (origin) git(d, "remote", "add", "origin", origin);
  fs.writeFileSync(path.join(d, "README"), "fixture\n");
  if (settings !== null) {
    fs.writeFileSync(path.join(d, ".agents.json"), typeof settings === "string" ? settings : `${JSON.stringify(settings, null, 2)}\n`);
  }
  commitAll(d);
  return d;
}

const R = {
  missing: repo("missing", null),
  malformed: repo("malformed", "{ not json\n"),
  trackerDone: repo("tracker-done", { tests: TESTS_OK, migrate: { tracker: "done", tests: "done" } }),
  testsNoMigrate: repo("tests-no-migrate", { tests: TESTS_OK, migrate: { tracker: "done", issues: "done" } }),
  testsOnly: repo("tests-only", { migrate: DONE }),
  allDone: repo("all-done", { tests: TESTS_OK, migrate: DONE }),
  gitlab: repo("gitlab", null, "git@gitlab.com:o/r.git"),
  unknownHost: repo("unknown-host", null, "https://example.com/o/r.git"),
};
// UNCOMMITTED fixtures: an untracked .agents.json, and one changed after its commit.
const UNTRACKED = repo("untracked", null);
fs.writeFileSync(path.join(UNTRACKED, ".agents.json"), `${JSON.stringify({ tests: TESTS_OK, migrate: DONE })}\n`);
const MODIFIED = repo("modified", { tests: TESTS_OK, migrate: { tracker: "done", tests: "done" } });
fs.writeFileSync(path.join(MODIFIED, ".agents.json"), `${JSON.stringify({ tests: TESTS_OK, migrate: DONE })}\n`);

const NEEDS = ["tracker", "issues", "tests"].map((k) => ({
  key: k, file: path.join(CHECKOUT, "skills", `migrate-${k}`, "scripts", "needs.js"),
}));
const CLI = path.join(CHECKOUT, "bin", "migrate-needs");
const LIB = path.join(CHECKOUT, "bin", "lib", "migrate-needs.js");

function cli(root) {
  const r = ORIG.spawnSync(process.execPath, [CLI, "--root", root], { cwd: root, encoding: "utf8", timeout: 60000 });
  const kv = {};
  for (const line of String(r.stdout || "").split(/\r?\n/)) {
    const m = /^([A-Z_]+)=(.*)$/.exec(line);
    if (m) kv[m[1]] = m[2];
  }
  const needed = String(kv.NEEDED || "").split(/[,\s]+/).filter(Boolean).map((s) => s.replace(/^migrate-/, ""));
  return { rc: r.status, kv, needed, text: `${r.stdout || ""}${r.stderr || ""}` };
}

// spy(fn) — every child process started while fn runs, by command name (git, gh, glab, ...).
function spy(fn) {
  const seen = [];
  const name = (c) => path.basename(String(c).trim().split(/\s+/)[0]).replace(/\.(exe|cmd)$/i, "");
  cp.spawnSync = (c, ...a) => { seen.push(name(c)); return ORIG.spawnSync(c, ...a); };
  cp.execFileSync = (c, ...a) => { seen.push(name(c)); return ORIG.execFileSync(c, ...a); };
  cp.execSync = (c, ...a) => { seen.push(name(c)); return ORIG.execSync(c, ...a); };
  try {
    return { value: fn(), seen };
  } finally {
    Object.assign(cp, ORIG);
  }
}

caseBegin("MN-needs-js-each", "skills/migrate-tracker/scripts/needs.js");
test("MN-needs-js-each: key + needs(root) and CLI exit 0/10 for missing, malformed and partly done", () => {
  const expect = {
    missing: { tracker: true, issues: true, tests: true },
    malformed: { tracker: true, issues: true, tests: true },
    trackerDone: { tracker: false, issues: true, tests: false },
    testsOnly: { tracker: false, issues: false, tests: true },
    // A valid tests section stays needed until migrate.tests records done.
    testsNoMigrate: { tracker: false, issues: false, tests: true },
    allDone: { tracker: false, issues: false, tests: false },
  };
  for (const n of NEEDS) {
    const mod = require(n.file);
    assert.equal(mod.key, n.key, `${n.key}: exported key`);
    for (const [fx, want] of Object.entries(expect)) {
      assert.equal(Boolean(mod.needs(R[fx])), want[n.key], `${n.key}.needs(${fx})`);
      const r = ORIG.spawnSync(process.execPath, [n.file, "--root", R[fx]], { cwd: R[fx], encoding: "utf8", timeout: 60000 });
      assert.equal(r.status, want[n.key] ? 10 : 0, `${n.key} CLI on ${fx}: ${r.stderr}`);
    }
  }
});
caseEnd();

// snapshot(d) — every file under d with its content, plus HEAD and porcelain status. .git/index is
// left out: git status may refresh its stat cache, which is no change to the repo.
function snapshot(d) {
  const files = {};
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const f = path.join(dir, e.name);
      const rel = path.relative(d, f).split(path.sep).join("/");
      if (rel === ".git/index") continue;
      if (e.isDirectory()) walk(f);
      else files[rel] = fs.readFileSync(f).toString("base64");
    }
  };
  walk(d);
  return { files, head: git(d, "rev-parse", "HEAD"), status: git(d, "status", "--porcelain", "--untracked-files=all") };
}

caseBegin("MN-done-no-side-effects", "skills/migrate-tracker/scripts/needs.js");
test("MN-done-no-side-effects: on an all-done repo each needs.js CLI and bin/migrate-needs exit 0 and change nothing", () => {
  const d = repo("done-untouched", { tests: TESTS_OK, migrate: DONE });
  const before = snapshot(d);
  for (const n of NEEDS) {
    const r = ORIG.spawnSync(process.execPath, [n.file, "--root", d], { cwd: d, encoding: "utf8", timeout: 60000 });
    assert.equal(r.status, 0, `${n.key} CLI on all done: ${r.stderr}`);
    assert.deepEqual(snapshot(d), before, `${n.key} CLI left the fixture unchanged`);
  }
  const agg = cli(d);
  assert.equal(agg.rc, 0, `bin/migrate-needs on all done: ${agg.text}`);
  assert.deepEqual(agg.needed, [], "nothing needed");
  assert.deepEqual(snapshot(d), before, "bin/migrate-needs left the fixture unchanged");
});
caseEnd();

caseBegin("MN-aggregate-order", "bin/migrate-needs");
test("MN-aggregate-order: NEEDED lists tracker, issues, tests in that order, only the needed ones", () => {
  assert.deepEqual(cli(R.missing).needed, ["tracker", "issues", "tests"], "missing");
  assert.deepEqual(cli(R.malformed).needed, ["tracker", "issues", "tests"], "malformed");
  assert.deepEqual(cli(R.trackerDone).needed, ["issues"], "tracker done");
  assert.deepEqual(cli(R.testsOnly).needed, ["tests"], "tests only");
  const done = cli(R.allDone);
  assert.equal(done.rc, 0, `all done rc: ${done.text}`);
  assert.ok("NEEDED" in done.kv, `NEEDED line is printed even when empty: ${done.text}`);
  assert.deepEqual(done.needed, [], "all done");
});
caseEnd();

caseBegin("MN-host", "bin/migrate-needs");
test("MN-host: HOST is github, gitlab or unknown from origin when tracker or issues is needed", () => {
  assert.equal(cli(R.missing).kv.HOST, "github", "github.com origin");
  assert.equal(cli(R.gitlab).kv.HOST, "gitlab", "gitlab.com origin");
  assert.equal(cli(R.unknownHost).kv.HOST, "unknown", "other origin");
});
caseEnd();

caseBegin("MN-uncommitted", "bin/migrate-needs");
test("MN-uncommitted: 1 for an untracked or changed .agents.json, 0 when it is committed as is", () => {
  const u = cli(UNTRACKED);
  assert.equal(u.kv.UNCOMMITTED, "1", `untracked: ${u.text}`);
  assert.deepEqual(u.needed, [], "the untracked file's content still counts as done");
  assert.equal(cli(MODIFIED).kv.UNCOMMITTED, "1", "changed after commit");
  assert.equal(cli(R.allDone).kv.UNCOMMITTED, "0", "committed as is");
});
caseEnd();

caseBegin("MN-no-gh-glab", "bin/lib/migrate-needs.js");
test("MN-no-gh-glab: the aggregation never starts gh or glab, and no source has a call that starts them", () => {
  const { collect } = require(LIB);
  assert.equal(typeof collect, "function", "bin/lib/migrate-needs.js exports collect(root)");
  for (const [fx, root] of Object.entries(R)) {
    const { seen } = spy(() => collect(root));
    const forge = seen.filter((c) => c === "gh" || c === "glab");
    assert.deepEqual(forge, [], `${fx}: started ${JSON.stringify(seen)}`);
  }
  for (const f of [LIB, CLI, ...NEEDS.map((n) => n.file)]) {
    const src = fs.readFileSync(f, "utf8");
    assert.doesNotMatch(src, /(spawn|exec)\w*\(\s*["'`](gh|glab)(\.exe)?["'`\s]/, `${path.relative(CHECKOUT, f)} starts gh or glab`);
  }
});
caseEnd();

caseBegin("MN-all-done-fast", "bin/lib/migrate-needs.js");
test("MN-all-done-fast: all done with an upstream starts git once and takes under 3x a bare git status + 50ms (min of 3 runs each)", () => {
  const { collect } = require(LIB);
  const allDone = tracked("fast-all-done");
  const { seen } = spy(() => collect(allDone));
  assert.deepEqual(seen, ["git"], `all done starts git once (status): ${JSON.stringify(seen)}`);
  const testsOnly = spy(() => collect(tracked("fast-tests-only", { migrate: DONE }))).seen;
  assert.deepEqual(testsOnly, ["git"], `tests only needs no HOST lookup: ${JSON.stringify(testsOnly)}`);
  const ms = (fn) => {
    const t0 = process.hrtime.bigint();
    fn();
    return Number(process.hrtime.bigint() - t0) / 1e6;
  };
  const collectTimes = [];
  const gitTimes = [];
  for (let i = 0; i < 3; i += 1) {
    collectTimes.push(ms(() => collect(allDone)));
    gitTimes.push(ms(() => ORIG.spawnSync("git", ["-C", allDone, "status", "--porcelain"], { encoding: "utf8" })));
  }
  const minCollect = Math.min(...collectTimes);
  const minGit = Math.min(...gitTimes);
  const fmt = (ts) => ts.map((t) => t.toFixed(1)).join(", ");
  assert.ok(minCollect < 3 * minGit + 50,
    `min collect ${minCollect.toFixed(1)}ms vs bound 3 x min git status ${minGit.toFixed(1)}ms + 50 (collect: ${fmt(collectTimes)}; git: ${fmt(gitTimes)})`);
});
caseEnd();

// UNPUSHED fixtures: origin's pushurl is a local bare repo and the branch tracks origin's copy.
function tracked(name, settings = { tests: TESTS_OK, migrate: DONE }) {
  const d = repo(name, settings);
  const bare = `${d}.git`;
  ORIG.spawnSync("git", ["init", "-q", "--bare", bare], { encoding: "utf8" });
  git(d, "config", "remote.origin.pushurl", bare);
  git(d, "push", "-q", "-u", "origin", "HEAD");
  return d;
}
