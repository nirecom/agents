#!/usr/bin/env node
// tests/bin/feature-2764-jev-report-dialogs.js
// Tests: bin/jev-report, bin/lib/jev-report-aggregate/askuser-dialogs.js
// Tags: TL2, bin, jev, report, askuserquestion, askuser-answer, dialog-id, route-log, jsonl, log-rotation, output-sanitize, flag-rename, scope:issue-specific, pwsh-not-required
// #2764 Step 13-14: jev-report reads the AskUserQuestion route log and shows, per dialog ID (null as
// "(no id)"), how many were shown, sent to Jev (jev_called, an error after the call included) and
// answered. The section appears with no --point or --point askuser-answer, and in --json under
// askuser_dialogs. TL3 gap: none; the report reads local files only and runs here as the real CLI.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { after, test } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("../hooks/feature-2461-jev/fixture");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2764rd-"));
after(() => {
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const REPORT = path.join(F.REPO, "bin", "jev-report");
const AGG = F.lib("bin/lib/jev-report-aggregate/askuser-dialogs.js");
const CAL = "run-tests.calibrate";
const HIGH = "write-code.edit-plan-approve";
let seq = 0;
const route = (dialog_id, r, jev_called = false, step = "run_tests") => {
  seq++;
  return { version: 1, ts: `2026-11-01T00:00:${String(seq % 60).padStart(2, "0")}Z`, session_id: `sid-${seq}`, dialog_id, route: r, step, jev_called };
};
// The fixture: calibrate shown 4 (to Jev 3, answered 1), the high ID shown 2, no ID shown 1.
const RECORDS = [
  route(CAL, "answered", true),
  route(CAL, "jev-declined", true),
  route(CAL, "error", true),
  route(CAL, "step-mismatch", false, "write_code"),
  route(HIGH, "high", false, null),
  route(HIGH, "high", false, null),
  route(null, "no-id", false, null),
];
const WANT = {
  [CAL]: { shown: 4, to_jev: 3, answered: 1, routes: { answered: 1, "jev-declined": 1, error: 1, "step-mismatch": 1 } },
  [HIGH]: { shown: 2, to_jev: 0, answered: 0, routes: { high: 2 } },
  "(no id)": { shown: 1, to_jev: 0, answered: 0, routes: { "no-id": 1 } },
};
const jsonl = (recs) => recs.map((r) => (typeof r === "string" ? r : JSON.stringify(r))).join("\n") + "\n";
// dialogsOf(x) — the per-ID map, whether given bare or under a dialogs key.
const dialogsOf = (x) => (x && x.dialogs && typeof x.dialogs === "object" ? x.dialogs : x);
const pick = (d) => ({ shown: d.shown, to_jev: d.to_jev, answered: d.answered, routes: d.routes });
// report(name, {records, files, args, extra}) — the CLI on a fresh scene; files maps a name under the scene to text.
function report(name, opt = {}) {
  const sc = F.scene(ROOT, name);
  const routesLog = path.join(sc.io, "routes.jsonl");
  if (opt.records) fs.writeFileSync(routesLog, jsonl(opt.records));
  for (const [rel, text] of Object.entries(opt.files || {})) {
    const p = path.join(sc.dir, rel);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, text);
  }
  const args = opt.args || ["--routes-log", F.fwd(routesLog)];
  const o = F.run(sc, null, [REPORT, "--no-sweep", "--log", F.fwd(path.join(sc.io, "no-decisions.jsonl")), ...args], { extra: Object.assign({ JEV: "off" }, opt.extra || {}) });
  return Object.assign(o, { sc, routesLog });
}
const jsonOf = (o) => { assert.strictEqual(o.status, 0, o.stderr.slice(0, 300)); return JSON.parse(o.stdout); };

caseBegin("aggregate", "bin/lib/jev-report-aggregate/askuser-dialogs.js");
test("aggregateDialogs counts shown / to_jev / answered / routes per dialog ID, null as (no id)", () => {
  const got = dialogsOf(require(AGG).aggregateDialogs(RECORDS));
  assert.deepStrictEqual(Object.keys(got).sort(), Object.keys(WANT).sort());
  for (const [id, want] of Object.entries(WANT)) assert.deepStrictEqual(pick(got[id]), want, id);
});
test("a route error after Jev was called counts toward to_jev", () => {
  const got = dialogsOf(require(AGG).aggregateDialogs([route(CAL, "error", true), route(CAL, "error", false)]));
  assert.deepStrictEqual(pick(got[CAL]), { shown: 2, to_jev: 1, answered: 0, routes: { error: 2 } });
});
test("formatDialogs: a dialog ID carrying a newline or ESC cannot forge a line or a terminal sequence", () => {
  const evil = `${CAL}\nFAKE-LINE answered=999\u001b[31m`;
  const text = require(AGG).formatDialogs(require(AGG).aggregateDialogs([route(evil, "malformed-id")]));
  assert.ok(!text.includes("\u001b"), "no ESC");
  assert.ok(!text.split("\n").some((l) => l.startsWith("FAKE-LINE")), text);
});
caseEnd();

caseBegin("cli", "bin/jev-report");
test("--json carries askuser_dialogs with the per-ID counts", () => {
  const sc = F.scene(ROOT, "json");
  const p = path.join(sc.io, "routes.jsonl");
  fs.writeFileSync(p, jsonl(RECORDS));
  const j = jsonOf(F.run(sc, null, [REPORT, "--no-sweep", "--log", F.fwd(path.join(sc.io, "none.jsonl")), "--routes-log", F.fwd(p), "--json"], { extra: { JEV: "off" } }));
  const got = dialogsOf(j.askuser_dialogs);
  for (const [id, want] of Object.entries(WANT)) assert.deepStrictEqual(pick(got[id]), want, id);
});
test("text output names each dialog ID with no --point and with --point askuser-answer", () => {
  for (const extraArgs of [[], ["--point", "askuser-answer"]]) {
    const sc = F.scene(ROOT, `text-${extraArgs.length}`);
    const p = path.join(sc.io, "routes.jsonl");
    fs.writeFileSync(p, jsonl(RECORDS));
    const o = F.run(sc, null, [REPORT, "--no-sweep", "--log", F.fwd(path.join(sc.io, "none.jsonl")), "--routes-log", F.fwd(p), ...extraArgs], { extra: { JEV: "off" } });
    assert.strictEqual(o.status, 0, o.stderr.slice(0, 300));
    for (const id of [CAL, HIGH, "(no id)"]) assert.ok(o.stdout.includes(id), `${extraArgs.join(" ") || "no --point"}: ${id} shown`);
  }
});
test("--point continuation: no dialog section, no askuser_dialogs key", () => {
  const sc = F.scene(ROOT, "point-cont");
  const p = path.join(sc.io, "routes.jsonl");
  fs.writeFileSync(p, jsonl(RECORDS));
  const base = [REPORT, "--no-sweep", "--log", F.fwd(path.join(sc.io, "none.jsonl")), "--routes-log", F.fwd(p), "--point", "continuation"];
  const t = F.run(sc, null, base, { extra: { JEV: "off" } });
  assert.strictEqual(t.status, 0, t.stderr.slice(0, 300));
  assert.ok(!t.stdout.includes(CAL), t.stdout.slice(0, 400));
  const j = F.run(sc, null, [...base, "--json"], { extra: { JEV: "off" } });
  assert.strictEqual(JSON.parse(j.stdout).askuser_dialogs, undefined);
});
test("without --routes-log the report reads <AGENTS_STATE_DIR>/logs/askuser-routes.jsonl", () => {
  const j = jsonOf(report("default-path", { files: { "state/logs/askuser-routes.jsonl": jsonl(RECORDS) }, args: ["--json"] }));
  assert.deepStrictEqual(pick(dialogsOf(j.askuser_dialogs)[CAL]), WANT[CAL]);
});
test("rotated generations (.3 .. .1) are read with the base, and unparsable lines are skipped", () => {
  const sc = F.scene(ROOT, "rotation");
  const p = path.join(sc.io, "routes.jsonl");
  fs.writeFileSync(`${p}.3`, jsonl([route(CAL, "answered", true)]));
  fs.writeFileSync(`${p}.1`, jsonl([route(CAL, "jev-declined", true), "{not json", "[1,2]"]));
  fs.writeFileSync(p, jsonl([route(CAL, "step-mismatch"), ""]));
  const o = F.run(sc, null, [REPORT, "--no-sweep", "--log", F.fwd(path.join(sc.io, "none.jsonl")), "--routes-log", F.fwd(p), "--json"], { extra: { JEV: "off" } });
  const j = jsonOf(o);
  assert.deepStrictEqual(pick(dialogsOf(j.askuser_dialogs)[CAL]), { shown: 3, to_jev: 2, answered: 1, routes: { answered: 1, "jev-declined": 1, "step-mismatch": 1 } });
});
test("text output of a hostile log: no ESC, no forged line", () => {
  const evil = route(`x.y\nFAKE-LINE shown=999\u001b]0;pwn\u0007`, "malformed-id");
  const o = report("hostile", { records: [evil] });
  assert.strictEqual(o.status, 0, o.stderr.slice(0, 300));
  assert.ok(!o.stdout.includes("\u001b") && !o.stdout.includes("\u0007"), "no control characters");
  assert.ok(!o.stdout.split("\n").some((l) => l.startsWith("FAKE-LINE")), o.stdout.slice(0, 400));
});
test("only the old JEV_AUTO_SKIP_ASKUSER=off: the report warns with the new name", () => {
  const o = report("old-flag", { records: RECORDS, extra: { JEV_AUTO_SKIP_ASKUSER: "off" } });
  assert.strictEqual(o.status, 0, o.stderr.slice(0, 300));
  assert.ok(o.stderr.includes("JEV_AUTO_CLARIFICATIONS"), o.stderr.slice(0, 300));
});
caseEnd();
