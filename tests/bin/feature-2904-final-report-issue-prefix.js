"use strict";
// tests/bin/feature-2904-final-report-issue-prefix.js
// Tests: bin/render-final-report/notes.js, hooks/lib/final-report-schema.js
// Tags: final-report, worktree-notes, issue-prefix, schema, table-driven, scope:issue-specific, TL1, notes-merge
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

// #3013: promoted entries with an identical displayed body fold into one `#N #M ` line, in all 3 sections.
caseBegin("notes: same-body promoted entries merge into one line", "bin/render-final-report/notes.js");
test("notes: same-body promoted entries merge into one line", () => {
  const long = (tail) => `${"x".repeat(130)}${tail}`;
  const cases = [
    { name: "three merge, interleaved entry keeps its place", lines: [`- T${PRO(11)}`, `- O${PRO(20)}`, `- T${PRO(12)}`, `- T${PRO(13)}`], want: "- #11 #12 #13 T\n- #20 O" },
    { name: "numbers follow appearance order", lines: [`- T${PRO(13)}`, `- T${PRO(11)}`, `- T${PRO(12)}`], want: "- #13 #11 #12 T" },
    { name: "mode A and mode B merge after (#N) removal", lines: [`- T (#11)${PRO(11)}`, `- T${PRO(12)}`], want: "- #11 #12 T" },
    { name: "differ before truncation, equal after: not merged", lines: [`- ${long("a")}${PRO(31)}`, `- ${long("b")}${PRO(32)}`], wantLines: ["- #31 ", "- #32 "] },
    { name: "[issue-TBD] same body: not merged", lines: ["- T", "- T"], want: "- [issue-TBD] T\n- [issue-TBD] T" },
    { name: "promoted and unpromoted same body: not merged", lines: ["- T", `- T${PRO(1)}`], want: "- [issue-TBD] T\n- #1 T" },
    { name: "severity high stays verbatim, first", lines: [`- H${SEV}${PRO(41)}`, `- H${SEV}${PRO(42)}`, `- T${PRO(43)}`, `- T${PRO(44)}`], want: "- #41 H\n- #42 H\n- #43 #44 T" },
    { name: "severity high long identical body stays verbatim, not merged, not truncated", lines: [`- ${long("h")}${SEV}${PRO(61)}`, `- ${long("h")}${SEV}${PRO(62)}`], wantContains: long("h"), want: `- #61 ${long("h")}\n- #62 ${long("h")}` },
    { name: "duplicate number appears once", lines: [`- T${PRO(11)}`, `- T${PRO(11)}`, `- T${PRO(12)}`], want: "- #11 #12 T" },
    { name: "token in a merged body is escaped", lines: [`- <FOO_BAR> x${PRO(51)}`, `- <FOO_BAR> x${PRO(52)}`], want: "- #51 #52 &lt;FOO_BAR&gt; x" },
  ];
  for (const section of N.NOTES_SECTIONS) {
    for (const { name, lines, want, wantLines, wantContains } of cases) {
      const out = inSection(section, lines);
      if (wantContains) {
        const got = out.split("\n").filter((l) => l.startsWith("- #"));
        assert.strictEqual(got.length, 2, `${section}: ${name}: two separate lines`);
        got.forEach((l, i) => assert.ok(l.includes(wantContains), `${section}: ${name}: line ${i} holds the full body`));
      } else if (wantLines) {
        const got = out.split("\n");
        assert.strictEqual(got.length, wantLines.length + (pointerLines(out).length), `${section}: ${name}: line count`);
        wantLines.forEach((head, i) => assert.ok(got[i].startsWith(head), `${section}: ${name}: line ${i} head`));
      } else {
        assert.strictEqual(out, want, `${section}: ${name}`);
      }
    }
  }
});
caseEnd();

caseBegin("notes: a merged line is not split and counts as one toward the list max", "bin/render-final-report/notes.js");
test("notes: a merged line is not split and counts as one toward the list max", () => {
  const same = (n, first) => Array.from({ length: n }, (_, i) => `- S${PRO(first + i)}`);
  const nums25 = Array.from({ length: 25 }, (_, i) => `#${100 + i}`).join(" ");
  for (const section of N.NOTES_SECTIONS) {
    assert.strictEqual(inSection(section, same(25, 100)), `- ${nums25} S`, `${section}: 25 numbers on one line`);
    const distinct = Array.from({ length: 15 }, (_, i) => `- D${i}${PRO(200 + i)}`);
    const out = inSection(section, distinct);
    assert.strictEqual(out.split("\n").length, N.COMPRESSED_LIST_MAX + 1, `${section}: 10 lines + pointer`);
    assert.ok(pointerLines(out)[0].includes("5 not listed above"), `${section}: 5 not listed above`);
    const groups = [...same(30, 300), ...Array.from({ length: 30 }, (_, i) => `- U${PRO(400 + i)}`), ...Array.from({ length: 30 }, (_, i) => `- V${PRO(500 + i)}`)];
    const merged = inSection(section, groups);
    assert.strictEqual(merged.split("\n").length, 3, `${section}: three groups are three lines`);
    assert.strictEqual(pointerLines(merged).length, 0, `${section}: no pointer when nothing is omitted`);
  }
});
caseEnd();
