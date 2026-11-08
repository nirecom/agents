"use strict";
// Tests: bin/lib/migrate-needs.js
// Tags: TL2, bin, migrate, repo-settings, scope:issue-specific
// #2473 — UNPUSHED push-target table of collect(root) and bin/migrate-needs: which origin ref the
// ahead .agents.json commit is judged against (upstream, origin/<b>, other origin refs, detached HEAD).
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
const ORIG = { spawnSync: cp.spawnSync };

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
const touchReadme = (d) => {
  fs.writeFileSync(path.join(d, "README"), "changed\n");
  commitAll(d);
};

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
