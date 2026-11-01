"use strict";
// Tests: bin/check-glossary-drift, hooks/workflow-state/glossary-check/scope/artifact.js, bin/lib/glossary-drift.js, hooks/workflow-state/glossary-check/scope/changed-lines.js, bin/lib/glossary-drift/scan.js
// Tags: TL2, hooks, glossary, glossary-check, glossary-drift, merge, scope:issue-specific
// #2770: the stages that scan staged files (tests / code / docs) scan only the lines a staged
// change adds or modifies against HEAD; a new file is scanned whole; while merging, the line
// filter applies to the paths left after the merge-incoming subtraction. The stages that scan a
// plan file are unchanged.
// TL3 gap (what this test does NOT catch):
// - a real claude session committing through the commit gate with a partly edited file.
// Fixtures: tests/lib/glossary-check-fixture.js, ./feat-2761-glossary-merge/fixture.js.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restoreIsolation = isolate();
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "g2770-transcripts-"));
delete process.env.CLAUDE_PROJECT_DIR;
delete process.env.CLAUDE_CODE_SESSION_ID;
process.chdir(os.tmpdir());

const F = require("../lib/glossary-check-fixture");
const M = require("./feat-2761-glossary-merge/fixture");

const W = F.VARIANT;
const DRIFT_RE = /DRIFT: (\S+) "([^"]*)" -> "([^"]*)" at (.+):(\d+)\s*$/;
const hits = (text) => String(text).split(/\r?\n/).map((l) => DRIFT_RE.exec(l)).filter(Boolean)
  .map((m) => `${F.slash(m[4])}:${m[5]}`);
const guarded = (name, fn) => M.guarded(F.check, name, fn);
// The case fails when any F.check inside it (or an exception, via guarded) adds a failure.
const verdict = (label, fn) => () => noNewFailures(F.failureCount, () => guarded(label, fn));
after(() => {
  restoreIsolation();
  F.finish();
});
const show = (r) => `exit=${r.code} ${r.out}${r.err}`;
const APPEND = { tests: "echo unrelated\n", code: "module.exports.b = 2;\n", docs: "\nUnrelated text.\n" };

// A repo whose HEAD holds the stage's target file carrying the variant, and a session at that stage.
function committed(tag, stage) {
  const repo = F.mkRepo(tag);
  M.commitAll(repo, { [F.TARGET[stage]]: F.targetBody(stage, W) }, "fixture: target with the variant");
  return { repo, sid: F.seedSession(tag, stage, { cwd: repo }) };
}

caseBegin("unchanged variant lines of a modified file are not scanned", "hooks/workflow-state/glossary-check/scope/artifact.js");
test("B1: unchanged variant lines of a modified file are not scanned", () => noNewFailures(F.failureCount, () => {
for (const stage of F.RS_STAGES) {
  guarded(`B1 ${stage}`, () => {
    const s = committed(`b1-${stage}`, stage);
    F.stageFile(s.repo, F.TARGET[stage], F.targetBody(stage, W) + APPEND[stage]);
    const r = F.drift(s.sid, stage, s.repo, false);
    F.check(`B1 ${stage}: an unrelated added line leaves the old variant line unscanned (exit 0, no DRIFT)`,
      r.code === 0 && hits(r.out).length === 0, show(r));
  });
}
}));
caseEnd();

caseBegin("a variant on an added line is reported at its file line", "bin/check-glossary-drift");
test("B2: a variant on an added line is reported at its file line", verdict("B2", () => {
  const s = committed("b2", "docs");
  F.stageFile(s.repo, F.TARGET.docs, `${F.targetBody("docs", W)}\nEach ${W} is new.\n`);
  const r = F.drift(s.sid, "docs", s.repo, false);
  F.check("B2 docs: the added variant line is reported at docs/guide.md:5", r.code === 1 && hits(r.out).includes("docs/guide.md:5"), show(r));
}));
caseEnd();

caseBegin("a new file is scanned whole", "bin/check-glossary-drift");
test("B3: a new file is scanned whole", verdict("B3", () => {
  const repo = F.mkRepo("b3");
  F.stageFile(repo, "docs/new.md", `# New\n\nEach ${W} is checked.\n`);
  const sid = F.seedSession("b3", "docs", { cwd: repo });
  const r = F.drift(sid, "docs", repo, false);
  F.check("B3 docs: every line of a new file is scanned (docs/new.md:3 reported)", r.code === 1 && hits(r.out).includes("docs/new.md:3"), show(r));
}));
caseEnd();

caseBegin("merge: the line filter applies after the merge-incoming subtraction", "hooks/workflow-state/glossary-check/scope/artifact.js");
test("B4: merge: the line filter applies after the merge-incoming subtraction", verdict("B4", () => {
  const repo = F.mkRepo("b4");
  const shared = (tail) => `# Shared\n\nEach ${W} is old.\n\nPlain text${tail}\n`;
  M.commitAll(repo, { "docs/shared.md": shared(".") }, "fixture: merge base");
  M.startMerge(repo, {
    upstream: { "docs/main-only.md": `# Main only\n\nEach ${W} is checked.\n`, "docs/shared.md": shared(" (main).") },
    branch: { "docs/shared.md": shared(" (branch).") },
    resolve: { "docs/shared.md": `${shared(" (resolved).")}\nEach ${W} is new.\n` },
  });
  const sid = F.seedSession("b4", "docs", { cwd: repo });
  const r = F.drift(sid, "docs", repo, false);
  F.check("B4 docs: only the added line of docs/shared.md is reported (docs/shared.md:7)",
    r.code === 1 && JSON.stringify(hits(r.out)) === '["docs/shared.md:7"]', show(r));
}));
caseEnd();

caseBegin("a plan-file stage still scans the whole plan", "bin/check-glossary-drift");
test("B5: a plan-file stage still scans the whole plan", verdict("B5", () => {
  const s = F.setupStage("b5", "outline", W);
  const r = F.drift(s.sid, "outline", s.repo, false);
  F.check("B5 outline: the variant in the plan is reported (exit 1)", r.code === 1 && hits(r.out).length > 0, show(r));
}));
caseEnd();

caseBegin("a deletion-only change scans no line", "hooks/workflow-state/glossary-check/scope/artifact.js");
test("B6: a deletion-only change scans no line", verdict("B6", () => {
  const s = committed("b6", "docs");
  F.stageFile(s.repo, F.TARGET.docs, F.targetBody("docs", W).replace("# Guide\n\n", ""));
  const r = F.drift(s.sid, "docs", s.repo, false);
  F.check("B6 docs: removing a line next to an unchanged variant line reports nothing (exit 0)",
    r.code === 0 && hits(r.out).length === 0, show(r));
  const d = committed("b6-rm", "docs");
  F.git(d.repo, ["rm", "-q", "--", F.TARGET.docs]);
  const rm = F.drift(d.sid, "docs", d.repo, false);
  F.check("B6 docs: a staged whole-file deletion reports nothing (exit 0)", rm.code === 0 && hits(rm.out).length === 0, show(rm));
}));
caseEnd();

caseBegin("a modified committed line is reported at its file line, an unchanged variant line is not", "bin/check-glossary-drift");
test("C1: a modified committed line is reported at its file line, an unchanged variant line is not", verdict("C1", () => {
  const repo = F.mkRepo("c1");
  const body = (mid) => `# Guide\n\n${mid}\n\nEach ${W} is checked.\n`;
  M.commitAll(repo, { [F.TARGET.docs]: body("Plain text here.") }, "fixture: a plain line above a variant line");
  F.stageFile(repo, F.TARGET.docs, body(`Plain ${W} text here.`));
  const sid = F.seedSession("c1", "docs", { cwd: repo });
  const r = F.drift(sid, "docs", repo, false);
  F.check("C1 docs: exactly the modified line is reported (docs/guide.md:3), the unchanged docs/guide.md:5 is not",
    r.code === 1 && JSON.stringify(hits(r.out)) === '["docs/guide.md:3"]', show(r));
}));
caseEnd();

caseBegin("record and commit gate agree under line narrowing", "hooks/workflow-gate/glossary-record-checker.js");
test("C2: record and commit gate agree under line narrowing", verdict("C2", () => {
  const G = require("./feat-2529-glossary-commit-gate/gate");
  const { stageFingerprint } = require(path.join(F.ROOT, "hooks/workflow-state/glossary-check/scope"));
  const repo = F.mkRepo("c2");
  M.commitAll(repo, { [F.TARGET.docs]: F.targetBody("docs", W) }, "fixture: target with the variant");
  F.stageFile(repo, F.TARGET.docs, F.targetBody("docs", W) + APPEND.docs);
  const sid = F.seedSession("c2", "docs", { cwd: repo, ownStatus: "complete" });
  G.recordOk("C2 docs (drift only on an unchanged line)", F.drift(sid, "docs", repo), 0);
  const rec = F.recordOf(sid, "docs");
  F.check("C2 the record holds no finding", !!rec && Array.isArray(rec.findings) && rec.findings.length === 0, JSON.stringify(rec));
  const now = stageFingerprint(sid, "docs", { repoDir: repo });
  F.check("C2 stageFingerprint equals the recorded fingerprint", now.ok && !!rec && rec.fingerprint === now.fingerprint,
    `${JSON.stringify(now)} vs ${rec && rec.fingerprint}`);
  G.passes("C2 commit gate with the same staged content", G.scan(sid, repo), "review_docs");
}));
caseEnd();

caseBegin("undecidable merge keeps every path but reports only changed lines", "hooks/workflow-state/glossary-check/scope/artifact.js");
test("C3: undecidable merge keeps every path but reports only changed lines", verdict("C3", () => {
  const repo = F.mkRepo("c3");
  const shared = (tail) => `# Shared\n\nEach ${W} is old.\n\nPlain text${tail}\n`;
  M.commitAll(repo, { "docs/shared.md": shared(".") }, "fixture: merge base");
  M.startMerge(repo, {
    upstream: { "docs/main-only.md": `# Main only\n\nEach ${W} is checked.\n`, "docs/shared.md": shared(" (main).") },
    branch: { "docs/shared.md": shared(" (branch).") },
    resolve: { "docs/shared.md": `${shared(" (resolved).")}\nEach ${W} is new.\n` },
  });
  M.corruptMergeHead(repo);
  const sid = F.seedSession("c3", "docs", { cwd: repo });
  const r = F.drift(sid, "docs", repo, false);
  F.check("C3 docs: the merge-incoming new file is kept whole and only the added line of docs/shared.md is reported",
    r.code === 1 && JSON.stringify(hits(r.out).sort()) === '["docs/main-only.md:3","docs/shared.md:7"]', show(r));
}));
caseEnd();

caseBegin("parseChangedLines reads hunk headers and quoted paths", "hooks/workflow-state/glossary-check/scope/changed-lines.js");
test("C4: parseChangedLines reads hunk headers and quoted paths", verdict("C4", () => {
  const { parseChangedLines } = require(path.join(F.ROOT, "hooks/workflow-state/glossary-check/scope/changed-lines.js"));
  const head = (b) => `diff --git a/${b} b/${b}\nindex 1..2 100644\n--- a/${b}\n+++ b/${b}\n`;
  const TABLE = [
    ["count omitted means one line", `${head("x.md")}@@ -3 +3 @@\n-a\n+b\n`, { "x.md": [3] }],
    ["explicit count", `${head("x.md")}@@ -2,0 +3,2 @@\n+a\n+b\n`, { "x.md": [3, 4] }],
    ["zero count (deletion only)", `${head("x.md")}@@ -4,2 +3,0 @@\n-a\n-b\n`, { "x.md": [] }],
    ["several hunks", `${head("x.md")}@@ -1 +1 @@\n-a\n+b\n@@ -9,0 +10,1 @@\n+c\n`, { "x.md": [1, 10] }],
    ["deleted file has no entry", "diff --git a/x.md b/x.md\ndeleted file mode 100644\n--- a/x.md\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-a\n-b\n", {}],
    ["quoted path with octal UTF-8 and space",
      'diff --git "a/d/\\346\\227\\245 x.md" "b/d/\\346\\227\\245 x.md"\n--- "a/d/\\346\\227\\245 x.md"\n+++ "b/d/\\346\\227\\245 x.md"\n@@ -0,0 +1 @@\n+a\n',
      { [`d/${String.fromCharCode(0x65e5)} x.md`]: [1] }],
    ["quoted path with an escaped quote", 'diff --git "a/q\\"x.md" "b/q\\"x.md"\n--- "a/q\\"x.md"\n+++ "b/q\\"x.md"\n@@ -0,0 +1 @@\n+a\n', { 'q"x.md': [1] }],
    ["a +++ line inside a hunk is content, not a header", `${head("x.md")}@@ -0,0 +1,2 @@\n+++ not a header\n+b\n`, { "x.md": [1, 2] }],
    ["unquoted path with a space and git's trailing tab",
      "diff --git a/docs/my guide.md b/docs/my guide.md\nindex 1..2 100644\n--- a/docs/my guide.md\t\n+++ b/docs/my guide.md\t\n@@ -2 +2 @@\n-a\n+b\n",
      { "docs/my guide.md": [2] }],
  ];
  for (const [name, patch, want] of TABLE) {
    const got = Object.fromEntries(parseChangedLines(patch));
    F.check(`C4 parseChangedLines: ${name}`, JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
  }
}));
caseEnd();

caseBegin("changedLinesOf maps a path with a space and a Japanese path to their changed lines", "hooks/workflow-state/glossary-check/scope/changed-lines.js");
test("C5: changedLinesOf maps a path with a space and a Japanese path to their changed lines", verdict("C5", () => {
  const { spawnSync } = require("node:child_process");
  const { changedLinesOf } = require(path.join(F.ROOT, "hooks/workflow-state/glossary-check/scope/changed-lines.js"));
  const run = (dir, args) => {
    const r = spawnSync("git", ["-C", dir].concat(args), { timeout: 60000 });
    if (r.error || r.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr || r.error}`);
    return r.stdout;
  };
  const repo = F.mkRepo("c5");
  const ja = `docs/${String.fromCharCode(0x7528, 0x8a9e)}.md`; // a Japanese file name, kept out of the source as code points
  M.commitAll(repo, { "docs/my guide.md": "a\nb\nc\n", [ja]: "x\ny\nz\n" }, "fixture: non-ASCII and spaced paths");
  F.stageFile(repo, "docs/my guide.md", "a\nB\nc\n");
  F.stageFile(repo, ja, "x\ny\nz\nw\n");
  const got = Object.fromEntries(changedLinesOf(run, repo));
  const want = { "docs/my guide.md": [2], [ja]: [4] };
  F.check("C5 changedLinesOf: the spaced path -> [2] and the Japanese path -> [4]", JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
}));
caseEnd();
