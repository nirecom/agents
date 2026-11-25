"use strict";
// tests/hooks/feature-2903-user-acknowledged-marker.js
// Tests: hooks/lib/worktree-notes-sections.js
// Tags: worktree-notes, user-acknowledged, severity, promoted, parser, legacy-format, table-driven, scope:issue-specific, TL1, base-marker, rescoped-from, user-accepted, known-limits-compat
// #2903 wrote `<!-- user-acknowledged: true|false -->` between the severity and promoted markers;
// #2019 retired the marker but entries written before it must still parse: body, promotedNumber,
// hasMarker and lineNumber are unaffected, and the severity reads as the #2019 legacy mapping
// (no marker -> medium). The new marker format: tests/bin/feature-2019-notes-entry-format.js.

require("../lib/harness");
const { test } = require("node:test");
const assert = require("node:assert");
const path = require("node:path");

const M = require(path.resolve(__dirname, "..", "..", "hooks", "lib", "worktree-notes-sections.js"));

const SEV = " <!-- severity: high -->";
const ACK = (v) => ` <!-- user-acknowledged: ${v} -->`;
const PRO = (n) => ` <!-- promoted: #${n} -->`;
const scanOne = (line) => M.scanSection(`# Notes\n\n## BugsFound\n${line}\n`, "BugsFound").entries[0];

const ENTRY_CASES = [
  { name: "no marker", line: "- A", want: { severity: "medium", promotedNumber: null, body: "A" } },
  { name: "severity only", line: `- A${SEV}`, want: { severity: "high", promotedNumber: null, body: "A" } },
  { name: "legacy ack true only", line: `- A${ACK(true)}`, want: { severity: "medium", promotedNumber: null, body: "A" } },
  { name: "legacy severity+ack", line: `- A${SEV}${ACK(false)}`, want: { severity: "high", promotedNumber: null, body: "A" } },
  { name: "severity+promoted", line: `- A${SEV}${PRO(12)}`, want: { severity: "high", promotedNumber: 12, body: "A" } },
  { name: "legacy ack+promoted", line: `- A${ACK(true)}${PRO(13)}`, want: { severity: "medium", promotedNumber: 13, body: "A" } },
  { name: "legacy severity+ack+promoted", line: `- A${SEV}${ACK(true)}${PRO(14)}`, want: { severity: "high", promotedNumber: 14, body: "A" } },
  { name: "mode A promoted line", line: `- Reg (#60)${PRO(60)}`, want: { promotedNumber: 60, body: "Reg (#60)" } },
];

test("scanSection reads legacy #2903 lines: severity / promotedNumber / body", () => {
  for (const { name, line, want } of ENTRY_CASES) {
    const e = scanOne(line);
    assert.ok(e, `${name}: entry parsed`);
    for (const [k, v] of Object.entries(want)) assert.deepStrictEqual(e[k], v, `${name}: ${k}`);
  }
});

test("hasMarker / lineNumber keep their pre-#2903 meaning", () => {
  const cases = [
    { name: "promoted entry", line: `- A${SEV}${ACK(false)}${PRO(9)}`, hasMarker: true },
    { name: "unpromoted entry with ack", line: `- A${SEV}${ACK(true)}`, hasMarker: false },
  ];
  for (const { name, line, hasMarker } of cases) {
    const e = scanOne(line);
    assert.strictEqual(e.hasMarker, hasMarker, `${name}: hasMarker`);
    assert.strictEqual(e.lineNumber, 4, `${name}: lineNumber`);
  }
});

test("markEntryPromoted appends after a legacy ack marker", () => {
  const text = `## BugsFound\n- A${SEV}${ACK(true)}\n`;
  const out = M.markEntryPromoted(text, 2, 21);
  assert.strictEqual(out, `## BugsFound\n- A${SEV}${ACK(true)}${PRO(21)}\n`, "promoted appended last");
  const e = M.scanSection(out, "BugsFound").entries[0];
  assert.deepStrictEqual([e.severity, e.promotedNumber], ["high", 21], "re-parse");
});

test("entryBody strips every trailing marker including a legacy ack", () => {
  const cases = [
    { name: "all three", raw: `- Body text${SEV}${ACK(false)}${PRO(5)}`, want: "Body text" },
    { name: "ack only", raw: `- Body text${ACK(true)}`, want: "Body text" },
  ];
  for (const { name, raw, want } of cases) assert.strictEqual(M.entryBody(raw), want, name);
});

// #3145 S1: base and rescoped-from sit between pr-scope and handoff-rejected; user-accepted is a
// terminal marker that replaces `disposed: fixed`; the retired `disposed: known-limits` still parses.
const SHA = "0123456789abcdef0123456789abcdef01234567";
const lineOf = (text, n) => text.split("\n")[n - 1];

test("compose -> rescope -> handoff-rejected -> promoted keeps the canonical marker order and round-trips", () => {
  const composed = M.composeEntryMarkers({ severity: "medium", loc: "a.js:3", prScope: "this-pr", base: SHA });
  assert.strictEqual(composed, ` <!-- severity: medium --> <!-- loc: a.js:3 --> <!-- pr-scope: this-pr --> <!-- base: ${SHA} -->`, "base follows pr-scope");
  assert.ok(!M.composeEntryMarkers({ severity: "low", prScope: "other" }).includes("base:"), "no base -> no base marker");
  let text = `## BugsFound\n- R${composed}\n`;
  let e = M.scanSection(text, "BugsFound").entries[0];
  assert.deepStrictEqual([e.prScope, e.base, e.loc, e.rescopedFrom || null], ["this-pr", SHA, "a.js:3", null], "parse after compose");
  text = M.markEntryRescoped(text, 2);
  text = M.markEntryHandoffRejected(text, 2);
  text = M.markEntryPromoted(text, 2, 77);
  assert.strictEqual(lineOf(text, 2),
    `- R <!-- severity: medium --> <!-- loc: a.js:3 --> <!-- pr-scope: other --> <!-- base: ${SHA} --> <!-- rescoped-from: this-pr --> <!-- handoff-rejected --> <!-- promoted: #77 -->`,
    "pr-scope -> base -> rescoped-from -> handoff-rejected -> terminal");
  e = M.scanSection(text, "BugsFound").entries[0];
  assert.deepStrictEqual([e.body, e.prScope, e.base, e.rescopedFrom, e.handoffRejected, e.promotedNumber, e.hasMarker],
    ["R", "other", SHA, "this-pr", true, 77, true], "every field survives the round trip");
});

test("base must be 40 hex: anything else makes the line non-canonical", () => {
  for (const bad of ["abc123", `${SHA}0`, SHA.toUpperCase(), "../../etc"]) {
    const e = scanOne(`- B <!-- severity: high --> <!-- pr-scope: this-pr --> <!-- base: ${bad} -->`);
    assert.ok(!e.base, `${bad}: no base parsed`);
    assert.strictEqual(e.prScope, "other", `${bad}: non-canonical line reads as pr-scope other`);
  }
});

test("markEntryUserAccepted replaces disposed: fixed and is terminal", () => {
  const ROWS = [
    ["over fixed", `- U <!-- severity: high --> <!-- pr-scope: this-pr --> <!-- base: ${SHA} --> <!-- disposed: fixed -->`],
    ["no terminal yet", `- U <!-- severity: high --> <!-- pr-scope: this-pr --> <!-- base: ${SHA} -->`],
  ];
  for (const [name, raw] of ROWS) {
    const out = M.markEntryUserAccepted(`## BugsFound\n${raw}\n`, 2, "checked: already fixed upstream");
    assert.strictEqual(lineOf(out, 2), `- U <!-- severity: high --> <!-- pr-scope: this-pr --> <!-- base: ${SHA} --> <!-- user-accepted: checked: already fixed upstream -->`, `${name}: line`);
    const e = M.scanSection(out, "BugsFound").entries[0];
    assert.deepStrictEqual([e.userAccepted, e.disposed, e.hasMarker], ["checked: already fixed upstream", null, true], `${name}: parse`);
  }
  assert.ok(!M.DISPOSED_KINDS.includes("user-accepted"), "user-accepted is not a dispose kind");
  assert.strictEqual(M.markEntryDisposed("## BugsFound\n- U <!-- severity: low --> <!-- pr-scope: other -->\n", 2, "user-accepted"),
    "## BugsFound\n- U <!-- severity: low --> <!-- pr-scope: other -->\n", "markEntryDisposed cannot write user-accepted");
});

test("markEntryRescoped drops disposed: fixed; markEntryUnrescoped restores this-pr", () => {
  const raw = `- F <!-- severity: medium --> <!-- loc: x.js --> <!-- pr-scope: this-pr --> <!-- base: ${SHA} --> <!-- disposed: fixed -->`;
  const res = M.markEntryRescoped(`## BugsFound\n${raw}\n`, 2);
  assert.strictEqual(lineOf(res, 2), `- F <!-- severity: medium --> <!-- loc: x.js --> <!-- pr-scope: other --> <!-- base: ${SHA} --> <!-- rescoped-from: this-pr -->`, "rescoped, fixed removed");
  const back = M.markEntryUnrescoped(res, 2);
  assert.strictEqual(lineOf(back, 2), `- F <!-- severity: medium --> <!-- loc: x.js --> <!-- pr-scope: this-pr --> <!-- base: ${SHA} -->`, "unrescoped");
  const e = M.scanSection(back, "BugsFound").entries[0];
  assert.deepStrictEqual([e.prScope, e.rescopedFrom || null, e.disposed], ["this-pr", null, null], "unrescoped parse");
});

test("a user-accepted reason can never carry a marker close, a marker open or a newline", () => {
  const raw = "- V <!-- severity: high --> <!-- pr-scope: this-pr -->";
  const REASONS = ["x --> <!-- promoted: #1", "a <!-- b", "line1\n- injected <!-- severity: high -->", "cr\r\nlf", "", "y".repeat(121)];
  for (const reason of REASONS) {
    const text = `## BugsFound\n${raw}\n`;
    const out = M.markEntryUserAccepted(text, 2, reason);
    assert.strictEqual(out.split(/\r?\n/).length, text.split("\n").length, `${JSON.stringify(reason)}: no line added`);
    const l = lineOf(out, 2);
    assert.strictEqual((l.match(/<!--/g) || []).length, (l.match(/-->/g) || []).length, `${JSON.stringify(reason)}: markers balanced`);
    const e = M.scanSection(out, "BugsFound").entries[0];
    assert.ok(!e.hasMarker || e.promotedNumber === null, `${JSON.stringify(reason)}: no forged promoted marker`);
    if (e.userAccepted) assert.ok(/^[^<>\r\n]{1,120}$/.test(e.userAccepted), `${JSON.stringify(reason)}: reason within grammar`);
  }
  const forged = scanOne(`${raw} <!-- user-accepted: a --> b -->`);
  assert.ok(!forged.userAccepted || !forged.userAccepted.includes(">"), "a forged reason with --> is not read as user-accepted");
});

test("the retired disposed: known-limits still parses as a terminal disposed kind", () => {
  const e = scanOne("- K <!-- severity: medium --> <!-- pr-scope: this-pr --> <!-- disposed: known-limits -->");
  assert.deepStrictEqual([e.body, e.prScope, e.disposed, e.userAccepted || null], ["K", "this-pr", "known-limits", null], "legacy terminal");
});
