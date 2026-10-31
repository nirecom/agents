"use strict";
// tests/hooks/feat-forge-tracker-issue-title.js
// Tests: hooks/lib/forge/github.js, hooks/lib/forge/gitlab.js, hooks/lib/forge/stub.js, hooks/lib/forge-router.js
// Tags: TL1, scope:common, forge, tracker, issue-title
// #299: every tracker descriptor gains issueTitle(remoteUrl, ref, opts) -> string | null.
// Assumed signature: ref = {number, repo?} (parseIssueToken shape); opts = {timeoutMs, projectRoot,
// spawnSync} where opts.spawnSync replaces the real child_process call (the test injects it).

// TL3 gap: the real VS Code / Claude app title rendering is not observed, and neither are the real
// gh / glab binaries or a live GitLab host (every spawn here is an injected recorder).

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const ROOT = path.resolve(__dirname, "..", "..");
const mod = (rel) => require(path.join(ROOT, rel));

// Neutral environment: the global .env layer reads AGENTS_MAIN_ROOT/.env, so point it at an empty
// fixture; drop every GitLab host variable and the project dir so only what a case sets applies.
const ENV_KEYS = ["AGENTS_MAIN_ROOT", "CLAUDE_PROJECT_DIR", "GITLAB_HOSTNAME", "GITLAB_SSH_HOSTNAME"];
const savedEnv = Object.fromEntries(ENV_KEYS.map((k) => [k, process.env[k]]));
const savedCwd = process.cwd();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "tracker-title-"));
const neutral = path.join(tmp, "neutral");
fs.mkdirSync(neutral);
fs.mkdirSync(path.join(tmp, "agents-stub"));
fs.writeFileSync(path.join(tmp, "agents-stub", ".env"), "");
process.env.AGENTS_MAIN_ROOT = path.join(tmp, "agents-stub");
for (const k of ENV_KEYS.slice(1)) delete process.env[k];
process.chdir(neutral);
after(() => {
  process.chdir(savedCwd);
  for (const k of ENV_KEYS) { if (savedEnv[k] === undefined) delete process.env[k]; else process.env[k] = savedEnv[k]; }
  fs.rmSync(tmp, { recursive: true, force: true });
  restore();
});

function recorder(result) {
  const calls = [];
  const fn = (cmd, args, opts) => { calls.push({ cmd, args, opts }); return typeof result === "function" ? result(cmd, args) : result; };
  fn.calls = calls;
  return fn;
}
const argv = (c) => (c ? `${c.cmd} ${(c.args || []).join(" ")}` : "<none>");
const OPTS = (sp) => ({ timeoutMs: 3000, spawnSync: sp });
const github = () => mod("hooks/lib/forge/github.js").trackerGithub;
const gitlab = () => mod("hooks/lib/forge/gitlab.js").trackerGitlab;

// Abnormal tracker answers, shared by github and gitlab (CPR-ORTH): each must spawn once and answer null.
const ABNORMAL = [
  ["non-zero exit", () => ({ status: 1, stdout: "", stderr: "not found" })],
  ["whitespace-only stdout", () => ({ status: 0, stdout: "  \n\t\n", stderr: "" })],
  ["spawn error (status null)", () => ({ error: new Error("spawn ENOENT"), status: null, stdout: "", stderr: "" })],
];

caseBegin("every-tracker-descriptor-has-issue-title", "hooks/lib/forge-router.js");
test("T1 every FORGE_DESCRIPTORS tracker has issueTitle", () => {
  const { FORGE_DESCRIPTORS } = mod("hooks/lib/forge-router.js");
  for (const [type, d] of Object.entries(FORGE_DESCRIPTORS)) {
    assert.strictEqual(typeof (d.tracker && d.tracker.issueTitle), "function", `${type}.tracker.issueTitle`);
  }
});
test("T1 trackerStub.issueTitle is a function", () => assert.strictEqual(typeof mod("hooks/lib/forge/stub.js").trackerStub.issueTitle, "function"));
caseEnd();

caseBegin("github-issue-title-argv-timeout-and-owner-fill-in", "hooks/lib/forge/github.js");
test("T2 github argv, timeout and trimmed title", () => {
  const sp = recorder({ status: 0, stdout: "Fix the widget\n", stderr: "" });
  const got = github().issueTitle("https://github.com/o/r.git", { number: 12 }, OPTS(sp));
  assert.strictEqual(sp.calls.length, 1, "one spawn");
  assert.strictEqual(argv(sp.calls[0]), "gh issue view 12 -R o/r --json title --jq .title");
  assert.strictEqual(sp.calls[0].opts && sp.calls[0].opts.timeout, 3000, JSON.stringify(sp.calls[0].opts));
  assert.strictEqual(got, "Fix the widget");
});
for (const [label, answer] of ABNORMAL) {
  test(`T2 github ${label} -> null (spawn observed)`, () => {
    const sp = recorder(answer());
    const r = github().issueTitle("https://github.com/o/r.git", { number: 12 }, OPTS(sp));
    assert.strictEqual(sp.calls.length, 1, "spawn observed");
    assert.strictEqual(r, null);
  });
}
test("T3 short repo#N fills the origin owner", () => {
  const sp = recorder({ status: 0, stdout: "Other\n" });
  github().issueTitle("git@github.com:o/r.git", { number: 5, repo: "other" }, OPTS(sp));
  assert.strictEqual(argv(sp.calls[0]), "gh issue view 5 -R o/other --json title --jq .title");
});
test("T3 owner/repo#N is used as given", () => {
  const sp = recorder({ status: 0, stdout: "Full\n" });
  github().issueTitle("https://github.com/o/r.git", { number: 6, repo: "x/y" }, OPTS(sp));
  assert.strictEqual(argv(sp.calls[0]), "gh issue view 6 -R x/y --json title --jq .title");
});
for (const [label, url, ref] of [
  ["invalid repo in ref", "https://github.com/o/r.git", { number: 5, repo: "bad repo;rm" }],
  ["invalid owner in ref", "https://github.com/o/r.git", { number: 5, repo: "-x/y" }],
  ["unparseable origin", "not a url", { number: 5 }],
]) {
  test(`T3 ${label} -> null with 0 spawns`, () => {
    const tracker = github();
    const bad = recorder({ status: 0, stdout: "never\n" });
    const r = tracker.issueTitle(url, ref, OPTS(bad));
    assert.strictEqual(bad.calls.length, 0, `spawned: ${bad.calls.map(argv).join(" | ")}`);
    assert.strictEqual(r, null);
  });
}
caseEnd();

caseBegin("gitlab-issue-title-argv-parsing-and-project-local-host", "hooks/lib/forge/gitlab.js");
test("T4 gitlab argv, timeout and title read from JSON", () => {
  const sp = recorder({ status: 0, stdout: JSON.stringify({ iid: 12, title: "GL title" }) });
  const got = gitlab().issueTitle("https://gitlab.com/g/p.git", { number: 12 }, OPTS(sp));
  assert.strictEqual(argv(sp.calls[0]), "glab api --hostname gitlab.com projects/g%2Fp/issues/12");
  assert.strictEqual(sp.calls[0].opts && sp.calls[0].opts.timeout, 3000);
  assert.strictEqual(got, "GL title");
});
for (const [label, result] of [
  ["broken JSON", { status: 0, stdout: "{not json" }],
  ["non-zero exit with a JSON body", { status: 1, stdout: JSON.stringify({ title: "x" }) }],
  ["title missing", { status: 0, stdout: JSON.stringify({ iid: 12 }) }],
]) {
  test(`T4 ${label} -> null`, () => {
    const tracker = gitlab();
    assert.strictEqual(tracker.issueTitle("https://gitlab.com/g/p.git", { number: 12 }, OPTS(recorder(result))), null);
  });
}
for (const [label, answer] of ABNORMAL.concat([["whitespace-only title", () => ({ status: 0, stdout: JSON.stringify({ iid: 12, title: "  \t " }) })]])) {
  test(`T4 gitlab ${label} -> null (spawn observed)`, () => {
    const sp = recorder(answer());
    const r = gitlab().issueTitle("https://gitlab.com/g/p.git", { number: 12 }, OPTS(sp));
    assert.strictEqual(sp.calls.length, 1, "spawn observed");
    assert.strictEqual(r, null);
  });
}
test("T4 '..' segment -> null with 0 spawns", () => {
  const tracker = gitlab();
  const dots = recorder({ status: 0, stdout: JSON.stringify({ title: "x" }) });
  const r = tracker.issueTitle("https://gitlab.com/g/p.git", { number: 12, repo: "../evil" }, OPTS(dots));
  assert.strictEqual(dots.calls.length, 0, `spawned: ${dots.calls.map(argv).join(" | ")}`);
  assert.strictEqual(r, null);
});
// ref.repo symmetric to T3: short form replaces the origin namespace's last segment; a/b is the project.
test("T4 short repo#N replaces the last namespace segment", () => {
  const sp = recorder({ status: 0, stdout: JSON.stringify({ title: "S" }) });
  gitlab().issueTitle("https://gitlab.com/grp/sub/p.git", { number: 5, repo: "other" }, OPTS(sp));
  assert.strictEqual(argv(sp.calls[0]), "glab api --hostname gitlab.com projects/grp%2Fsub%2Fother/issues/5");
});
test("T4 a/b#N is used as the project", () => {
  const sp = recorder({ status: 0, stdout: JSON.stringify({ title: "F" }) });
  gitlab().issueTitle("https://gitlab.com/g/p.git", { number: 6, repo: "x/y" }, OPTS(sp));
  assert.strictEqual(argv(sp.calls[0]), "glab api --hostname gitlab.com projects/x%2Fy/issues/6");
});
test("T4b project-local GITLAB_HOSTNAME reaches --hostname; without projectRoot it is not used", () => {
  const tracker = gitlab();
  const { localEnvPathFor } = mod("hooks/lib/local-env.js");
  const root = path.join(tmp, "project");
  fs.mkdirSync(root);
  fs.writeFileSync(localEnvPathFor(root), "GITLAB_HOSTNAME=git.corp.example\n");
  const url = "https://git.corp.example/g/p.git";
  const sp = recorder({ status: 0, stdout: JSON.stringify({ title: "Self-hosted" }) });
  const got = tracker.issueTitle(url, { number: 12 }, { timeoutMs: 3000, projectRoot: root, spawnSync: sp });
  const a = sp.calls[0] && sp.calls[0].args ? sp.calls[0].args : [];
  assert.ok(a.indexOf("--hostname") !== -1 && a[a.indexOf("--hostname") + 1] === "git.corp.example", argv(sp.calls[0]));
  assert.strictEqual(got, "Self-hosted");
  const ctl = recorder({ status: 0, stdout: JSON.stringify({ title: "Self-hosted" }) });
  tracker.issueTitle(url, { number: 12 }, OPTS(ctl));
  assert.ok(!ctl.calls.some((c) => (c.args || []).includes("git.corp.example")), ctl.calls.map(argv).join(" | "));
});
caseEnd();

caseBegin("stub-tracker-answers-null-without-spawning", "hooks/lib/forge/stub.js");
test("T5 stub -> null, 0 spawns", () => {
  const { trackerStub } = mod("hooks/lib/forge/stub.js");
  const sp = recorder({ status: 0, stdout: "x" });
  const r = trackerStub.issueTitle("https://example.org/a/b.git", { number: 1 }, OPTS(sp));
  assert.strictEqual(sp.calls.length, 0);
  assert.strictEqual(r, null);
});
caseEnd();
