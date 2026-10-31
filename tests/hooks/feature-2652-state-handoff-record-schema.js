#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/state-handoff-record-schema.js
// Tags: TL1, TL2, workflow-state, event-stream, state-handoff-record, regression-2652, scope:issue-specific, pwsh-not-required
// lang-check: ignore — multibyte fixture strings are test data for truncation/UTF-8 handling.
// #2652 S1-1 / S1-2: the state_handoff_record event kind. validateEvent accepts and refuses it by the
// rules of the new schema module, and adding 0 or 300 such records to a state leaves the projection,
// the current step, next-step's ACTION / NEXT_SKILL and the stream integrity check unchanged.
// TL3 gap (what this test does NOT catch):
// - a live hook writing records while next-step runs in a real session; here the records are appended
//   through appendEvents in one batch and next-step is spawned against a fixture state.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2652s-"));
process.chdir(SCRATCH);
process.on("exit", () => {
  process.chdir(os.tmpdir());
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const { check, eq, show, parseKv } = require("./feature-2652-state-handoff/check");
const ROOT = path.resolve(__dirname, "..", "..");
const mod = (rel) => require(path.join(ROOT, rel));
const EV = mod("hooks/workflow-state/state-io/events");
const S = mod("hooks/workflow-state/state-io");
const { projectState, assertStreamIntegrity } = mod("hooks/workflow-state/state-io/projection");
let SCHEMA = null;
let schemaLoadError = null;
try { SCHEMA = mod("hooks/workflow-state/state-io/state-handoff-record-schema"); } catch (e) { schemaLoadError = e.message.split("\n")[0]; }
const schema = () => { if (!SCHEMA) throw new Error(`schema module not loadable: ${schemaLoadError}`); return SCHEMA; };

// record(over) — a well-formed state_handoff_record; `over` replaces fields, an undefined value removes one.
function record(over) {
  const ev = {
    kind: "state_handoff_record", cls: "C", at_step: "write_tests", record_key: "gate:block",
    summary: "blocked by the gate", pointer: "-", origin: "gate-block", provenance: "observed",
  };
  for (const [k, v] of Object.entries(over || {})) { if (v === undefined) delete ev[k]; else ev[k] = v; }
  return ev;
}
// refusal(ev, field) — validateEvent must throw InvalidEventError naming `field`, not the kind.
function refusal(ev, field) {
  let err = null;
  try { EV.validateEvent(ev); } catch (e) { err = e; }
  if (!err) throw new Error("validateEvent accepted the event");
  if (!(err instanceof EV.InvalidEventError)) throw new Error(`threw ${err && err.name}, not InvalidEventError`);
  if (/event\.kind/.test(err.message)) throw new Error(`refused for the kind, not for ${field}: ${err.message}`);
  if (!err.message.includes(field)) throw new Error(`message does not name ${field}: ${err.message}`);
}

caseBegin("schema-constants", "hooks/workflow-state/state-io/state-handoff-record-schema.js");
{
  check("S1-1: the schema module exports the classes, origins and limits of the plan", () => {
    const m = schema();
    eq(m.CLASSES, ["A", "B", "C", "D", "E", "F", "G"], "CLASSES");
    eq([...m.ORIGINS].sort(), ["auto-record", "gate-block", "procedure-point"], "ORIGINS");
    eq(String(m.KEY_VALID_RE), String(/^[A-Za-z0-9_.:-]+$/), "KEY_VALID_RE");
    eq([m.MAX_FIELD_CHARS, m.EVENT_MAX_BYTES, m.MAX_RECORDS, m.MAX_TOTAL_BYTES, m.SEQ_RESERVE_DIGITS],
      [300, 2048, 300, 65536, 10], "limits");
  });
  check("S1-1: storedEventBytes counts the compact UTF-8 form with a 10-digit seq, with or without a seq", () => {
    const m = schema();
    const ev = Object.assign(record({ summary: "要約 summary" }), { at: "2026-10-28T00:00:00.000Z" });
    const want = Buffer.byteLength(JSON.stringify(Object.assign({}, ev, { seq: 1234567890 })), "utf8");
    eq(m.storedEventBytes(ev), want, "bytes without seq");
    eq(m.storedEventBytes(Object.assign({}, ev, { seq: 7 })), want, "bytes with a 1-digit seq");
  });
}
caseEnd();

caseBegin("validate-accepts-state-handoff-record", "hooks/workflow-state/state-io/events.js");
{
  check("S1-1: state_handoff_record is an EVENT_KIND with the five required fields", () => {
    eq(EV.EVENT_KINDS.includes("state_handoff_record"), true, "in EVENT_KINDS");
    eq(EV.REQUIRED_FIELDS.state_handoff_record, ["cls", "at_step", "record_key", "summary", "pointer"], "REQUIRED_FIELDS");
  });
  const accepted = [
    ["every class A-G", ["A", "B", "C", "D", "E", "F", "G"].map((cls) => record({ cls }))],
    ["every origin", [record({ origin: "procedure-point", provenance: "declared" }), record({ origin: "gate-block" }), record({ origin: "auto-record" })]],
    ["at_step '-' and a VALID_STEP", [record({ at_step: "-" }), record({ at_step: S.VALID_STEPS[0] })]],
    ["a 120-character key and the reserved overflow key", [record({ record_key: "k".repeat(120) }), record({ cls: "B", record_key: "state-handoff:overflow" })]],
  ];
  for (const [label, events] of accepted) {
    check(`S1-1: validateEvent accepts ${label}`, () => { for (const ev of events) EV.validateEvent(ev); });
  }
  check("S1-1: the record carries no step / key, so the VALID_STEPS check on step never applies", () => {
    const ev = record({ at_step: "-" });
    eq(["step", "key"].filter((k) => Object.prototype.hasOwnProperty.call(ev, k)), [], "step/key fields");
    EV.validateEvent(ev);
  });
}
caseEnd();

caseBegin("validate-refuses-malformed-record", "hooks/workflow-state/state-io/events.js");
{
  for (const field of ["cls", "at_step", "record_key", "summary", "pointer"]) {
    check(`S1-1: a record without ${field} is refused`, () => refusal(record({ [field]: undefined }), field));
  }
  for (const cls of ["H", "a", ""]) check(`S1-1: cls ${show(cls)} is refused`, () => refusal(record({ cls }), "cls"));
  for (const origin of ["flush", "mark-step"]) check(`S1-1: origin ${show(origin)} is refused`, () => refusal(record({ origin }), "origin"));
  check("S1-1: an at_step outside VALID_STEPS and '-' is refused", () => refusal(record({ at_step: "not_a_step" }), "at_step"));
  for (const [label, key] of [["a space", "gate block"], ["a slash", "a/b"], ["a newline", "a\nb"], ["121 characters", "k".repeat(121)]]) {
    check(`S1-1: a record_key with ${label} is refused`, () => refusal(record({ record_key: key }), "record_key"));
  }
}
caseEnd();

// seed(sid) — workflow_init complete and research skipped: a state next-step has an answer for.
function seed(sid) {
  S.writeState(sid, S.createInitialState(sid, { cwd: SCRATCH, git_branch: "feature/2652-fixture" }));
  S.markStep(sid, "workflow_init", "complete");
  S.markStep(sid, "research", "skipped", { skip_reason: "fixture" });
}
function nextStep(sid) {
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [path.join(ROOT, "bin/workflow/next-step"), "--session", sid],
    { input: "", cwd: SCRATCH, env, encoding: "utf8", timeout: 60000 });
  return Object.assign(parseKv(r.stdout || ""), { _d: `exit=${r.status} err=${String(r.stderr || "").slice(0, 300)}` });
}
const recordsFor = (n) => Array.from({ length: n }, (_, i) => record({
  cls: "ABCDEFG"[i % 7], record_key: `fixture.${i}`, summary: `record ${i}`,
  origin: i % 3 === 0 ? "procedure-point" : i % 3 === 1 ? "gate-block" : "auto-record",
  provenance: i % 3 === 0 ? "declared" : "observed",
}));

caseBegin("records-leave-projection-and-gate-unchanged", "hooks/workflow-state/state-io/events.js");
{
  const cur = mod("hooks/workflow-state/current-step");
  const runs = {};
  for (const [sid, n] of [["s2652-zero", 0], ["s2652-three-hundred", 300]]) {
    seed(sid);
    let appendError = null;
    if (n > 0) { try { EV.appendEvents(sid, recordsFor(n)); } catch (e) { appendError = e.message; } }
    const raw = JSON.parse(fs.readFileSync(path.join(process.env.WORKFLOW_STATE_DIR, sid + ".json"), "utf8"));
    runs[n] = { appendError, raw, projection: projectState(raw), current: cur.resolveCurrentEffectiveStep(sid), ns: nextStep(sid) };
  }
  const zero = runs[0];
  const many = runs[300];
  check("S1-2: fixture — with 0 records there is a current step and next-step prints an ACTION", () => {
    if (zero.current === null) return "no current step";
    if (!zero.ns.ACTION) return `no ACTION (${zero.ns._d})`;
    return undefined;
  });
  const appended = () => { if (many.appendError) throw new Error(`appendEvents refused the records: ${many.appendError}`); };
  check("S1-2: 300 records go through appendEvents and all land in the stream", () => {
    appended();
    eq(many.raw.events.filter((e) => e.kind === "state_handoff_record").length, 300, "stored records");
  });
  check("S1-2: the projection is identical with 0 and with 300 records", () => {
    appended();
    // The two sessions are seeded at different wall-clock times, so steps[*].updated_at differs by design.
    const clockless = (p) => Object.assign({}, p, { steps: Object.fromEntries(Object.entries(p.steps || {}).map(([k, v]) => {
      const { updated_at: _ignored, ...rest } = v || {};
      return [k, rest];
    })) });
    eq(clockless(many.projection), clockless(zero.projection), "projectState");
  });
  check("S1-2: the current step is identical with 0 and with 300 records", () => {
    appended();
    if (zero.current === null) throw new Error("fixture: no current step with 0 records");
    eq(many.current, zero.current, "resolveCurrentEffectiveStep");
  });
  check("S1-2: next-step ACTION / NEXT_SKILL are identical with 0 and with 300 records", () => {
    appended();
    if (!zero.ns.ACTION) throw new Error(`fixture: next-step printed no ACTION (${zero.ns._d})`);
    eq([many.ns.ACTION, many.ns.NEXT_SKILL], [zero.ns.ACTION, zero.ns.NEXT_SKILL], `next-step (${many.ns._d})`);
  });
  check("S1-2: assertStreamIntegrity passes on both streams", () => {
    appended();
    assertStreamIntegrity(zero.raw.events);
    assertStreamIntegrity(many.raw.events);
  });
}
caseEnd();
