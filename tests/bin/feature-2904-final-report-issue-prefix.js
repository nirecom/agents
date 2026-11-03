"use strict";
// tests/bin/feature-2904-final-report-issue-prefix.js
// Tests: bin/render-final-report/notes.js, hooks/lib/final-report-schema.js
// Tags: final-report, worktree-notes, issue-prefix, schema, table-driven, scope:issue-specific, TL1
// #2904: every notes entry in the Final Report leads with `#N ` (promoted) or `[issue-TBD] `; the
// `compressed:` summary is gone and one backup pointer appears only when something was omitted;
// Merged PR / Worktree / Backup collapse to shorter lines. #2903: userAcknowledged is never shown.

const { caseBegin, caseEnd } = require("../lib/harness");
const { test } = require("node:test");
const assert = require("node:assert");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..", "..");
const N = require(path.join(ROOT, "bin", "render-final-report", "notes.js"));
const S = require(path.join(ROOT, "hooks", "lib", "final-report-schema.js"));

const BK = "C:/bk/WORKTREE_NOTES.backup.md";
const SEV = " <!-- severity: high -->";
const ACK = (v) => ` <!-- user-acknowledged: ${v} -->`;
const PRO = (n) => ` <!-- promoted: #${n} -->`;
const doc = (section, lines) => ["# Worktree Notes", "", `## ${section}`, ...lines, ""].join("\n");
const inSection = (section, lines) => N.compressNotesSections(doc(section, lines), { backupPath: BK })[section];
const bugs = (lines) => inSection("BugsFound", lines);
const pointerLines = (out) => out.split("\n").filter((l) => l.includes("full text: "));

caseBegin("notes: entry head prefix per entry kind", "bin/render-final-report/notes.js");
test("notes: entry head prefix per entry kind", () => {
  const cases = [
    { name: "untagged three", lines: ["- a", "- b", "- c"], want: "- [issue-TBD] a\n- [issue-TBD] b\n- [issue-TBD] c" },
    { name: "high only", lines: [`- boom${SEV}`], want: "- [issue-TBD] boom" },
    { name: "high+ack", lines: [`- boom${SEV}${ACK(true)}`], want: "- [issue-TBD] boom" },
    { name: "ack false untagged", lines: [`- quiet${ACK(false)}`], want: "- [issue-TBD] quiet" },
    { name: "mode A promoted, no duplicate (#N)", lines: [`- Reg (#60)${PRO(60)}`], want: "- #60 Reg" },
    { name: "mode B promoted high", lines: [`- X${SEV}${ACK(true)}${PRO(12)}`], want: "- #12 X" },
    { name: "mode B promoted untagged", lines: [`- Y${ACK(false)}${PRO(13)}`], want: "- #13 Y" },
    { name: "(#N) not matching promoted kept", lines: [`- Foo (#7)${PRO(60)}`], want: "- #60 Foo (#7)" },
    { name: "(#N) without promoted kept", lines: ["- Bar (#7)"], want: "- [issue-TBD] Bar (#7)" },
    { name: "high before rest order kept", lines: ["- low1", `- hi${SEV}`], want: "- [issue-TBD] hi\n- [issue-TBD] low1" },
  ];
  for (const section of N.NOTES_SECTIONS) {
    for (const { name, lines, want } of cases) assert.strictEqual(inSection(section, lines), want, `${section}: ${name}`);
  }
  const specific = [
    { section: "RelatedTasks", name: "mode A promoted", lines: [`- Reg (#60)${PRO(60)}`], want: "- #60 Reg" },
    { section: "NextTasks", name: "mode B promoted", lines: [`- X${ACK(true)}${PRO(12)}`], want: "- #12 X" },
    { section: "NextTasks", name: "unpromoted", lines: ["- a"], want: "- [issue-TBD] a" },
  ];
  for (const { section, name, lines, want } of specific) assert.strictEqual(inSection(section, lines), want, `${section}: ${name}`);
});
caseEnd();

caseBegin("notes: no compressed summary; pointer only when something is omitted", "bin/render-final-report/notes.js");
test("notes: no compressed summary; pointer only when something is omitted", () => {
  const many = Array.from({ length: N.COMPRESSED_LIST_MAX + 2 }, (_, i) => `- e${i}`);
  const cases = [
    { name: "plain entries", lines: ["- a", "- b"], pointer: false },
    { name: "high verbatim long", lines: [`- ${"h".repeat(200)}${SEV}`], pointer: false },
    { name: "long title truncated", lines: [`- ${"t".repeat(200)}`], pointer: true },
    { name: "multi-line body (stray continuation)", lines: ["- a", "  continued"], pointer: true },
    { name: "over list max", lines: many, pointer: true },
    { name: "cut at sub-heading", lines: ["- a", "### Sub", "- hidden"], pointer: true },
  ];
  for (const { name, lines, pointer } of cases) {
    const out = bugs(lines);
    assert.ok(!out.includes("compressed:"), `${name}: no compressed: summary`);
    const ptr = pointerLines(out);
    assert.strictEqual(ptr.length, pointer ? 1 : 0, `${name}: pointer line count`);
    if (pointer) {
      assert.ok(ptr[0].startsWith("- ("), `${name}: pointer shape`);
      assert.ok(ptr[0].includes(`full text: ${BK}`), `${name}: pointer names the backup`);
    }
  }
});
caseEnd();

caseBegin("notes: truncated title keeps the prefix and stays bounded", "bin/render-final-report/notes.js");
test("notes: truncated title keeps the prefix and stays bounded", () => {
  const cases = [
    { name: "unpromoted", line: `- ${"t".repeat(300)}`, head: "- [issue-TBD] " },
    { name: "promoted", line: `- ${"p".repeat(300)}${PRO(77)}`, head: "- #77 " },
  ];
  for (const { name, line, head } of cases) {
    const first = bugs([line]).split("\n")[0];
    assert.ok(first.startsWith(head), `${name}: prefix`);
    assert.ok(first.endsWith("…"), `${name}: truncation mark`);
    assert.ok(Array.from(first).length <= N.TITLE_MAX_CHARS + 20, `${name}: bounded length ${first.length}`);
  }
});
caseEnd();

caseBegin("notes: userAcknowledged is never displayed", "bin/render-final-report/notes.js");
test("notes: userAcknowledged is never displayed", () => {
  const cases = [
    { name: "true", lines: [`- a${ACK(true)}`, `- b${SEV}${ACK(true)}`] },
    { name: "false", lines: [`- a${ACK(false)}`, `- b${SEV}${ACK(false)}${PRO(4)}`] },
  ];
  for (const { name, lines } of cases) assert.ok(!/acknowledged/i.test(bugs(lines)), `${name}: no ack text`);
});
caseEnd();

const ENV = {
  PR_NUMBER: "42", PR_TITLE: "Do it", PR_URL: "https://x/pr/42", PR_STATE: "MERGED", BRANCH: "feature/x",
  WORKTREE_PATH: "C:/wt/x", CREATED_DATE: "2026-11-01", BACKUP_MANIFEST_PATH: "C:/bk/m.json", BRANCH_DELETED: "yes",
};
const OUTCOME = { issues: [{ issueNumber: 7, state: "closed", historyEntry: true, issueClosed: true, sentinelsPosted: true, wipCleared: true }] };
const render = (extra) => S.renderFinalReport("sid2904", Object.assign({
  env: ENV, outcome: OUTCOME, closesIssues: [7], supervisorState: null,
  notesSections: { bugs: "- [issue-TBD] b", related: "- #9 r", next: "(none)" },
}, extra || {}));

caseBegin("schema: shortened Merged PR / Worktree / Backup lines", "hooks/lib/final-report-schema.js");
test("schema: shortened Merged PR / Worktree / Backup lines", () => {
  const out = render();
  const cases = [
    { name: "merged pr line", want: "- PR #42: Do it (MERGED)", present: true },
    { name: "url line", want: "- URL: https://x/pr/42", present: true },
    { name: "branch line", want: "- Branch: feature/x (C:/wt/x)", present: true },
    { name: "created line", want: "- Created: 2026-11-01", present: true },
    { name: "backup line", want: "- Manifest: C:/bk/m.json / branches deleted: yes", present: true },
    { name: "no State line", want: "- State: MERGED", present: false },
    { name: "no Path line", want: "- Path: C:/wt/x", present: false },
    { name: "no Removed line", want: "- Removed: ✓", present: false },
    { name: "no Branches deleted line", want: "- Branches deleted: yes", present: false },
    { name: "outcome line not shortened (A-2)", want: "- #7: closed (history: true, closed: true, sentinels: true, wip: true)", present: true },
  ];
  const lines = out.split("\n");
  for (const { name, want, present } of cases) assert.strictEqual(lines.includes(want), present, name);
});
caseEnd();

caseBegin("schema: 13 headings kept and no token left", "hooks/lib/final-report-schema.js");
test("schema: 13 headings kept and no token left", () => {
  const out = render();
  const headings = S.getSectionHeadings("sid2904");
  assert.strictEqual(headings.length, 13, "13 headings");
  for (const h of headings) assert.ok(out.split("\n").includes(h), `heading present: ${h}`);
  assert.deepStrictEqual(out.match(/<[A-Z][A-Z0-9_]+>/g), null, "no unsubstituted <TOKEN>");
});
caseEnd();

caseBegin("schema: renderLines agree with the skeleton placeholders", "hooks/lib/final-report-schema.js");
test("schema: renderLines agree with the skeleton placeholders", () => {
  const skel = S.renderSkeleton("sid2904");
  const ctx = { safeEnv: (k) => `<${k}>` };
  for (const id of ["merged_pr", "worktree", "backup"]) {
    const sec = S.SECTIONS.find((s) => s.id === id);
    const want = `${sec.heading("sid2904")}\n${sec.renderLines({}, "sid2904", ctx).join("\n")}\n`;
    assert.ok(skel.includes(want), `${id}: skeleton block equals renderLines with tokens`);
  }
});
caseEnd();

caseBegin("schema: runTestsNote goes right after the URL line", "hooks/lib/final-report-schema.js");
test("schema: runTestsNote goes right after the URL line", () => {
  const cases = [
    { name: "plain note", note: "- Unverified tests: x", want: "- Unverified tests: x" },
    { name: "token escaped", note: "- Unverified tests: <FOO>", want: "- Unverified tests: &lt;FOO&gt;" },
  ];
  for (const { name, note, want } of cases) {
    const lines = render({ runTestsNote: note }).split("\n");
    const i = lines.indexOf("- URL: https://x/pr/42");
    assert.ok(i >= 0, `${name}: URL line present`);
    assert.strictEqual(lines[i + 1], want, `${name}: note follows URL`);
  }
});
caseEnd();
