"use strict";
// tests/hooks/feat-transcript-paths.js
// Tests: hooks/lib/transcript-paths.js, hooks/workflow-state/inheritance/candidates.js, bin/lib/resume-session/transcript-fallback.js
// Tags: TL1, scope:common, transcript, resume, session
// #299: the transcript-directory helpers (encodeCwd / getTranscriptBase) move out of the retired
// session-title lib into hooks/lib/transcript-paths.js; every consumer composes paths through it.

// TL3 gap: the real VS Code / Claude app title rendering is not observed, and neither is the
// directory name a live Claude Code build actually picks for a cwd (the encoder is assumed to match it).

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const restore = isolate();
const ROOT = path.resolve(__dirname, "..", "..");
const LIB = path.join(ROOT, "hooks", "lib", "transcript-paths.js");
const readSrc = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const savedBase = process.env.CLAUDE_TRANSCRIPT_BASE_DIR;
after(() => {
  if (savedBase === undefined) delete process.env.CLAUDE_TRANSCRIPT_BASE_DIR;
  else process.env.CLAUDE_TRANSCRIPT_BASE_DIR = savedBase;
  restore();
});

// withBase(fn) — runs fn(fixtureDir) with CLAUDE_TRANSCRIPT_BASE_DIR on a fresh temp dir.
function withBase(prefix, fn) {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  try {
    process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fixture;
    fn(fixture);
  } finally {
    delete process.env.CLAUDE_TRANSCRIPT_BASE_DIR;
    fs.rmSync(fixture, { recursive: true, force: true });
  }
}

caseBegin("encode-cwd-lower-case-dash-slug", "hooks/lib/transcript-paths.js");
test("TP1 encodeCwd is exported", () => assert.strictEqual(typeof require(LIB).encodeCwd, "function"));
for (const cwd of ["/home/u/My Repo/x.y", "C:\\Git\\Agents", "C:/git/worktrees/A_b", "/c/git/agents"]) {
  test(`TP1 encodeCwd(${JSON.stringify(cwd)}) matches ^[a-z0-9-]+$`, () => assert.match(String(require(LIB).encodeCwd(cwd)), /^[a-z0-9-]+$/));
}
// Exact values pinned to the retired lib's output (path.resolve, lower-case, non-alnum -> "-").
for (const [cwd, want] of process.platform === "win32"
  ? [["D:\\Work\\Repo", "d--work-repo"], ["D:/work/trees/A_b", "d--work-trees-a-b"]]
  : [["/home/u/My Repo/x.y", "-home-u-my-repo-x-y"], ["/c/git/agents", "-c-git-agents"]]) {
  test(`TP1 encodeCwd(${JSON.stringify(cwd)}) === ${want}`, () => assert.strictEqual(require(LIB).encodeCwd(cwd), want));
}
caseEnd();

caseBegin("get-transcript-base-override-and-default", "hooks/lib/transcript-paths.js");
test("TP2 override returned as-is", () => withBase("tp2-", (fixture) => assert.strictEqual(require(LIB).getTranscriptBase(), fixture)));
test("TP2 default is ~/.claude/projects", () => {
  const { getTranscriptBase } = require(LIB);
  delete process.env.CLAUDE_TRANSCRIPT_BASE_DIR;
  assert.strictEqual(getTranscriptBase(), path.join(os.homedir(), ".claude", "projects"));
});
caseEnd();

caseBegin("candidates-transcript-dir-composes-through-encode-cwd", "hooks/workflow-state/inheritance/candidates.js");
for (const cwd of ["/fixture/inj/repo", "C:/git/agents"]) {
  test(`TP3 basename(transcriptDirFor(${cwd})) === encodeCwd(cwd)`, () => {
    const { encodeCwd } = require(LIB);
    const candidates = require(path.join(ROOT, "hooks", "workflow-state", "inheritance", "candidates.js"));
    assert.strictEqual(path.basename(candidates.transcriptDirFor(cwd)), encodeCwd(cwd));
  });
}
test("TP3 candidates.js requires lib/transcript-paths", () => assert.match(readSrc("hooks/workflow-state/inheritance/candidates.js"), /lib\/transcript-paths/));
caseEnd();

caseBegin("resume-session-transcript-fallback-uses-new-lib", "bin/lib/resume-session/transcript-fallback.js");
test("TP4 locateUpstreamTranscript composes base + encodeCwd + <sid>.jsonl", () => withBase("tp4-", (fixture) => {
  const { encodeCwd, getTranscriptBase } = require(LIB);
  const { locateUpstreamTranscript } = require(path.join(ROOT, "bin", "lib", "resume-session", "transcript-fallback.js"));
  const want = path.join(getTranscriptBase(), encodeCwd("/fixture/up/repo"), "sid-tp4.jsonl");
  const got = locateUpstreamTranscript("sid-tp4", "/fixture/up/repo");
  assert.strictEqual(got, want);
  assert.ok(got.startsWith(fixture), `${got} is not under ${fixture}`);
}));
test("TP4 transcript-fallback.js requires hooks/lib/transcript-paths", () => assert.match(readSrc("bin/lib/resume-session/transcript-fallback.js"), /hooks\/lib\/transcript-paths/));
caseEnd();

caseBegin("count-subagents-references-new-lib-and-loads", "hooks/lib/transcript-paths.js");
test("TP5 count-subagents requires hooks/lib/transcript-paths", () => assert.match(readSrc("bin/count-subagents"), /hooks\/lib\/transcript-paths/));
test("TP5 transcript-paths.js loads in a fresh process", () => {
  const r = spawnSync(process.execPath, ["-e", "require(process.argv[1])", LIB], { encoding: "utf8", timeout: 30000 });
  assert.strictEqual(r.status, 0, r.stderr);
});
test("TP5 count-subagents parses", () => {
  const c = spawnSync(process.execPath, ["--check", path.join(ROOT, "bin", "count-subagents")], { encoding: "utf8", timeout: 30000 });
  assert.strictEqual(c.status, 0, c.stderr);
});
caseEnd();
