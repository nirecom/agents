#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/state-handoff-record/legacy-handoff-md.js, hooks/lib/state-handoff-record/read.js
// Tags: TL2, state-handoff-record, state-handoff-reader, handoff, migration, sanitize, regression-2652, scope:issue-specific, pwsh-not-required, dup-group-keep:size-hard-limit
// #2652 R7b: a RESET written before #2652 to both the reset event and handoff.md reads back once.
// The legacy line is "RESET_FROM <step>: <reason>" (reset-handler's old summary); the state entry is
// "<step>: <reason>". Both sides are compared after the reader's own field sanitizer.

// # TL3 gap
// - A legacy handoff.md written by the retired reset-handler itself; every fixture here is written directly.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
const path = require("node:path");

const restore = isolate();
process.on("exit", () => restore());

const fx = require("../lib/state-handoff-record-fixture");
const BARREL = path.join(fx.REPO, "hooks", "lib", "state-handoff-record");

const NL = String.fromCharCode(10);
const CR = String.fromCharCode(13);
const SENTINEL = "<" + "<WORKFLOW_RESET_FROM_detail: x>" + ">";
const TOKEN_A = "ghp" + "_" + "A1b2C3d4".repeat(4);
const TOKEN_B = "ghp" + "_" + "Z9y8X7w6".repeat(4);

let seq = 0;
// fixture(row) -> sid: one state reset event plus one legacy class E reset-from line.
function fixture({ stateStep, stateReason, legacyStep, legacySummary }) {
  const sid = `r2652-dedupe-${seq++}`;
  fx.makeState(sid);
  fx.pushEvents(sid, [fx.resetEvent({ at: fx.isoAt(40), from_step: stateStep, reason: stateReason })]);
  fx.writeLegacyHandoff(sid, [
    { cls: "E", at: fx.isoAt(40), origin: "reset-handler", step: legacyStep, key: "reset-from", summary: legacySummary },
  ]);
  return sid;
}
function resets(sid) {
  const out = require(BARREL).readStateHandoff(sid);
  assert.ok(out && Array.isArray(out.entries) && Array.isArray(out.errors), `readStateHandoff shape: ${JSON.stringify(out)}`);
  assert.deepStrictEqual(out.errors, []);
  return out.entries.filter((e) => e.record_key === "reset-from");
}

caseBegin("legacy-reset-from-dedupes-both-shapes", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  const rows = [
    { name: "B1 RESET_FROM-prefixed legacy summary", legacySummary: "RESET_FROM write_tests: B-REASON" },
    { name: "B4 unprefixed legacy summary", legacySummary: "write_tests: B-REASON" },
  ];
  for (const r of rows) {
    const sid = fixture({ stateStep: "write_tests", stateReason: "B-REASON", legacyStep: "write_tests", legacySummary: r.legacySummary });
    test(`${r.name}: the same RESET in the state and the legacy handoff.md reads back as one reset-from entry`, () => {
      const got = resets(sid);
      assert.strictEqual(got.length, 1, `reset-from count: ${JSON.stringify(got.map((e) => e.summary))}`);
      assert.strictEqual(got[0].summary, "write_tests: B-REASON");
    });
  }
}
caseEnd();

caseBegin("legacy-reset-from-normalized-compare", "hooks/lib/state-handoff-record/read.js");
{
  const reason = `R ${SENTINEL}${NL}line2 ${TOKEN_A}`;
  const rows = [
    // The fixture escapes the newline as \n; the parser unescapes it back to the raw reason.
    { name: "B2 escaped legacy round-trip", legacyReason: reason },
    // Raw text differs (CR for LF, another token) yet sanitizes to the same value.
    { name: "B2 raw-different, sanitized-equal", legacyReason: `R ${SENTINEL}${CR}line2 ${TOKEN_B}` },
  ];
  for (const r of rows) {
    const sid = fixture({ stateStep: "write_code", stateReason: reason, legacyStep: "write_code", legacySummary: `RESET_FROM write_code: ${r.legacyReason}` });
    test(`${r.name}: deduped to one reset-from entry`, () => {
      assert.strictEqual(resets(sid).length, 1, "reset-from count");
    });
    test(`${r.name}: the shown entry is sanitized`, () => {
      const s = resets(sid)[0].summary;
      assert.strictEqual(/<<\s*WORKFLOW/i.test(s), false, "runnable sentinel survived");
      assert.ok(s.includes("<<_REDACTED_WORKFLOW"), "redacted sentinel marker");
      assert.strictEqual(s.includes(TOKEN_A) || s.includes(TOKEN_B), false, "token survived");
      assert.ok(s.includes("<redacted>"), "redacted token marker");
      assert.strictEqual(/[\r\n]/.test(s), false, "raw line break survived");
      assert.ok(s.startsWith("write_code: R "), "state summary shape");
    });
  }
}
caseEnd();

caseBegin("legacy-reset-from-near-miss-shows-both", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  const rows = [
    { name: "B3 same reason, different step", legacyStep: "write_code", legacySummary: "RESET_FROM write_code: NEAR-REASON" },
    { name: "B3 same reason and summary step, different step field", legacyStep: "write_code", legacySummary: "RESET_FROM write_tests: NEAR-REASON" },
    { name: "B3 same step, different reason", legacyStep: "write_tests", legacySummary: "RESET_FROM write_tests: NEAR-REASON-2" },
  ];
  for (const r of rows) {
    const sid = fixture({ stateStep: "write_tests", stateReason: "NEAR-REASON", legacyStep: r.legacyStep, legacySummary: r.legacySummary });
    test(`${r.name}: the state and the legacy reset-from entries both stay`, () => {
      const got = resets(sid).map((e) => e.summary).sort();
      assert.deepStrictEqual(got, [r.legacySummary, "write_tests: NEAR-REASON"].sort());
    });
  }
}
caseEnd();

// R28: a control-dir handoff.md that exists but cannot be read (EACCES, injected through fs so it
// also runs on win32) falls back to the plans-dir copy and still reports the read failure.
caseBegin("legacy-unreadable-control-falls-back-to-plans-dir", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  const fs = require("node:fs");
  function plansLegacy(sid, summary) {
    fs.mkdirSync(process.env.WORKFLOW_PLANS_DIR, { recursive: true });
    const file = path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-handoff.md`);
    fs.writeFileSync(file, `handoff_schema_version: 1${NL}${NL}## A${NL}- ${fx.isoAt(141)} | procedure-point | - | m | ${summary} | -${NL}`, "utf8");
    return file;
  }
  // readWithDenied(sid, files) — readStateHandoff with fs.readFileSync throwing EACCES for `files`.
  function readWithDenied(sid, files) {
    const denied = new Set(files.map((f) => path.resolve(f).toLowerCase()));
    const real = fs.readFileSync;
    const hits = [];
    fs.readFileSync = function patched(p) {
      const key = typeof p === "string" ? path.resolve(p).toLowerCase() : null;
      if (key && denied.has(key)) {
        hits.push(key);
        throw Object.assign(new Error(`EACCES: permission denied, open '${p}'`), { code: "EACCES" });
      }
      return real.apply(this, arguments);
    };
    try { return { out: require(BARREL).readStateHandoff(sid), hits }; } finally { fs.readFileSync = real; }
  }
  const rows = [
    { name: "R28a control unreadable, plans-dir readable", deny: ["control"], want: ["PLANS-DIR-ROW"] },
    { name: "R28b both unreadable", deny: ["control", "plans"], want: [] },
  ];
  rows.forEach((r, i) => {
    const sid = `r2652-legacy-unreadable-${i}`;
    const files = {
      control: fx.writeLegacyHandoff(sid, [{ cls: "A", at: fx.isoAt(140), step: "-", key: "ctl", summary: "CONTROL-ROW" }]),
      plans: plansLegacy(sid, "PLANS-DIR-ROW"),
    };
    test(`${r.name}: entries ${JSON.stringify(r.want)}, errors ["legacy-handoff-md"]`, () => {
      const { out, hits } = readWithDenied(sid, r.deny.map((k) => files[k]));
      assert.strictEqual(hits.length, r.deny.length, `injected EACCES fired ${hits.length} times`);
      assert.deepStrictEqual([out.entries.map((e) => e.summary), out.errors], [r.want, ["legacy-handoff-md"]]);
    });
  });
}
caseEnd();

// R24b: a refused control dir (a regular file, so it also runs on win32) with no plans-dir copy
// leaves only the state entries and still names "legacy-handoff-md".
caseBegin("legacy-refused-control-without-plans-copy", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  const fs = require("node:fs");
  const sid = "r2652-legacy-refused-no-plans";
  fx.makeState(sid);
  fx.pushEvents(sid, [fx.record({ at: fx.isoAt(150), summary: "REFUSED-NO-PLANS-STATE" })]);
  const controlDir = path.dirname(fx.legacyHandoffPath(sid));
  fs.mkdirSync(path.dirname(controlDir), { recursive: true });
  fs.writeFileSync(controlDir, "not a directory", "utf8");
  test("R24b: <sid>.control as a regular file and no plans-dir copy: state entries only, errors [\"legacy-handoff-md\"], no throw", () => {
    assert.strictEqual(fs.existsSync(path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-handoff.md`)), false, "fixture: no plans-dir copy");
    let stderr = "";
    const orig = process.stderr.write;
    process.stderr.write = (chunk) => { stderr += String(chunk); return true; };
    let out;
    try {
      assert.doesNotThrow(() => { out = require(BARREL).readStateHandoff(sid); });
    } finally { process.stderr.write = orig; }
    assert.deepStrictEqual([out.entries.map((e) => e.summary), out.errors], [["REFUSED-NO-PLANS-STATE"], ["legacy-handoff-md"]]);
    assert.match(stderr, /^legacy-handoff-md: [^\r\n]*\n$/);
  });
}
caseEnd();
