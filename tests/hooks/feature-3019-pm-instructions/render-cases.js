"use strict";
// Section-reading and size-cap cases of tests/hooks/feature-3019-pm-instructions.js (#3019). No case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const { test } = require("node:test");
const W8 = require("./world");

const { P, MD_ENV, MAX_BYTES, fixtureMd, makeWorld, brief, firstLine } = W8;
const TRUNC_RE = /^\[pm-instructions\b[^\n]*truncated at 8192 bytes\]$/m;

// missingHeading: a contract heading absent from the md -> null plus exactly one stderr line, never a throw.
function missingHeading(S) {
  const w = makeWorld(S, "missing");
  const pmSid = P.uuid(0x30190601);
  const wf = P.uuid(0x30190602);
  w.pm(pmSid, P.pm({ tag: "PM-miss", issues: [4601] }));
  w.plain(wf);
  w.intent(wf, ["#4601"]);
  w.field({ "o/r#4601": "PM-miss" });
  const cases = [
    ["the PM session / Session start H3", pmSid, fixtureMd({ drop: { h2: "PM session", h3: "Session start" } })],
    ["the whole Workflow session H2", wf, fixtureMd({ drop: { h2: "Workflow session" } })],
    ["Before user verification, one H3 of the workflow bundle", wf, fixtureMd({ drop: { h2: "Workflow session", h3: "Before user verification" } })],
  ];
  cases.forEach(([label, sid, text], i) => {
    test(`render-missing-heading: ${label} missing -> null and one stderr line`, () => {
      const r = w.probe({ sid, deadline: "hook" }, { [MD_ENV]: S.md(`missing-${i}`, text) });
      assert.strictEqual(r.value, null, brief(r));
      assert.strictEqual(r.err.trim().split("\n").filter(Boolean).length, 1, `stderr lines: ${JSON.stringify(r.err)}`);
    });
  });
  test("render-missing-heading: control — the same world with a complete md injects for both roles", () => {
    const md = { [MD_ENV]: S.md("missing-control", fixtureMd()) };
    for (const sid of [pmSid, wf]) {
      const r = w.probe({ sid, deadline: "hook" }, md);
      assert.strictEqual(typeof r.value, "string", brief(r));
      assert.strictEqual(r.err.trim(), "", `stderr on a complete md: ${r.err}`);
    }
  });
  test("render-missing-md: the SSOT md absent -> null, no throw", () => {
    const r = w.probe({ sid: pmSid, deadline: "hook" }, { [MD_ENV]: S.md("does-not-exist", null) });
    assert.strictEqual(r.value, null, brief(r));
  });
  test("render-corrupt-state: the session's own state file is not JSON -> null, no throw", () => {
    const bad = P.uuid(0x30190603);
    w.within(() => fs.writeFileSync(P.statePath(bad), "{not json"));
    const r = w.probe({ sid: bad, deadline: "hook" }, { [MD_ENV]: S.md("missing-control", fixtureMd()) });
    assert.strictEqual(r.value, null, brief(r));
  });
}

// cap: a section over MAX_BYTES is cut on a UTF-8 boundary and marked; one under it is kept whole.
function cap(S) {
  const w = makeWorld(S, "cap");
  const pmSid = P.uuid(0x30190701);
  w.pm(pmSid, P.pm({ tag: "PM-cap", issues: [4701] }));
  // lang-check: ignore -- the 3-byte character is the point: 8192 is not a multiple of 3.
  const big = `${"あ".repeat(4000)}\nTAIL-SENTINEL-3019`;
  const r0 = () => w.probe({ sid: pmSid, deadline: "hook" }, { [MD_ENV]: S.md("cap-big", fixtureMd({ body: { h2: "PM session", h3: "Session start", text: big } })) });
  test("render-cap: an oversized section is cut and carries the truncation marker", () => {
    const r = r0();
    assert.strictEqual(typeof r.value, "string", brief(r));
    assert.ok(TRUNC_RE.test(r.value), `no truncation marker: ${brief(r)}`);
    assert.ok(!r.value.includes("TAIL-SENTINEL-3019"), "the text past the cap leaked");
    assert.ok(firstLine(r.value).startsWith("[pm-instructions role=pm"), brief(r));
  });
  test("render-cap: the cut lands on a character boundary and the kept text fits MAX_BYTES", () => {
    const r = r0();
    const lines = String(r.value).split("\n");
    const kept = lines.slice(1).filter((l) => !TRUNC_RE.test(l)).join("\n");
    assert.ok(!kept.includes("�"), "a character was split (U+FFFD present)");
    assert.ok(Buffer.byteLength(kept, "utf8") <= MAX_BYTES, `kept ${Buffer.byteLength(kept, "utf8")} bytes`);
    assert.ok(kept.includes("あ".repeat(100)), "the section body itself was dropped");
  });
  test("render-cap: a section under the cap -> no truncation marker", () => {
    const r = w.probe({ sid: pmSid, deadline: "hook" }, { [MD_ENV]: S.md("cap-small", fixtureMd()) });
    assert.strictEqual(typeof r.value, "string", brief(r));
    assert.ok(!/truncated at/.test(r.value), brief(r));
  });
  test("render-idempotent: two calls on the same world and md give byte-identical output", () => {
    const md = { [MD_ENV]: S.md("cap-small", fixtureMd()) };
    const a = w.probe({ sid: pmSid, deadline: "hook" }, md);
    const b = w.probe({ sid: pmSid, deadline: "hook" }, md);
    assert.strictEqual(typeof a.value, "string", brief(a));
    assert.strictEqual(a.value, b.value);
  });
}

module.exports = { missingHeading, cap };
