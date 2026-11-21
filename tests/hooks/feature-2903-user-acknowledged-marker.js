"use strict";
// tests/hooks/feature-2903-user-acknowledged-marker.js
// Tests: hooks/lib/worktree-notes-sections.js
// Tags: worktree-notes, user-acknowledged, severity, promoted, parser, legacy-format, table-driven, scope:issue-specific, TL1
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
