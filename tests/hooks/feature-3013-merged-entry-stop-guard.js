"use strict";
// Tests: bin/render-final-report/notes.js, hooks/stop-final-report-guard.js
// Tags: feature-3013, stop-guard, final-report, worktree-notes, notes-merge, lane-a, scope:issue-specific, TL2, pwsh-not-required
// #3013: a Related Tasks line merged by notes.js (`- #N #M #K <title>`) must pass the Stop guard, which
// checks only the headings and leftover `<TOKEN>`s. A pass (rc 0, no block) is also what an early exit
// looks like, so the two controls (a dropped heading, an unfilled token) run on the same fixture and
// must block; only then does the pass count as an inspected pass.
// TL3 gap: a live model re-emitting the merged line verbatim in a real Stop event.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");
const F = require("../lib/worktree-leftover-fixture");
const G = require("../lib/final-report-guard-fixture");

const N = require(F.rel("bin/render-final-report/notes.js"));
const S = require(F.rel("hooks/lib/final-report-schema.js"));

const restoreIsolation = isolate();
const SB = F.makeBase("f3013-");
const TRANSCRIPTS = path.join(SB, "transcripts");
after(() => {
  restoreIsolation();
  fs.rmSync(SB, { recursive: true, force: true });
});

const PRO = (n) => ` <!-- promoted: #${n} -->`;
const ENV = {
  PR_NUMBER: "42", PR_TITLE: "Do it", PR_URL: "https://x/pr/42", PR_STATE: "MERGED", BRANCH: "feature/x",
  WORKTREE_PATH: "C:/wt/x", CREATED_DATE: "2026-11-01", BACKUP_MANIFEST_PATH: "C:/bk/m.json", BRANCH_DELETED: "yes",
};
const OUTCOME = { issues: [{ issueNumber: 7, state: "closed", historyEntry: true, issueClosed: true, sentinelsPosted: true, wipCleared: true }] };
const MERGED_TITLE = "Child task title";
const MERGED_LINE = `- #11 #12 #13 ${MERGED_TITLE}`;

// A Final Report whose Related Tasks come from the real compressNotesSections over three same-body promoted entries.
function mergedReport(sid, relatedOverride) {
  const notes = ["# Worktree Notes", "", "## RelatedTasks",
    `- ${MERGED_TITLE}${PRO(11)}`, `- ${MERGED_TITLE}${PRO(12)}`, `- ${MERGED_TITLE}${PRO(13)}`, ""].join("\n");
  const sections = N.compressNotesSections(notes, { backupPath: "C:/bk/WORKTREE_NOTES.backup.md" });
  return S.renderFinalReport(sid, {
    env: ENV, outcome: OUTCOME, closesIssues: [7], supervisorState: null,
    notesSections: { bugs: sections.BugsFound, related: relatedOverride || sections.RelatedTasks, next: sections.NextTasks },
  });
}

function guard(sid, text) {
  G.writeEnv(sid);
  return G.runGuard(sid, G.writeTranscript(TRANSCRIPTS, sid, text), SB);
}

// Control 1: the same report minus one heading must block, naming that heading.
function dropHeadingControl(sid) {
  const heading = S.getSectionHeadings(sid)[3];
  const report = mergedReport(sid);
  assert.ok(report.split("\n").includes(heading), `fixture: heading present before the drop: ${heading}`);
  const r = guard(sid, report.split("\n").filter((l) => l !== heading).join("\n"));
  assert.strictEqual(r.rc, 2, `control 1 must block (else the fixture hits an early exit): ${r.out}`);
  assert.strictEqual(r.decision, "block");
  assert.ok(r.reason.includes(heading), `the reason must name the dropped heading ${heading}:\n${r.reason}`);
}

// Control 2: the same report plus an unfilled token must block, naming the token.
function leftoverTokenControl(sid) {
  const r = guard(sid, `${mergedReport(sid)}\n<UNFILLED_TOKEN>`);
  assert.strictEqual(r.rc, 2, `control 2 must block (the last check is reached with the merged line in the body): ${r.out}`);
  assert.strictEqual(r.decision, "block");
  assert.ok(r.reason.includes("<UNFILLED_TOKEN>"), `the reason must name the placeholder:\n${r.reason}`);
}

caseBegin("control-dropped-heading-blocks", "hooks/stop-final-report-guard.js");
test("control-dropped-heading-blocks", () => dropHeadingControl("m-ctl-heading"));
caseEnd();

caseBegin("control-unfilled-token-blocks", "hooks/stop-final-report-guard.js");
test("control-unfilled-token-blocks", () => leftoverTokenControl("m-ctl-token"));
caseEnd();

caseBegin("merged-line-report-is-rendered-by-notes", "bin/render-final-report/notes.js");
test("merged-line-report-is-rendered-by-notes", () => {
  const report = mergedReport("m-fixture");
  assert.ok(report.split("\n").includes(MERGED_LINE), `the Related Tasks must hold the merged line:\n${report}`);
  assert.strictEqual(report.split("\n").filter((l) => l.includes(MERGED_TITLE)).length, 1, "the title appears on one line only");
  assert.deepStrictEqual(report.match(/<[A-Z][A-Z0-9_]+>/g), null, "no unsubstituted <TOKEN>");
});
caseEnd();

caseBegin("merged-line-report-passes-the-guard", "hooks/stop-final-report-guard.js");
test("merged-line-report-passes-the-guard", () => {
  dropHeadingControl("m-pass-ctl1");
  leftoverTokenControl("m-pass-ctl2");
  const sid = "m-pass";
  const report = mergedReport(sid);
  assert.ok(report.split("\n").includes(MERGED_LINE), "fixture: the report carries the merged line");
  const r = guard(sid, report);
  assert.strictEqual(r.rc, 0, `a report with a merged line must not block: ${r.out}`);
  assert.notStrictEqual(r.decision, "block");
});
caseEnd();

// The real renderer CLI (the 1886 compression test's TL2 path), fed a notes file of same-body promoted entries.
caseBegin("real-cli-renders-one-merged-related-tasks-line", "bin/render-final-report/notes.js");
test("real-cli-renders-one-merged-related-tasks-line", () => {
  const sid = "m-cli";
  const nums = Array.from({ length: 25 }, (_, i) => 701 + i);
  const notesPath = path.join(SB, "WORKTREE_NOTES.md");
  fs.writeFileSync(notesPath, ["# Worktree Notes", "", "## BugsFound", "- (none)", "", "## RelatedTasks",
    ...nums.map((n) => `- same child task${PRO(n)}`), "", "## NextTasks", "- (none)", ""].join("\n"));
  G.writeControl(sid, "final-report-env.json", Object.assign({}, G.DEFAULT_ENV, { NOTES_BACKUP_PATH: notesPath.replace(/\\/g, "/") }));
  const r = G.runRenderer(sid, SB);
  assert.strictEqual(r.rc, 0, r.err);
  const lines = r.out.split("\n");
  const start = lines.indexOf("### Related Tasks");
  assert.ok(start >= 0, "### Related Tasks heading present");
  const rest = lines.slice(start + 1);
  const end = rest.findIndex((l) => l.startsWith("### "));
  const block = (end < 0 ? rest : rest.slice(0, end)).filter((l) => l.trim() !== "");
  const merged = block.filter((l) => l.startsWith(`- ${nums.slice(0, 3).map((n) => `#${n}`).join(" ")} `));
  assert.strictEqual(merged.length, 1, `exactly one merged line:\n${block.join("\n")}`);
  assert.strictEqual(merged[0], `- ${nums.map((n) => `#${n}`).join(" ")} same child task`);
  assert.ok(block.length <= N.COMPRESSED_LIST_MAX, `the block stays within the list max: ${block.length}`);
});
caseEnd();

caseBegin("guard-does-not-read-the-line-shape","hooks/stop-final-report-guard.js");
test("guard-does-not-read-the-line-shape", () => {
  dropHeadingControl("m-shape-ctl1");
  leftoverTokenControl("m-shape-ctl2");
  const sid = "m-shape";
  const odd = mergedReport(sid, "- free text #99 #98 without the usual head");
  const r = guard(sid, odd);
  assert.strictEqual(r.rc, 0, `the guard checks headings and tokens only, not the notes line shape: ${r.out}`);
  assert.notStrictEqual(r.decision, "block");
});
caseEnd();
