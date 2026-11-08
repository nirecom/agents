"use strict";
// Tests: bin/migrate-needs, bin/lib/migrate-needs.js
// Tags: TL2, bin, migrate, repo-settings, scope:issue-specific
// #2473 — UNPUSHED of bin/migrate-needs / collect(root): 1 only when a commit ahead of the upstream
// touches .agents.json, with and without an upstream, and the git start budget of that lookup.
// Split from feature-2473-migrate-needs.js so each part stays under the per-test time cap.
// TL3 gap: a real GitHub / GitLab remote; here origin is a local bare repo that is never a forge.
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

// UNPUSHED fixtures: origin's pushurl is a local bare repo and the branch tracks origin's copy.
function tracked(name, settings = { tests: TESTS_OK, migrate: DONE }) {
  const d = repo(name, settings);
  const bare = `${d}.git`;
  ORIG.spawnSync("git", ["init", "-q", "--bare", bare], { encoding: "utf8" });
  git(d, "config", "remote.origin.pushurl", bare);
  git(d, "push", "-q", "-u", "origin", "HEAD");
  return d;
}
// reformat(d) — commit .agents.json rewritten compact: same content (all done), a new commit of the file.
const reformat = (d) => {
  fs.writeFileSync(path.join(d, ".agents.json"), `${JSON.stringify({ tests: TESTS_OK, migrate: DONE })}\n`);
  commitAll(d);
};

caseBegin("MN-unpushed", "bin/migrate-needs");
test("MN-unpushed: 1 only when a commit ahead of the upstream touches .agents.json; 0 after the push", () => {
  const d = tracked("unpushed");
  const synced = cli(d);
  assert.equal(synced.kv.UNPUSHED, "0", `in sync with the upstream: ${synced.text}`);
  reformat(d);
  const ahead = cli(d);
  assert.equal(ahead.kv.UNPUSHED, "1", `one .agents.json commit ahead: ${ahead.text}`);
  assert.equal(ahead.kv.UNCOMMITTED, "0", "UNPUSHED is apart from UNCOMMITTED");
  git(d, "push", "-q", "origin", "HEAD");
  assert.equal(cli(d).kv.UNPUSHED, "0", "after the push");
});
caseEnd();

caseBegin("MN-unpushed-boundaries", "bin/lib/migrate-needs.js");
test("MN-unpushed-boundaries: an ahead commit without .agents.json gives 0", () => {
  const other = tracked("ahead-readme");
  fs.writeFileSync(path.join(other, "README"), "changed\n");
  commitAll(other);
  assert.equal(cli(other).kv.UNPUSHED, "0", "ahead by a commit that does not touch .agents.json");
});
caseEnd();

// pushedNoUpstream(name) — origin is a local bare repo; the branch is pushed with a plain
// `git push origin <b>` (no -u), so refs/remotes/origin/<b> exists but no upstream is set.
function pushedNoUpstream(name) {
  const d = repo(name, { tests: TESTS_OK, migrate: DONE });
  const bare = `${d}.git`;
  ORIG.spawnSync("git", ["init", "-q", "--bare", bare], { encoding: "utf8" });
  git(d, "config", "remote.origin.pushurl", bare);
  const b = git(d, "rev-parse", "--abbrev-ref", "HEAD").trim();
  git(d, "push", "-q", "origin", b);
  assert.throws(() => git(d, "rev-parse", "--abbrev-ref", "@{upstream}"), /git rev-parse/, `${name}: no upstream`);
  return d;
}
const touchReadme = (d) => {
  fs.writeFileSync(path.join(d, "README"), "changed\n");
  commitAll(d);
};

caseBegin("MN-unpushed-table", "bin/lib/migrate-needs.js");
test("MN-unpushed-table: UNPUSHED with and without an upstream, without origin, and for a non-.agents.json commit", () => {
  const rows = [
    { id: "a upstream, .agents.json commit pushed", make: () => { const d = tracked("t-a"); reformat(d); git(d, "push", "-q", "origin", "HEAD"); return d; }, want: "0" },
    { id: "b upstream, .agents.json commit unpushed", make: () => { const d = tracked("t-b"); reformat(d); return d; }, want: "1" },
    { id: "c no upstream, .agents.json commit unpushed", make: () => { const d = pushedNoUpstream("t-c"); reformat(d); return d; }, want: "1" },
    { id: "d no upstream, everything on origin", make: () => pushedNoUpstream("t-d"), want: "0" },
    { id: "e no origin remote", make: () => { const d = repo("t-e", { tests: TESTS_OK, migrate: DONE }, null); reformat(d); return d; }, want: "0" },
    { id: "f unpushed commit not touching .agents.json", make: () => { const d = pushedNoUpstream("t-f"); touchReadme(d); return d; }, want: "0" },
  ];
  const { collect } = require(LIB);
  for (const row of rows) {
    const d = row.make();
    const r = cli(d);
    assert.equal(r.rc, 0, `${row.id}: rc ${r.text}`);
    assert.equal(r.kv.UNPUSHED, row.want, `${row.id}: CLI UNPUSHED ${r.text}`);
    assert.equal(r.kv.UNCOMMITTED, "0", `${row.id}: UNPUSHED is apart from UNCOMMITTED`);
    assert.equal(String(collect(d).unpushed), row.want, `${row.id}: collect().unpushed`);
  }
});
caseEnd();

caseBegin("MN-unpushed-git-budget-no-upstream", "bin/lib/migrate-needs.js");
test("MN-unpushed-git-budget-no-upstream: all done, no upstream, origin/<b> exists: exactly 3 git starts (status, rev-parse, rev-list)", () => {
  const { collect } = require(LIB);
  const d = pushedNoUpstream("budget-no-upstream");
  const { seen } = spy(() => collect(d));
  assert.deepEqual(seen, ["git", "git", "git"], JSON.stringify(seen));
});
caseEnd();

caseBegin("MN-unpushed-git-budget", "bin/lib/migrate-needs.js");
test("MN-unpushed-git-budget: in sync starts git once; ahead adds one rev-list; neither starts gh or glab", () => {
  const { collect } = require(LIB);
  const d = tracked("budget");
  const inSync = spy(() => collect(d));
  assert.deepEqual(inSync.seen, ["git"], `in sync with an upstream: ${JSON.stringify(inSync.seen)}`);
  assert.equal(inSync.value.unpushed, 0);
  reformat(d);
  const ahead = spy(() => collect(d));
  assert.deepEqual(ahead.seen, ["git", "git"], `ahead: status + rev-list only: ${JSON.stringify(ahead.seen)}`);
  assert.equal(ahead.value.unpushed, 1);
  assert.deepEqual(ahead.value.needed, [], "the content judgment is unchanged");
});
caseEnd();
