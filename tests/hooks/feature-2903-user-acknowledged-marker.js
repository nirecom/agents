"use strict";
// tests/hooks/feature-2903-user-acknowledged-marker.js
// Tests: hooks/lib/worktree-notes-sections.js
// Tags: worktree-notes, user-acknowledged, severity, promoted, parser, table-driven, scope:issue-specific, TL1
// #2903: a notes entry carries `<!-- user-acknowledged: true|false -->` after the severity marker and
// before the promoted marker; scanSection reports userAcknowledged / promotedNumber, and
// composeEntryMarkers owns the canonical order. Existing severity / promoted parsing is unchanged.

require("../lib/harness");
const { test } = require("node:test");
const assert = require("node:assert");
const path = require("node:path");

const M = require(path.resolve(__dirname, "..", "..", "hooks", "lib", "worktree-notes-sections.js"));

const SEV = " <!-- severity: high -->";
const ACK = (v) => ` <!-- user-acknowledged: ${v} -->`;
const PRO = (n) => ` <!-- promoted: #${n} -->`;
const scanOne = (line) => M.scanSection(`# Notes\n\n## BugsFound\n${line}\n`, "BugsFound").entries[0];

// want: severity / userAcknowledged / promotedNumber / body; null userAck|promoted means "unchanged field".
const ENTRY_CASES = [
  { name: "no marker", line: "- A", want: { severity: null, userAcknowledged: false, promotedNumber: null, body: "A" } },
  { name: "severity only", line: `- A${SEV}`, want: { severity: "high", userAcknowledged: false, promotedNumber: null, body: "A" } },
  { name: "ack true only", line: `- A${ACK(true)}`, want: { severity: null, userAcknowledged: true, promotedNumber: null, body: "A" } },
  { name: "ack false only", line: `- A${ACK(false)}`, want: { severity: null, userAcknowledged: false, promotedNumber: null, body: "A" } },
  { name: "severity+ack", line: `- A${SEV}${ACK(true)}`, want: { severity: "high", userAcknowledged: true, promotedNumber: null, body: "A" } },
  { name: "severity+promoted", line: `- A${SEV}${PRO(12)}`, want: { severity: "high", userAcknowledged: false, promotedNumber: 12, body: "A" } },
  { name: "ack+promoted", line: `- A${ACK(true)}${PRO(13)}`, want: { severity: null, userAcknowledged: true, promotedNumber: 13, body: "A" } },
  { name: "severity+ack+promoted", line: `- A${SEV}${ACK(true)}${PRO(14)}`, want: { severity: "high", userAcknowledged: true, promotedNumber: 14, body: "A" } },
  { name: "mode A promoted line", line: `- Reg (#60)${PRO(60)}`, want: { severity: null, userAcknowledged: false, promotedNumber: 60, body: "Reg (#60)" } },
  { name: "invalid ack value maybe", line: `- A${ACK("maybe")}`, want: { severity: null, userAcknowledged: false, promotedNumber: null, body: "A" } },
  { name: "invalid ack value TRUE", line: `- A${SEV}${ACK("TRUE")}`, want: { userAcknowledged: false } },
  { name: "wrong order ack before severity (fail-safe)", line: `- A${ACK(true)}${SEV}`, want: { severity: null } },
];

test("scanSection reports severity / userAcknowledged / promotedNumber / body per marker combination", () => {
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

test("USER_ACK_MARKER_RE is exported and matches only a trailing ack marker (optionally before promoted)", () => {
  assert.ok(M.USER_ACK_MARKER_RE instanceof RegExp, "USER_ACK_MARKER_RE exported");
  const cases = [
    { name: "trailing true", line: `- A${ACK(true)}`, want: true },
    { name: "trailing false", line: `- A${SEV}${ACK(false)}`, want: true },
    { name: "followed by promoted", line: `- A${ACK(true)}${PRO(3)}`, want: true },
    { name: "invalid value", line: `- A${ACK("maybe")}`, want: false },
    { name: "absent", line: `- A${SEV}`, want: false },
  ];
  for (const { name, line, want } of cases) assert.strictEqual(M.USER_ACK_MARKER_RE.test(line), want, name);
});

// composeEntryMarkers may return the marker tail with or without its leading space; normalize both.
const lineOf = (tail) => {
  const s = Array.isArray(tail) ? tail.join(" ") : String(tail);
  return s === "" ? "- X" : `- X${s.startsWith(" ") ? "" : " "}${s}`;
};

test("composeEntryMarkers holds the canonical order severity -> user-acknowledged", () => {
  assert.strictEqual(typeof M.composeEntryMarkers, "function", "composeEntryMarkers exported");
  const cases = [
    { name: "high+true", input: { severity: "high", userAcknowledged: true }, want: `- X${SEV}${ACK(true)}` },
    { name: "high+false", input: { severity: "high", userAcknowledged: false }, want: `- X${SEV}${ACK(false)}` },
    { name: "none+true", input: { severity: "none", userAcknowledged: true }, want: `- X${ACK(true)}` },
    { name: "low+false", input: { severity: "low", userAcknowledged: false }, want: `- X${ACK(false)}` },
    { name: "no severity+false", input: { userAcknowledged: false }, want: `- X${ACK(false)}` },
  ];
  for (const { name, input, want } of cases) {
    const line = lineOf(M.composeEntryMarkers(input));
    assert.strictEqual(line, want, name);
    const e = scanOne(line);
    assert.strictEqual(e.severity, input.severity === "high" ? "high" : null, `${name}: round-trip severity`);
    assert.strictEqual(e.userAcknowledged, input.userAcknowledged, `${name}: round-trip userAcknowledged`);
  }
});

test("markEntryPromoted keeps the canonical order after an ack marker", () => {
  const text = `## BugsFound\n- A${SEV}${ACK(true)}\n`;
  const out = M.markEntryPromoted(text, 2, 21);
  assert.strictEqual(out, `## BugsFound\n- A${SEV}${ACK(true)}${PRO(21)}\n`, "promoted appended last");
  const e = M.scanSection(out, "BugsFound").entries[0];
  assert.deepStrictEqual([e.severity, e.userAcknowledged, e.promotedNumber], ["high", true, 21], "re-parse");
});

test("entryBody strips every trailing marker including ack", () => {
  const cases = [
    { name: "all three", raw: `- Body text${SEV}${ACK(false)}${PRO(5)}`, want: "Body text" },
    { name: "ack only", raw: `- Body text${ACK(true)}`, want: "Body text" },
  ];
  for (const { name, raw, want } of cases) assert.strictEqual(M.entryBody(raw), want, name);
});
