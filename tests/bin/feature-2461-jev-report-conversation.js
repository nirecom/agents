#!/usr/bin/env node
// tests/bin/feature-2461-jev-report-conversation.js
// Tests: bin/jev-report, bin/lib/jev-report-aggregate/select.js, bin/lib/jev-report-aggregate/adoption.js
// Tags: TL2, bin, jev, report, decision-log, continuation, askuser-answer, scope:issue-specific, pwsh-not-required
// #2461 Step 1-6: jev-report reads only the new decision-log name (jev-decisions.jsonl), and
// counts a conversation-input point (continuation, askuser-answer) as adopted only when its
// record says adopted "jev"; a null or any other value is not an adoption.
// TL3 gap: none; the report reads local files only and runs here as the real CLI.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { after, test } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("../hooks/feature-2461-jev/fixture");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2461rc-"));
after(() => {
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const { DECISION_RECORD_VERSION } = require(F.lib("hooks/lib/jev/decision-record.js"));
const REPORT = path.join(F.REPO, "bin", "jev-report");
let seq = 0;
// rec(point, adopted, final) -> one hook-path (ticket-less) v2 decision record of a conversation point.
function rec(point, adopted, final) {
  seq++;
  return {
    version: DECISION_RECORD_VERSION, record_type: "decision", ts: `2026-11-01T00:00:${String(seq).padStart(2, "0")}Z`,
    point, mode: "production", adopted, threshold: { true: 0.9, false: null }, session_id: `sid-${seq}`, step: "write_code",
    judged_in: { kind: "hook", name: "stop-premature-stop-guard" }, final,
    jev: { status: "ok", probabilities: { "work-remaining": 0.97 } }, fallback_reason: adopted === "jev" ? null : "below-threshold",
  };
}
const CONT_YES = { direction: "continue-on-stop", intervene: true, keys: ["work-remaining"] };
const CONT_NO = { direction: "continue-on-stop", intervene: false, keys: [] };
const writeLog = (p, recs) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, recs.map((r) => JSON.stringify(r)).join("\n") + "\n"); };
// report(sc) -> the parsed --json report over the default log location.
function report(sc) {
  const o = F.run(sc, null, [REPORT, "--json", "--no-sweep"], { extra: { JEV: "off" } });
  assert.strictEqual(o.status, 0, o.stderr.slice(0, 400));
  return JSON.parse(o.stdout);
}
const point = (r, name) => (r.adoption && r.adoption.points && r.adoption.points[name]) || null;

caseBegin("new-log-name-only", "bin/jev-report");
test("records only under the old name jev-decisions.log: the report counts none of them", () => {
  const sc = F.scene(ROOT, "old-only");
  writeLog(sc.oldLog, [rec("continuation", "jev", CONT_YES), rec("continuation", "jev", CONT_YES)]);
  const r = report(sc);
  assert.strictEqual(point(r, "continuation"), null);
  assert.strictEqual(r.adoption.overall.count, 0);
});
test("records under the new name jev-decisions.jsonl are counted", () => {
  const sc = F.scene(ROOT, "new");
  writeLog(sc.log, [rec("continuation", "jev", CONT_YES)]);
  const r = report(sc);
  assert.ok(point(r, "continuation"), "continuation is reported");
  assert.strictEqual(point(r, "continuation").count, 1);
});
caseEnd();

caseBegin("conversation-adoption", "bin/lib/jev-report-aggregate/adoption.js");
test("continuation: adopted counts only \"jev\"; null and \"llm\" are not adoptions", () => {
  const sc = F.scene(ROOT, "adopt");
  writeLog(sc.log, [
    rec("continuation", "jev", CONT_YES), rec("continuation", "jev", CONT_YES),
    rec("continuation", null, CONT_NO), rec("continuation", "llm", CONT_NO),
    rec("askuser-answer", "jev", { route: "auto-answer", answers: { "Which format?": "HTML" } }),
    rec("askuser-answer", null, { route: "ask-user", answers: null }),
  ]);
  const r = report(sc);
  const c = point(r, "continuation");
  assert.ok(c, "continuation is reported");
  assert.strictEqual(c.count, 4);
  assert.deepStrictEqual(c.adopted, { jev: 2, llm: 0, mixed: 0 });
  const a = point(r, "askuser-answer");
  assert.ok(a, "askuser-answer is reported");
  assert.strictEqual(a.count, 2);
  assert.deepStrictEqual(a.adopted, { jev: 1, llm: 0, mixed: 0 });
});
caseEnd();
