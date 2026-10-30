#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/state-handoff-record.js, hooks/lib/state-handoff-record/read.js, hooks/lib/state-handoff-record/render-resume.js, hooks/lib/state-handoff-record/legacy-handoff-md.js
// Tags: TL2, state-handoff-record, state-handoff-reader, handoff, resume, sanitize, migration, regression-2652, scope:issue-specific, pwsh-not-required
// #2652 state handoff reader readStateHandoff(sid) -> {entries, errors} and renderStateHandoffForResume (detail plan S3-1, S3-2, S3-4).
// Assumed entry fields: at, cls, origin, at_step, record_key, summary, pointer (a legacy line's step/key map to at_step/record_key).

// # TL3 gap
// - Hook-written state read by a live `/resume-session --from`; every fixture here is written directly.
// - An unreadable legacy handoff.md needs chmod 000 to deny reads; R12 skips where it does not (win32).

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
const fs = require("node:fs");
const path = require("node:path");

const restore = isolate();
process.on("exit", () => restore());

const fx = require("../lib/state-handoff-record-fixture");
const BARREL = path.join(fx.REPO, "hooks", "lib", "state-handoff-record");

function api() {
  return require(BARREL);
}
// read(sid) — the reader's answer, checked for its shape before any case looks inside.
function read(sid) {
  const out = api().readStateHandoff(sid);
  assert.ok(out && Array.isArray(out.entries) && Array.isArray(out.errors), `readStateHandoff shape: ${JSON.stringify(out)}`);
  return out;
}
const summaries = (out) => out.entries.map((e) => e.summary);

caseBegin("state-records-only", "hooks/lib/state-handoff-record/read.js");
{
  const sid = "r2652-state-only";
  fx.makeState(sid);
  fx.pushEvents(sid, [
    fx.record({ at: fx.isoAt(2), record_key: "k-two", summary: "S-ONLY-TWO" }),
    fx.record({ at: fx.isoAt(1), record_key: "k-one", summary: "S-ONLY-ONE", cls: "A", origin: "procedure-point", at_step: "-" }),
  ]);
  test("R1: a session with only state handoff records returns them in time order with no error", () => {
    const out = read(sid);
    assert.deepStrictEqual(summaries(out), ["S-ONLY-ONE", "S-ONLY-TWO"]);
    assert.deepStrictEqual(out.errors, []);
  });
  test("R1: an entry carries cls, origin, at_step, record_key and at from its event", () => {
    const e = read(sid).entries.find((x) => x.summary === "S-ONLY-ONE");
    assert.deepStrictEqual([e.cls, e.origin, e.at_step, e.record_key, e.at], ["A", "procedure-point", "-", "k-one", fx.isoAt(1)]);
  });
}
caseEnd();

caseBegin("legacy-handoff-md-only", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  const noState = "r2652-legacy-nostate";
  fx.writeLegacyHandoff(noState, [
    { cls: "C", at: fx.isoAt(5), origin: "gate-block", step: "write_code", key: "gate:block", summary: "L-NOSTATE-C" },
    { cls: "A", at: fx.isoAt(4), step: "-", key: "a-key", summary: "L-NOSTATE-A" },
  ]);
  test("R2: no state file, only a legacy handoff.md — its entries come back in time order", () => {
    assert.strictEqual(fs.existsSync(fx.statePath(noState)), false, "fixture: no state file");
    const out = read(noState);
    assert.deepStrictEqual(summaries(out), ["L-NOSTATE-A", "L-NOSTATE-C"]);
    assert.deepStrictEqual(out.errors, []);
  });
  test("R2: a legacy line's step and key read back as at_step and record_key", () => {
    const e = read(noState).entries.find((x) => x.summary === "L-NOSTATE-C");
    assert.deepStrictEqual([e.cls, e.origin, e.at_step, e.record_key, e.at], ["C", "gate-block", "write_code", "gate:block", fx.isoAt(5)]);
  });
  const withState = "r2652-legacy-withstate";
  fx.makeState(withState);
  fx.writeLegacyHandoff(withState, [{ cls: "B", at: fx.isoAt(6), step: "-", key: "b-key", summary: "L-WITHSTATE-B" }]);
  test("R3: a state file without records does not stop the legacy handoff.md from being read", () => {
    assert.deepStrictEqual(summaries(read(withState)), ["L-WITHSTATE-B"]);
  });
}
caseEnd();

caseBegin("state-and-legacy-merged", "hooks/lib/state-handoff-record/read.js");
{
  const sid = "r2652-both";
  fx.makeState(sid);
  fx.pushEvents(sid, [
    fx.record({ at: fx.isoAt(11), record_key: "s-1", summary: "BOTH-S11" }),
    fx.record({ at: fx.isoAt(13), record_key: "s-2", summary: "BOTH-S13" }),
  ]);
  fx.writeLegacyHandoff(sid, [
    { cls: "A", at: fx.isoAt(10), step: "-", key: "l-1", summary: "BOTH-L10" },
    { cls: "D", at: fx.isoAt(12), step: "-", key: "l-2", summary: "BOTH-L12" },
  ]);
  test("R4: state records and legacy entries interleave by time", () => {
    const out = read(sid);
    assert.deepStrictEqual(summaries(out), ["BOTH-L10", "BOTH-S11", "BOTH-L12", "BOTH-S13"]);
    assert.deepStrictEqual(out.errors, []);
  });
}
caseEnd();

caseBegin("nothing-recorded-is-empty", "hooks/lib/state-handoff-record/read.js");
{
  test("R5: no state file and no legacy handoff.md — empty entries, no error", () => {
    const out = read("r2652-nothing");
    assert.deepStrictEqual([out.entries, out.errors], [[], []]);
  });
  const sid = "r2652-state-no-records";
  fx.makeState(sid);
  test("R5: a state file with no record and no reset — empty entries, no error", () => {
    const out = read(sid);
    assert.deepStrictEqual([out.entries, out.errors], [[], []]);
  });
}
caseEnd();

caseBegin("reset-event-is-an-entry", "hooks/lib/state-handoff-record/read.js");
{
  const sid = "r2652-reset";
  fx.makeState(sid);
  fx.pushEvents(sid, [fx.resetEvent({ at: fx.isoAt(20), from_step: "write_tests", reason: "RESET-REASON-MARK" })]);
  test("R6: a reset event becomes one class E reset-from entry naming from_step and reason", () => {
    const out = read(sid);
    assert.strictEqual(out.entries.length, 1, "entry count");
    const e = out.entries[0];
    assert.deepStrictEqual([e.cls, e.record_key], ["E", "reset-from"]);
    assert.match(e.summary, /write_tests/);
    assert.match(e.summary, /RESET-REASON-MARK/);
  });
}
caseEnd();

caseBegin("reset-not-doubled-by-legacy", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  // Before #2652 a RESET went to both the reset event and handoff.md; the event is the SSOT.
  const sid = "r2652-reset-both";
  fx.makeState(sid);
  fx.pushEvents(sid, [fx.resetEvent({ at: fx.isoAt(30), from_step: "write_code", reason: "DUP-RESET" })]);
  fx.writeLegacyHandoff(sid, [
    { cls: "E", at: fx.isoAt(30), origin: "auto-record", step: "write_code", key: "reset-from", summary: "write_code: DUP-RESET" },
    { cls: "A", at: fx.isoAt(31), step: "-", key: "kept", summary: "LEGACY-KEPT" },
  ]);
  test("R7: the same RESET in the state file and the legacy handoff.md yields one reset-from entry", () => {
    const out = read(sid);
    assert.strictEqual(out.entries.filter((e) => e.record_key === "reset-from").length, 1, "reset-from count");
    assert.ok(summaries(out).includes("LEGACY-KEPT"), "other legacy entry kept");
  });
  const legacyOnly = "r2652-reset-legacy-only";
  fx.writeLegacyHandoff(legacyOnly, [
    { cls: "E", at: fx.isoAt(32), origin: "auto-record", step: "write_code", key: "reset-from", summary: "LEGACY-ONLY-RESET" },
  ]);
  test("R8: with no state file the legacy reset-from entry is the only source and stays", () => {
    assert.deepStrictEqual(summaries(read(legacyOnly)), ["LEGACY-ONLY-RESET"]);
  });
}
caseEnd();

caseBegin("copy-boundary-excludes-upstream", "hooks/lib/state-handoff-record/read.js");
{
  const sid = "r2652-boundary";
  fx.makeState(sid);
  const boundary = fx.pushEvents(sid, [
    fx.record({ at: fx.isoAt(40), record_key: "up-1", summary: "BEFORE-BOUNDARY-1" }),
    fx.record({ at: fx.isoAt(41), record_key: "up-2", summary: "BEFORE-BOUNDARY-2" }),
  ]);
  fx.setTopLevel(sid, { upstream_session_id: "r2652-boundary-upstream", upstream_copy_seq: boundary });
  fx.pushEvents(sid, [fx.record({ at: fx.isoAt(42), record_key: "own", summary: "AFTER-BOUNDARY" })]);
  test("R9: records at or before upstream_copy_seq are not this session's and are left out", () => {
    assert.deepStrictEqual(summaries(read(sid)), ["AFTER-BOUNDARY"]);
  });
}
caseEnd();

caseBegin("same-key-not-folded", "hooks/lib/state-handoff-record/read.js");
{
  const sid = "r2652-same-key";
  fx.makeState(sid);
  fx.pushEvents(sid, [1, 2, 3].map((n) => fx.record({ at: fx.isoAt(50 + n), record_key: "gate:block", summary: `FOLD-${n}` })));
  test("R10: three records with the same (at_step, record_key) all come back", () => {
    assert.deepStrictEqual(summaries(read(sid)), ["FOLD-1", "FOLD-2", "FOLD-3"]);
  });
}
caseEnd();

caseBegin("unreadable-source-is-an-error", "hooks/lib/state-handoff-record/read.js");
{
  const sid = "r2652-broken-state";
  fx.writeLegacyHandoff(sid, [{ cls: "A", at: fx.isoAt(60), step: "-", key: "k", summary: "READABLE-LEGACY" }]);
  fs.writeFileSync(fx.statePath(sid), "{ not json", "utf8");
  test("R11: a corrupt state file names \"state\" in errors and the legacy entries still come back", () => {
    const out = read(sid);
    assert.deepStrictEqual(out.errors, ["state"]);
    assert.deepStrictEqual(summaries(out), ["READABLE-LEGACY"]);
  });
  const lsid = "r2652-unreadable-legacy";
  fx.makeState(lsid);
  fx.pushEvents(lsid, [fx.record({ at: fx.isoAt(61), summary: "READABLE-STATE" })]);
  const file = fx.writeLegacyHandoff(lsid, [{ cls: "A", at: fx.isoAt(62), step: "-", key: "k", summary: "HIDDEN" }]);
  test("R12: an unreadable legacy handoff.md names \"legacy-handoff-md\" in errors and state entries still come back", (t) => {
    fs.chmodSync(file, 0o000);
    try {
      let denied = true;
      try {
        fs.readFileSync(file);
        denied = false;
      } catch (e) {
        denied = true;
      }
      if (!denied) {
        t.skip("chmod 000 does not deny reads on this host");
        return;
      }
      const out = read(lsid);
      assert.deepStrictEqual(out.errors, ["legacy-handoff-md"]);
      assert.deepStrictEqual(summaries(out), ["READABLE-STATE"]);
    } finally {
      fs.chmodSync(file, 0o600);
    }
  });
}
caseEnd();

caseBegin("never-throws", "hooks/lib/state-handoff-record/read.js");
{
  for (const bad of ["../x", "a/b", "", null, undefined, 7]) {
    test(`R13: readStateHandoff(${JSON.stringify(bad)}) returns empty entries without throwing`, () => {
      assert.deepStrictEqual(read(bad).entries, []);
    });
  }
}
caseEnd();

caseBegin("legacy-parser-escapes-and-broken-lines", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  // The retired writer escaped \ | CR LF inside a field; the parser undoes that, and the read-side
  // sanitize then turns the restored line break into a space.
  const sid = "r2652-legacy-escapes";
  fx.writeLegacyHandoff(sid, [
    { cls: "A", at: fx.isoAt(80), step: "-", key: "esc-pipe", summary: "ESC pipe | inside", pointer: "p|q" },
    { cls: "A", at: fx.isoAt(81), step: "-", key: "esc-back", summary: "ESC C:\\dir\\file tail\\", pointer: "-" },
    { cls: "A", at: fx.isoAt(82), step: "-", key: "esc-nl", summary: "ESC line one\nline two", pointer: "-" },
  ]);
  test("R18: escaped pipe, backslash and line break in a legacy field read back as the original text", () => {
    const out = read(sid);
    assert.deepStrictEqual(out.entries.map((e) => [e.record_key, e.summary]), [
      ["esc-pipe", "ESC pipe | inside"],
      ["esc-back", "ESC C:\\dir\\file tail\\"],
      ["esc-nl", "ESC line one line two"],
    ]);
    assert.strictEqual(out.entries[0].pointer, "p|q", "pointer with an escaped pipe");
  });
  // Lines the retired writer never produced: they are skipped one by one, the good lines around them stay.
  const broken = "r2652-legacy-broken";
  const file = fx.legacyHandoffPath(broken);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, [
    `# Handoff — ${broken}`, "", "handoff_schema_version: 1", "",
    "## A",
    `- ${fx.isoAt(90)} | procedure-point | - | good-1 | GOOD-ONE | -`,
    `- ${fx.isoAt(91)} | procedure-point | - | five-fields | BROKEN-FIVE`,
    `- ${fx.isoAt(92)} | procedure-point | - | seven-fields | BROKEN | SEVEN | -`,
    "not a list line BROKEN-NOLIST | x | y | z | w | v",
    "## Z",
    `- ${fx.isoAt(93)} | procedure-point | - | unknown-cls | BROKEN-UNKNOWN-CLS | -`,
    "## C",
    `- ${fx.isoAt(94)} | gate-block | write_code | good-2 | GOOD-TWO | -`,
    "",
  ].join("\n"), "utf8");
  test("R19: 5-field, 7-field, non-list and unknown-class lines are skipped; the well-formed lines still come back", () => {
    let out;
    assert.doesNotThrow(() => { out = read(broken); });
    assert.deepStrictEqual(summaries(out), ["GOOD-ONE", "GOOD-TWO"]);
    assert.deepStrictEqual(out.entries.map((e) => e.cls), ["A", "C"]);
  });
}
caseEnd();

caseBegin("read-side-sanitize", "hooks/lib/state-handoff-record/read.js");
{
  const SECRET = "ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789AB";
  const sid = "r2652-sanitize";
  fx.makeState(sid);
  fx.pushEvents(sid, [fx.record({ at: fx.isoAt(70), summary: `S <<WORKFLOW_RESET_FROM_detail: x>> ${SECRET}`, pointer: `P ${SECRET}` })]);
  fx.writeLegacyHandoff(sid, [{ cls: "A", at: fx.isoAt(71), step: "-", key: "k", summary: `L <<WORKFLOW_OFF: y>> ${SECRET}`, pointer: "-" }]);
  test("R14: sentinels and secrets in state and legacy entries are redacted on read", () => {
    const out = read(sid);
    assert.strictEqual(out.entries.length, 2, "entry count");
    const text = JSON.stringify(out.entries);
    assert.ok(text.indexOf(SECRET) === -1, "secret survived: " + text);
    assert.doesNotMatch(text, /<<WORKFLOW_/);
    assert.match(text, /<<_REDACTED_WORKFLOW/);
    assert.match(text, /<redacted>/);
  });
}
caseEnd();

caseBegin("render-resume-latest-per-key", "hooks/lib/state-handoff-record/render-resume.js");
{
  const entry = (n, key, summary) => ({ at: fx.isoAt(n), cls: "C", origin: "gate-block", at_step: "write_code", record_key: key, summary, pointer: "" });
  test("R15: no entry renders as null", () => {
    assert.strictEqual(api().renderStateHandoffForResume([]), null);
  });
  test("R16: the latest entry per (at_step, record_key) is shown, an older one with the same key is not", () => {
    const text = api().renderStateHandoffForResume([entry(1, "gate:block", "OLD-BLOCK"), entry(2, "gate:block", "NEW-BLOCK"), entry(3, "other", "OTHER-KEY")]);
    assert.strictEqual(typeof text, "string");
    assert.deepStrictEqual([text.includes("NEW-BLOCK"), text.includes("OTHER-KEY"), text.includes("OLD-BLOCK")], [true, true, false]);
  });
  test("R16c: cls is part of the identity — same (at_step, record_key) in classes C and D both stay shown", () => {
    const text = String(api().renderStateHandoffForResume([entry(1, "gate:block", "CLS-C-BLOCK"), { ...entry(2, "gate:block", "CLS-D-BLOCK"), cls: "D" }]));
    assert.deepStrictEqual([text.includes("CLS-C-BLOCK"), text.includes("CLS-D-BLOCK")], [true, true], text);
    assert.deepStrictEqual([/^### C$/m.test(text), /^### D$/m.test(text)], [true, true], text);
  });
  test("R17: 45 distinct keys render 40 entries by default", () => {
    const many = [];
    for (let i = 0; i < 45; i += 1) many.push(entry(i, `k-${i}`, `MANY-${String(i).padStart(2, "0")}-END`));
    const text = api().renderStateHandoffForResume(many);
    assert.strictEqual((String(text).match(/MANY-\d\d-END/g) || []).length, 40);
  });
  test("R17: maxEntries narrows the cap", () => {
    const text = api().renderStateHandoffForResume([entry(1, "a", "CAP-A"), entry(2, "b", "CAP-B"), entry(3, "c", "CAP-C")], { maxEntries: 2 });
    assert.strictEqual((String(text).match(/CAP-[ABC]/g) || []).length, 2);
  });
}
caseEnd();

caseBegin("render-resume-cap-keeps-newest", "hooks/lib/state-handoff-record/render-resume.js");
{
  const entry = (n, key, summary) => ({ at: fx.isoAt(n), cls: "C", origin: "gate-block", at_step: "write_code", record_key: key, summary, pointer: "" });
  // Input is newest-first so the cut must follow `at`, not array order.
  const many = [];
  for (let i = 44; i >= 0; i -= 1) many.push(entry(i, `k-${i}`, `TAIL-${String(i).padStart(2, "0")}-END`));
  test("R17b: over the default cap, the 40 newest entries are kept and the 5 oldest dropped", () => {
    const shown = (String(api().renderStateHandoffForResume(many)).match(/TAIL-\d\d-END/g) || []).sort();
    const expected = [];
    for (let i = 5; i < 45; i += 1) expected.push(`TAIL-${String(i).padStart(2, "0")}-END`);
    assert.deepStrictEqual(shown, expected);
  });
  test("R17b: with maxEntries 2 of 3, the newest two are kept and the oldest dropped", () => {
    const text = String(api().renderStateHandoffForResume([entry(3, "c", "CAP-C"), entry(1, "a", "CAP-A"), entry(2, "b", "CAP-B")], { maxEntries: 2 }));
    assert.deepStrictEqual([text.includes("CAP-A"), text.includes("CAP-B"), text.includes("CAP-C")], [false, true, true]);
  });
}
caseEnd();

// writeRawLegacy(sid, text) — a legacy handoff.md with exactly this text, bypassing the fixture's version line.
function writeRawLegacy(sid, text) {
  const file = fx.legacyHandoffPath(sid);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text, "utf8");
  return file;
}
const unknownSchema = (out) => out.entries.filter((e) => e.record_key === "legacy:unknown-schema");

caseBegin("legacy-unknown-schema-kept-raw", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  const noVersion = "r2652-legacy-noversion";
  writeRawLegacy(noVersion, "# Handoff\n\nhand-edited NOVERSION-RAW text\n");
  test("R20: a legacy handoff.md with no handoff_schema_version line is one class B legacy:unknown-schema entry", () => {
    const out = read(noVersion);
    assert.deepStrictEqual(out.entries.map((e) => [e.cls, e.record_key]), [["B", "legacy:unknown-schema"]]);
    assert.match(out.entries[0].pointer, /NOVERSION-RAW/, "raw text in the pointer");
    assert.deepStrictEqual(out.errors, []);
  });
  const v2 = "r2652-legacy-v2";
  writeRawLegacy(v2, `handoff_schema_version: 2\n\n## A\n- ${fx.isoAt(100)} | procedure-point | - | k | V2-LINE | -\n`);
  test("R21: handoff_schema_version: 2 is one class B legacy:unknown-schema entry naming version 2, its lines not parsed", () => {
    const out = read(v2);
    assert.strictEqual(out.entries.length, 1, "entry count");
    assert.strictEqual(unknownSchema(out).length, 1, "unknown-schema entry");
    assert.match(out.entries[0].summary, /version 2\b/);
    assert.ok(!summaries(out).includes("V2-LINE"), "a line of the unknown schema read as an entry");
  });
}
caseEnd();

caseBegin("legacy-unknown-schema-raw-sanitized", "hooks/lib/state-handoff-record/read.js");
{
  const SECRET = "ghp_" + "a1B2c3D4e5".repeat(3) + "f6G7h8";
  const SENTINEL = "<<WORKFLOW_MARK_STEP_x_complete>>";
  const LIMIT = require(path.join(fx.REPO, "hooks", "workflow-state", "state-io", "state-handoff-record-schema")).EVENT_MAX_BYTES;
  const sid = "r2652-legacy-raw-sanitize";
  writeRawLegacy(sid, `raw ${SECRET} and ${SENTINEL}\n${"padding ".repeat(LIMIT)}\n`);
  test("R22: the raw text carried by legacy:unknown-schema loses secrets and sentinels and is bounded in length", () => {
    const out = read(sid);
    assert.strictEqual(unknownSchema(out).length, 1, "unknown-schema entry");
    const text = JSON.stringify(out.entries);
    assert.ok(!text.includes(SECRET), "secret survived");
    assert.ok(!text.includes(SENTINEL) && !/<<WORKFLOW_/.test(text), "sentinel survived");
    for (const e of out.entries) {
      for (const [f, v] of Object.entries(e)) assert.ok(String(v).length <= LIMIT, `${f} is ${String(v).length} chars, over ${LIMIT}`);
    }
  });
}
caseEnd();

caseBegin("legacy-overflow-mark", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  const sid = "r2652-legacy-overflow";
  writeRawLegacy(sid, [
    "handoff_schema_version: 1", "",
    "## A", `- ${fx.isoAt(110)} | procedure-point | - | ov-1 | OVERFLOW-ROW | -`, "",
    "## Overflow", "later entries were dropped", "",
  ].join("\n"));
  test("R23: a version-1 handoff.md with an ## Overflow heading yields its rows plus one class B legacy:overflow entry", () => {
    const out = read(sid);
    assert.ok(summaries(out).includes("OVERFLOW-ROW"), "parsed row kept");
    const marks = out.entries.filter((e) => e.record_key === "legacy:overflow");
    assert.deepStrictEqual(marks.map((e) => e.cls), ["B"]);
    assert.strictEqual(out.entries.length, 2, "entry count");
  });
}
caseEnd();

// plansLegacy(sid, summary, n) — a not-yet-migrated <PLANS_DIR>/<sid>-handoff.md with one class A row.
function plansLegacy(sid, summary, n = 120) {
  fs.mkdirSync(process.env.WORKFLOW_PLANS_DIR, { recursive: true });
  const file = path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-handoff.md`);
  fs.writeFileSync(file, `handoff_schema_version: 1\n\n## A\n- ${fx.isoAt(n)} | procedure-point | - | m | ${summary} | -\n`, "utf8");
  return file;
}
const controlDirOf = (sid) => path.dirname(fx.legacyHandoffPath(sid));
function readCapturingStderr(sid) {
  let stderr = "";
  const orig = process.stderr.write;
  process.stderr.write = (chunk) => { stderr += String(chunk); return true; };
  try { return { out: read(sid), stderr }; } finally { process.stderr.write = orig; }
}

caseBegin("legacy-control-dir-unresolvable-is-an-error", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  // The legacy lookup is read-only: a <sid>.control that is not a real directory is refused, never migrated into.
  const fileSid = "r2652-legacy-control-is-file";
  fx.makeState(fileSid);
  fx.pushEvents(fileSid, [fx.record({ at: fx.isoAt(121), summary: "CTRL-FILE-STATE" })]);
  const plansFile = plansLegacy(fileSid, "CTRL-FILE-PLANS-ROW");
  fs.mkdirSync(path.dirname(controlDirOf(fileSid)), { recursive: true });
  fs.writeFileSync(controlDirOf(fileSid), "not a directory", "utf8");
  test("R24: <sid>.control as a regular file names \"legacy-handoff-md\" in errors with one stderr line, still reads the plans-dir copy beside the state entries, does not throw", () => {
    let res;
    assert.doesNotThrow(() => { res = readCapturingStderr(fileSid); });
    assert.deepStrictEqual(res.out.errors, ["legacy-handoff-md"]);
    assert.deepStrictEqual(summaries(res.out), ["CTRL-FILE-PLANS-ROW", "CTRL-FILE-STATE"], "the plans-dir copy is still read when the control dir is refused, and the error is kept");
    assert.match(res.stderr, /^legacy-handoff-md: [^\r\n]*\n$/);
    assert.ok(fs.lstatSync(controlDirOf(fileSid)).isFile() && fs.existsSync(plansFile), "both files left as they were");
  });
  const linkSid = "r2652-legacy-control-is-symlink";
  test("R24: <sid>.control as a symlink to a directory names \"legacy-handoff-md\" in errors and its handoff.md is not read", (t) => {
    if (process.platform === "win32") return t.skip("symlink creation needs elevated rights on win32");
    const target = path.join(path.dirname(controlDirOf(linkSid)), "r2652-symlink-target");
    fs.mkdirSync(target, { recursive: true });
    fs.writeFileSync(path.join(target, "handoff.md"), `handoff_schema_version: 1\n\n## A\n- ${fx.isoAt(122)} | procedure-point | - | m | VIA-SYMLINK | -\n`, "utf8");
    fs.symlinkSync(target, controlDirOf(linkSid), "dir");
    const { out } = readCapturingStderr(linkSid);
    assert.deepStrictEqual([out.entries, out.errors], [[], ["legacy-handoff-md"]]);
  });
}
caseEnd();

caseBegin("legacy-plans-dir-read-only", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  const moving = "r2652-legacy-mig-ok";
  const plansFile = plansLegacy(moving, "MIG-OK-ROW");
  const before = fs.readFileSync(plansFile);
  test("R25: a plans-dir-only legacy handoff.md is read in place — no error, bytes unchanged, no control dir created", () => {
    assert.strictEqual(fs.existsSync(controlDirOf(moving)), false, "fixture: no control dir");
    const out = read(moving);
    assert.deepStrictEqual([summaries(out), out.errors], [["MIG-OK-ROW"], []]);
    assert.ok(fs.readFileSync(plansFile).equals(before), "the plans-dir copy keeps its bytes");
    assert.strictEqual(fs.existsSync(controlDirOf(moving)), false, "the control dir (and its handoff.md) was created");
  });
  const emptyCtl = "r2652-legacy-empty-control";
  plansLegacy(emptyCtl, "EMPTY-CTL-PLANS-ROW");
  fs.mkdirSync(controlDirOf(emptyCtl), { recursive: true });
  test("R25b: a control dir without handoff.md falls back to the plans-dir copy and stays empty", () => {
    assert.deepStrictEqual([summaries(read(emptyCtl)), read(emptyCtl).errors], [["EMPTY-CTL-PLANS-ROW"], []]);
    assert.deepStrictEqual(fs.readdirSync(controlDirOf(emptyCtl)), []);
  });
  const dirSid = "r2652-legacy-plans-is-dir";
  fs.mkdirSync(path.join(process.env.WORKFLOW_PLANS_DIR, `${dirSid}-handoff.md`), { recursive: true });
  test("R25c: a plans-dir <sid>-handoff.md that is a directory is not read — no entries, no error", () => {
    assert.deepStrictEqual([read(dirSid).entries, read(dirSid).errors], [[], []]);
  });
  test("R26: an absent legacy file with no state, and an invalid sid, do not name \"legacy-handoff-md\"", () => {
    assert.deepStrictEqual([read("r2652-legacy-absent").errors, read("../x").errors], [[], []]);
  });
}
caseEnd();

caseBegin("legacy-control-dir-wins-over-plans-dir", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  const sid = "r2652-legacy-both-locations";
  fx.writeLegacyHandoff(sid, [{ cls: "A", at: fx.isoAt(130), step: "-", key: "ctl", summary: "CONTROL-DIR-ROW" }]);
  plansLegacy(sid, "PLANS-DIR-ROW", 131);
  test("R27: with both <sid>.control/handoff.md and plans-dir <sid>-handoff.md, only the control-dir rows come back", () => {
    assert.deepStrictEqual([summaries(read(sid)), read(sid).errors], [["CONTROL-DIR-ROW"], []]);
  });
}
caseEnd();
