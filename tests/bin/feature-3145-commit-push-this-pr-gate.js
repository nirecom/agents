"use strict";
// Tests: bin/worker-dispatch/workers/commit-push/procedure.js, bin/worker-dispatch/workers/commit-push/this-pr-gate.js
// Tags: TL2, bin, worker-dispatch, commit-push, this-pr, push-gate, fake-spawn, fail-closed, table-driven, scope:issue-specific, pwsh-not-required
// #3145 S7: the commit-push worker withholds the push (pushTail) and the PR (resume count=0 ensurePr) while
// WORKTREE_NOTES.md holds an unsettled this-pr finding, on every route — fresh commit, resume, ENFORCE_WORKTREE
// off, non-forge remote, direct main, empty remote. Its git runs only through gate.js runGit (spawn.js).
// spawn.js is replaced through require.cache before any worker module loads; the stub records every child.
// TL3 gap (what this test does NOT catch):
// - a real remote / gh / glab: every child the worker starts is answered by the spawn.js stub here.
// Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const childProcess = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const REPO = path.join(__dirname, "..", "..");
const CP_DIR = path.join(REPO, "bin", "worker-dispatch", "workers", "commit-push");
const SPAWN_PATH = require.resolve(path.join(REPO, "bin", "worker-dispatch", "spawn.js"));

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f3145-cp-gate-"));
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); });

// Every direct child_process launch is counted while `armed`; the worker must start none of its own.
let armed = false;
const directCalls = [];
for (const name of ["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"]) {
  const orig = childProcess[name];
  childProcess[name] = function spied(...args) {
    if (armed) directCalls.push({ name, file: String(args[0]) });
    return orig.apply(this, args);
  };
}

const realSpawn = require(SPAWN_PATH);
let handler = () => { throw new Error("no spawn handler installed for this test"); };
require.cache[SPAWN_PATH] = {
  id: SPAWN_PATH, filename: SPAWN_PATH, loaded: true,
  exports: { ...realSpawn, run: (entry, opts) => handler(entry, opts) },
};
const procedure = () => require(path.join(CP_DIR, "procedure.js"));
const gateModule = () => require(path.join(CP_DIR, "this-pr-gate.js"));

const ok = (stdout) => ({ status: 0, signal: null, timedOut: false, spawnError: null, stdout: stdout || "", stderr: "" });
const err = (status, stderr) => ({ status, signal: null, timedOut: false, spawnError: null, stdout: "", stderr: stderr || "" });
const SHA = "1111111111111111111111111111111111111111";
const BASE = "2222222222222222222222222222222222222222";
const keyOf = (section, body) => crypto.createHash("sha256").update(`${section}\n${body}`).digest("hex").slice(0, 8);
const pushLine = (b) => `${b} not pushed; push and PR creation withheld (the commit stays local).`;
const prLine = (b) => `${b} has no unpushed commits; PR creation withheld. If this branch already has a PR, it already carries every commit.`;

const OPEN_BODY = "Rename the helper the goal asked for";
const OPEN_NOTES = ["## BugsFound", `- ${OPEN_BODY} <!-- severity: medium --> <!-- loc: src/a.js:3 --> <!-- pr-scope: this-pr -->`];
const FIXED_NOTES = ["## BugsFound", `- Fixed helper <!-- severity: medium --> <!-- loc: src/a.js:3 --> <!-- pr-scope: this-pr --> <!-- base: ${BASE} --> <!-- disposed: fixed -->`];
// The stub diff reports only src/a.js, so a fix claimed on src/b.js stays fixed-unverified.
const UNVERIFIED_BODY = "Fixed the other helper";
const UNVERIFIED_NOTES = ["## BugsFound", `- ${UNVERIFIED_BODY} <!-- severity: medium --> <!-- loc: src/b.js --> <!-- pr-scope: this-pr --> <!-- base: ${BASE} --> <!-- disposed: fixed -->`];
const RESCOPED_BODY = "Moved to a follow-up";
const RESCOPED_NOTES = ["## BugsFound", `- ${RESCOPED_BODY} <!-- severity: medium --> <!-- pr-scope: other --> <!-- base: ${BASE} --> <!-- rescoped-from: this-pr -->`];
const SETTLED_NOTES =["## BugsFound", "- Elsewhere <!-- severity: medium --> <!-- pr-scope: other -->", "- Accepted <!-- severity: medium --> <!-- pr-scope: this-pr --> <!-- user-accepted: kept as is -->"];

let seq = 0;
// sc: notes (lines | null = no file), branch, stat ("" = empty stage), upstream, count, origin,
// emptyRemote, enforce, worktreePath (override). Records every child the stub answers.
function runProcedure(sc) {
  seq += 1;
  const dir = path.join(TMP, `p${seq}`);
  const worktree = path.join(dir, "worktree");
  for (const d of ["checkout", "worktree", "logs", "state"]) fs.mkdirSync(path.join(dir, d), { recursive: true });
  fs.writeFileSync(path.join(dir, "checkout", ".env"), `WORKFLOW_STATE_DIR=${path.join(dir, "state").replace(/\\/g, "/")}\n`);
  if (Array.isArray(sc.notes)) fs.writeFileSync(path.join(worktree, "WORKTREE_NOTES.md"), `# Worktree Notes\n\n${sc.notes.join("\n")}\n`);
  if (sc.notesDir) fs.mkdirSync(path.join(worktree, "WORKTREE_NOTES.md"));
  const branch = sc.branch || "feature/3145";
  const calls = [];
  const ctx = {
    entry: { name: "commit-push", binaries: { external: [], scripts: {} } },
    anchors: { scriptCheckoutRoot: path.join(dir, "checkout"), plansDir: dir },
    logDir: path.join(dir, "logs"),
    path,
    fsguard: { writeFile: (p) => p },
  };
  handler = (entry, opts) => {
    const args = opts.args || [];
    const a = args.join(" ");
    calls.push({ entry, command: opts.command, script: opts.script || "", args });
    if (opts.command === "node" && opts.script === "workflowGate") return ok(JSON.stringify({ decision: "approve" }));
    if (opts.command === "bash" && opts.script === "bootstrapProbe") {
      return sc.emptyRemote ? ok(JSON.stringify({ preBootstrap: true, classification: "empty-repo" })) : err(1, "");
    }
    if (opts.command === "gh") return ok(JSON.stringify({ state: "OPEN", url: "https://github.com/o/r/pull/1" }));
    if (opts.command === "glab") return ok(JSON.stringify({ state: "opened", web_url: "https://gitlab.com/o/r/-/merge_requests/1" }));
    if (opts.command !== "git") return ok("");
    if (a === "rev-parse --abbrev-ref HEAD") return ok(`${branch}\n`);
    if (a === "diff --cached --stat") return ok(sc.stat === undefined ? " a.txt | 1 +\n" : sc.stat);
    if (a === "diff --cached --name-only -z") return ok("a.txt\0");
    if (args[0] === "rev-list") return ok(`${sc.count || 0}\n`);
    if (a.includes("@{upstream}")) return sc.upstream ? ok(`origin/${branch}\n`) : err(128, "no upstream");
    if (a === "symbolic-ref refs/remotes/origin/HEAD") return ok("refs/remotes/origin/main\n");
    if (a === "remote get-url origin") return ok(`${sc.origin || "https://github.com/o/r.git"}\n`);
    if (args.includes("--show-toplevel")) return ok(`${worktree.replace(/\\/g, "/")}\n`);
    if (args.includes("merge-base")) return args.includes("--is-ancestor") ? ok("") : ok(`${BASE}\n`);
    if (args.includes("ls-files")) return ok("");
    if (args.includes("diff") && args.includes("--name-only")) return ok(args.includes("-z") ? "src/a.js\0" : "src/a.js\n");
    if (args.includes("rev-parse")) return ok(`${SHA}\n`);
    return ok("");
  };
  const payload = {
    branch,
    worktree_path: sc.worktreePath !== undefined ? sc.worktreePath(dir) : worktree,
    session_id: "00000000-0000-4000-8000-000000003145",
    commit_message: "feat: a thing",
    wip_mode: true,
    enforce_worktree: sc.enforce || "on",
    closes_issues: [],
  };
  directCalls.length = 0;
  armed = true;
  let res;
  try { res = procedure().run(payload, ctx); } finally { armed = false; }
  const git = calls.filter((c) => c.command === "git");
  return {
    res, calls, ctx, branch, direct: directCalls.slice(),
    pushCalls: git.filter((c) => c.args[0] === "push"),
    commitCalls: git.filter((c) => c.args.includes("commit")),
    forgeCalls: calls.filter((c) => c.command === "gh" || c.command === "glab"),
    firstLine: String(res.summary || "").split(/\r?\n/)[0],
  };
}

caseBegin("push-withheld-on-every-route", "bin/worker-dispatch/workers/commit-push/procedure.js");
test("an open this-pr finding withholds the push on every route that reaches pushTail", () => {
  // [name, scenario, resumed, keyed body, substrings the summary must carry]
  const ROWS = [
    ["fresh commit", {}, false],
    ["resume count>0", { stat: "", upstream: true, count: 2 }, true],
    ["ENFORCE_WORKTREE off", { enforce: "off" }, false],
    ["non-forge remote", { origin: "https://git.example.com/o/r.git" }, false],
    ["direct main", { branch: "main" }, false],
    ["empty remote (bootstrap)", { emptyRemote: true }, false],
    ["fixed on src/b.js, diff only src/a.js", { notes: UNVERIFIED_NOTES }, false, UNVERIFIED_BODY, ["fixed-unverified", "src/b.js"]],
    ["rescoped, not filed", { notes: RESCOPED_NOTES }, false, RESCOPED_BODY, ["rescoped-unfiled"]],
  ];
  for (const [name, sc, resumed, body, must] of ROWS) {
    const r = runProcedure(Object.assign({ notes: OPEN_NOTES }, sc));
    for (const s of must || []) assert.ok(String(r.res.summary).includes(s), `${name}: summary carries "${s}" (${r.res.summary})`);
    assert.strictEqual(r.res.status, "this_pr_open", `${name}: status (${r.res.summary})`);
    assert.deepStrictEqual(r.pushCalls, [], `${name}: git push never runs`);
    assert.deepStrictEqual(r.forgeCalls, [], `${name}: no gh / glab`);
    if (resumed) assert.ok(r.firstLine.endsWith(pushLine(r.branch)), `${name}: first line (${r.firstLine})`);
    else assert.strictEqual(r.firstLine, pushLine(r.branch), `${name}: first line`);
    if (!resumed) assert.strictEqual(r.commitCalls.length, 1, `${name}: the commit itself still lands locally`);
    assert.ok(r.res.summary.includes(keyOf("BugsFound", body || OPEN_BODY)), `${name}: the refusal names the key`);
  }
});
caseEnd();

caseBegin("pr-withheld-on-resume-count-zero", "bin/worker-dispatch/workers/commit-push/procedure.js");
test("resume with no unpushed commits creates no PR on GitHub or GitLab", () => {
  for (const [forge, origin] of [["github", "https://github.com/o/r.git"], ["gitlab", "https://gitlab.com/o/r.git"]]) {
    const r = runProcedure({ notes: OPEN_NOTES, stat: "", upstream: true, count: 0, origin });
    assert.strictEqual(r.res.status, "this_pr_open", `${forge}: status (${r.res.summary})`);
    assert.strictEqual(r.firstLine, prLine(r.branch), `${forge}: first line`);
    assert.deepStrictEqual(r.forgeCalls, [], `${forge}: neither gh nor glab is called`);
    assert.deepStrictEqual(r.pushCalls, [], `${forge}: no push`);
  }
});
caseEnd();

caseBegin("refusal-lists-the-exits", "bin/worker-dispatch/workers/commit-push/this-pr-gate.js");
test("the held summary lists the exits per key (fix, rescope, accept sentinel)", () => {
  const r = runProcedure({ notes: OPEN_NOTES });
  const key = keyOf("BugsFound", OPEN_BODY);
  assert.ok(r.res.summary.includes(`[${key}]`), r.res.summary);
  for (const exit of [`key=${key} fixed`, "rescope", `<<WORKFLOW_THIS_PR_FINDING_ACCEPTED: key=${key}`]) {
    assert.ok(r.res.summary.includes(exit), `exit "${exit}" listed: ${r.res.summary}`);
  }
});
caseEnd();

caseBegin("fixed-entry-git-only-through-spawn", "bin/worker-dispatch/workers/commit-push/this-pr-gate.js");
test("a fixed this-pr entry is verified with git through spawn.js runGit, never child_process", () => {
  const r = runProcedure({ notes: FIXED_NOTES, enforce: "off" });
  const evidence = r.calls.filter((c) => c.command === "git" && (c.args.includes("merge-base") || (c.args.includes("diff") && !c.args.includes("--cached"))));
  assert.ok(evidence.length > 0, `fixedEvidence git ran through the spawn stub: ${JSON.stringify(r.calls.map((c) => c.args.join(" ")))}`);
  for (const c of evidence) assert.strictEqual(c.entry, r.ctx.entry, "routed with the worker's ctx.entry");
  assert.deepStrictEqual(r.direct, [], "no direct child_process launch from the worker process");
  assert.strictEqual(r.res.status, "pushed", `a verified fix lets the push through (${r.res.summary})`);
});
caseEnd();

caseBegin("legacy-status-without-open-findings", "bin/worker-dispatch/workers/commit-push/procedure.js");
test("no notes, or only settled / other entries, keep the pre-#3145 status", () => {
  // [name, scenario, want]
  const ROWS = [
    ["no notes, fresh, ENFORCE off", { notes: null, enforce: "off" }, "pushed"],
    ["no notes, non-forge remote", { notes: null, origin: "https://git.example.com/o/r.git" }, "pushed"],
    ["no notes, empty remote", { notes: null, emptyRemote: true }, "bootstrap_pending"],
    ["no notes, resume count=0 github", { notes: null, stat: "", upstream: true, count: 0 }, "pr_reused"],
    ["settled notes, fresh github", { notes: SETTLED_NOTES }, "pr_reused"],
  ];
  for (const [name, sc, want] of ROWS) {
    const r = runProcedure(sc);
    assert.strictEqual(r.res.status, want, `${name}: ${r.res.summary}`);
  }
  const gate = gateModule();
  assert.strictEqual(typeof gate.thisPrGate, "function", "this-pr-gate.js exports thisPrGate");
});
caseEnd();

caseBegin("degraded-worktree-path-holds", "bin/worker-dispatch/workers/commit-push/this-pr-gate.js");
test("an unusable worktree_path or an unreadable notes file holds the push (fail-closed)", () => {
  // [name, scenario]
  const ROWS = [
    ["worktree_path is a file", { notes: null, worktreePath: (dir) => { const f = path.join(dir, "plain-file"); fs.writeFileSync(f, "x"); return f; } }],
    ["worktree_path is empty", { notes: null, worktreePath: () => "" }],
    ["notes path is a directory", { notes: null, notesDir: true }],
  ];
  for (const [name, sc] of ROWS) {
    const r = runProcedure(sc);
    assert.strictEqual(r.res.status, "this_pr_open", `${name}: held (${r.res.summary})`);
    assert.deepStrictEqual(r.pushCalls, [], `${name}: no push`);
  }
});
caseEnd();
