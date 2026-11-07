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
const DONE = { tracker: "done", issues: "done" };

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
  trackerDone: repo("tracker-done", { tests: TESTS_OK, migrate: { tracker: "done" } }),
  testsOnly: repo("tests-only", { migrate: DONE }),
  allDone: repo("all-done", { tests: TESTS_OK, migrate: DONE }),
  gitlab: repo("gitlab", null, "git@gitlab.com:o/r.git"),
  unknownHost: repo("unknown-host", null, "https://example.com/o/r.git"),
};
// UNCOMMITTED fixtures: an untracked .agents.json, and one changed after its commit.
const UNTRACKED = repo("untracked", null);
fs.writeFileSync(path.join(UNTRACKED, ".agents.json"), `${JSON.stringify({ tests: TESTS_OK, migrate: DONE })}\n`);
const MODIFIED = repo("modified", { tests: TESTS_OK, migrate: { tracker: "done" } });
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

// cutBranch(name, b) — main pushed to origin, then branch b cut from it (not pushed).
function cutBranch(name, b = "feature") {
  const d = repo(name, { tests: TESTS_OK, migrate: DONE });
  ORIG.spawnSync("git", ["init", "-q", "--bare", `${d}.git`], { encoding: "utf8" });
  git(d, "config", "remote.origin.pushurl", `${d}.git`);
  git(d, "branch", "-M", "main");
  git(d, "push", "-q", "origin", "main");
  git(d, "checkout", "-q", "-b", b);
  return d;
}
const pushTo = (d, ref) => git(d, "push", "-q", "origin", `HEAD:refs/heads/${ref}`);
const upstreamMain = (d) => git(d, "branch", "--set-upstream-to=origin/main");
// behindWithCommitOnMain(name, b) — origin/<b> at the base; a commit of .agents.json only on origin/main.
function behindWithCommitOnMain(name, b = "feature", commit = reformat) {
  const d = cutBranch(name, b);
  pushTo(d, b);
  commit(d);
  pushTo(d, "main");
  return d;
}

// One test per row, so a failure in one does not hide the others.
const PUSH_TARGET_ROWS = [
  { id: "upstream origin/main, origin/<b> behind, commit reachable from the upstream", make: () => { const d = behindWithCommitOnMain("pt-e"); upstreamMain(d); return d; }, want: "1" },
  { id: "the same on a branch name with a slash", make: () => { const d = behindWithCommitOnMain("pt-e-slash", "feat/x"); upstreamMain(d); return d; }, want: "1" },
  { id: "no upstream, origin/<b> behind, commit on another origin ref", make: () => behindWithCommitOnMain("pt-f"), want: "1" },
  { id: "upstream origin/main, origin/<b> behind, the reachable commit does not touch .agents.json", make: () => { const d = behindWithCommitOnMain("pt-readme", "feature", touchReadme); upstreamMain(d); return d; }, want: "0" },
  { id: "no origin/<b>, commit on another origin ref", make: () => { const d = cutBranch("pt-g"); reformat(d); pushTo(d, "main"); return d; }, want: "0" },
  { id: "no origin/<b>, upstream origin/main, commit on it (a freshly cut branch)", make: () => { const d = cutBranch("pt-g-up"); reformat(d); pushTo(d, "main"); upstreamMain(d); return d; }, want: "0" },
  { id: "no origin/<b>, commit on no origin ref", make: () => { const d = cutBranch("pt-g-none"); reformat(d); return d; }, want: "1" },
  { id: "upstream origin/main behind, origin/<b> in sync", make: () => { const d = cutBranch("pt-h"); reformat(d); pushTo(d, "feature"); upstreamMain(d); return d; }, want: "0" },
  { id: "upstream origin/<b> gone, commit on no origin ref", make: () => { const d = tracked("pt-gone"); git(d, "update-ref", "-d", `refs/remotes/origin/${git(d, "rev-parse", "--abbrev-ref", "HEAD").trim()}`); reformat(d); return d; }, want: "1" },
  { id: "detached HEAD, commit on an origin ref", make: () => { const d = cutBranch("pt-i"); reformat(d); pushTo(d, "main"); git(d, "checkout", "-q", "--detach"); return d; }, want: "0" },
  { id: "detached HEAD, commit on no origin ref", make: () => { const d = cutBranch("pt-i-none"); reformat(d); git(d, "checkout", "-q", "--detach"); return d; }, want: "1" },
];

caseBegin("MN-unpushed-push-target", "bin/lib/migrate-needs.js");
for (const row of PUSH_TARGET_ROWS) {
  test(`MN-unpushed-push-target: ${row.id} gives ${row.want}`, () => {
    const { collect } = require(LIB);
    const d = row.make();
    const r = cli(d);
    assert.equal(r.rc, 0, `rc ${r.text}`);
    assert.equal(r.kv.UNPUSHED, row.want, `CLI UNPUSHED ${r.text}`);
    assert.equal(String(collect(d).unpushed), row.want, "collect().unpushed");
  });
}
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

// MALFORMED: 1 when .agents.json exists and is not a JSON object (unparsable or non-object), else 0.
const MALFORMED_ROWS = [
  { id: "not JSON", settings: "{ not json\n", want: "1" },
  { id: "JSON array", settings: "[]\n", want: "1" },
  { id: "absent", settings: null, want: "0" },
  { id: "valid object", settings: { tests: TESTS_OK, migrate: DONE }, want: "0" },
];

caseBegin("MN-malformed-table", "bin/migrate-needs");
test("MN-malformed-table: MALFORMED through collect() and the bin/migrate-needs stdout", () => {
  const { collect } = require(LIB);
  MALFORMED_ROWS.forEach((row, i) => {
    const d = repo(`malformed-row-${i}`, row.settings);
    const r = cli(d);
    assert.equal(r.rc, 0, `${row.id}: rc ${r.text}`);
    assert.ok("MALFORMED" in r.kv, `${row.id}: MALFORMED line is printed: ${r.text}`);
    assert.equal(r.kv.MALFORMED, row.want, `${row.id}: CLI MALFORMED ${r.text}`);
    assert.equal(String(collect(d).malformed), row.want, `${row.id}: collect().malformed`);
  });
});
caseEnd();

caseBegin("MN-malformed-no-extra-process", "bin/lib/migrate-needs.js");
test("MN-malformed-no-extra-process: MALFORMED is a pure fs read and adds no git, gh or glab launch", () => {
  const { collect } = require(LIB);
  const valid = spy(() => collect(tracked("malformed-budget-valid")));
  assert.deepEqual(valid.seen, ["git"], `valid object, in sync: status only: ${JSON.stringify(valid.seen)}`);
  assert.equal(String(valid.value.malformed), "0");
  // Unparsable: every key is needed, so the host lookup adds one git remote get-url; nothing else.
  const bad = spy(() => collect(tracked("malformed-budget-bad", "{ not json\n")));
  assert.deepEqual(bad.seen, ["git", "git"], `malformed, in sync: status + host lookup only: ${JSON.stringify(bad.seen)}`);
  assert.equal(String(bad.value.malformed), "1");
});
caseEnd();
