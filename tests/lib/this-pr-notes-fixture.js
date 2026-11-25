"use strict";
// tests/lib/this-pr-notes-fixture.js — shared fixture for the #3145 this-pr gate tests
// (tests/hooks/feature-3145-write-code-this-pr-gate.js, tests/hooks/feature-3145-this-pr-accept-sentinel.js).
// The notes path is resolved from the PROCESS cwd (trusted repo dir) and compared with the
// session's linked worktree, so every gate / handler call runs in a child process whose cwd
// the case chooses. The fixture is a real main repo plus a `git worktree add` linked worktree,
// which is what resolveSessionWorktreePath accepts as an owned linked worktree.

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { isolate, gitInit } = require("./harness");

const ROOT = path.resolve(__dirname, "..", "..");
const fwd = (p) => p.replace(/\\/g, "/");
const PREFIX_STEPS = ["workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete", "write_tests", "review_tests"];

let TMP = null;
function setup(prefix) {
  const restore = isolate();
  TMP = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), `${prefix}-`)));
  process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
  fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
  delete process.env.CLAUDE_PROJECT_DIR;
  for (const n of ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"]) delete process.env[n];
  process.on("exit", () => {
    restore();
    fs.rmSync(TMP, { recursive: true, force: true });
  });
  return TMP;
}

function git(dir, args) {
  const r = spawnSync("git", ["-C", dir].concat(args), { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr || r.error}`);
  return (r.stdout || "").trim();
}

let n = 0;
// makeRepo(tag) -> { main, wt, base, plain }: main repo with one commit, a linked worktree on a
// topic branch, the HEAD sha (the entries' base), and a non-git directory.
function makeRepo(tag) {
  const dir = path.join(TMP, `${tag}-${++n}`);
  const main = path.join(dir, "main");
  fs.mkdirSync(path.join(main, "src"), { recursive: true });
  gitInit(main);
  fs.writeFileSync(path.join(main, "src", "a.js"), "module.exports = 1;\n");
  fs.writeFileSync(path.join(main, "src", "b.js"), "module.exports = 2;\n");
  git(main, ["add", "-A"]);
  git(main, ["-c", "user.email=t@example.invalid", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base"]);
  const wt = path.join(dir, "wt");
  git(main, ["worktree", "add", "-q", "-b", "feature/fixture", wt]);
  const plain = path.join(dir, "plain");
  fs.mkdirSync(plain);
  return { main, wt, base: git(wt, ["rev-parse", "HEAD"]), plain };
}

// seedState(sid, cwd): raw v2 state, every step before write_code complete, session cwd = `cwd`.
function seedState(sid, cwd) {
  const at = new Date().toISOString();
  const events = PREFIX_STEPS.map((step, i) => ({
    kind: "step_status", step, status: "complete", provenance: "observed", origin: "test-fixture", at, seq: i + 1,
  }));
  fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`), JSON.stringify({
    version: 2, session_id: sid, created_at: at,
    session_start_context: { cwd: fwd(cwd), git_branch: "feature/fixture" },
    workflow_type: "wf-code", deliverable_type: "wf-code", events,
  }, null, 2));
}

// entry(body, o) — one notes line in the S1 marker order.
function entry(body, o) {
  const x = o || {};
  let s = `- ${body} <!-- severity: high -->`;
  if (x.loc) s += ` <!-- loc: ${x.loc} -->`;
  s += ` <!-- pr-scope: ${x.scope || "this-pr"} -->`;
  if (x.base) s += ` <!-- base: ${x.base} -->`;
  if (x.rescoped) s += " <!-- rescoped-from: this-pr -->";
  if (x.terminal) s += ` ${x.terminal}`;
  return s;
}

// writeNotes(dir, { BugsFound: [lines], RelatedTasks: [lines] }) -> notes path.
function writeNotes(dir, sections) {
  let text = "# Worktree Notes\n";
  for (const [name, lines] of Object.entries(sections)) text += `\n## ${name}\n${lines.join("\n")}\n`;
  const p = path.join(dir, "WORKTREE_NOTES.md");
  fs.writeFileSync(p, text);
  return p;
}

const key = (section, body) => require(path.join(ROOT, "hooks", "lib", "finding-approval.js")).findingKey(section, body);

const DRIVER = `"use strict";
const [, , root, mode, sid, arg] = process.argv;
const out = {};
try {
  if (mode === "gate") {
    out.res = require(root + "/hooks/workflow-state/record-step-verdict.js").recordStepVerdict(sid, "write_code", "complete",
      { gate: arg, provenance: "declared", origin: arg === "mark" ? "next-step-mark" : arg === "reset" ? "reset-sentinel" : "mark-step" });
  } else if (mode === "check") {
    out.res = require(root + "/hooks/workflow-state/record-step-verdict/this-pr-open.js").checkWriteCodeThisPr(sid);
  } else if (mode === "accept") {
    const msgs = [];
    const unapplied = [];
    out.handled = require(root + "/hooks/workflow-mark/this-pr-accept-handler.js").handle({
      cmd: arg, sessionId: sid, repoCwd: process.cwd(), toolCwd: process.cwd(),
      pushMessage: (m) => msgs.push(String(m)), pushUnapplied: (m) => unapplied.push(String(m)),
    });
    out.msgs = msgs;
    out.unapplied = unapplied;
  }
} catch (e) {
  out.error = String((e && e.stack) || e).split("\\n").slice(0, 3).join(" | ");
}
process.stdout.write(JSON.stringify(out));
`;

// drive(cwd, mode, sid, arg) -> the driver's JSON, run with `cwd` as the process cwd.
function drive(cwd, mode, sid, arg) {
  const driver = path.join(TMP, "driver.js");
  if (!fs.existsSync(driver)) fs.writeFileSync(driver, DRIVER);
  const r = spawnSync(process.execPath, [driver, fwd(ROOT), mode, sid, arg === undefined ? "" : arg], {
    cwd, encoding: "utf8", timeout: 60000, env: Object.assign({}, process.env),
  });
  try {
    return JSON.parse(r.stdout);
  } catch (_) {
    return { error: `driver exit ${r.status}: ${(r.stderr || "").slice(0, 300)}` };
  }
}

function stepStatus(sid, step) {
  const st = require(path.join(ROOT, "hooks", "workflow-state")).readState(sid) || {};
  return ((st.steps || {})[step] || {}).status;
}
function eventCount(sid) {
  const st = require(path.join(ROOT, "hooks", "workflow-state")).readState(sid) || {};
  return (st.events || []).length;
}

module.exports = { ROOT, setup, git, makeRepo, seedState, entry, writeNotes, key, drive, stepStatus, eventCount };
