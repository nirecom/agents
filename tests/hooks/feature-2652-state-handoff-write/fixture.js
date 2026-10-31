"use strict";
// Fixture helpers for tests/hooks/feature-2652-state-handoff-write.js. Records are placed with
// tests/lib/state-handoff-record-fixture.js (raw writes, never through the entry under test), and
// every byte count is measured here independently of the schema module under test.

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const F = require("../../lib/state-handoff-record-fixture");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const { sanitizeUntrustedField } = require(path.join(ROOT, "hooks", "lib", "output-sanitize"));
const CHILD = path.join(__dirname, "child.js");
const AT = "2026-10-28T00:00:00.000Z"; // the 24-character `at` every stored record carries

// storedBytes(ev) — compact UTF-8 bytes with the seq replaced by a 10-digit number (the plan's measure).
const storedBytes = (ev) => Buffer.byteLength(JSON.stringify(Object.assign({}, ev, { seq: 1000000000 })), "utf8");
const compactBytes = (ev) => Buffer.byteLength(JSON.stringify(ev), "utf8");

const readState = (sid) => JSON.parse(fs.readFileSync(F.statePath(sid), "utf8"));
const records = (sid) => readState(sid).events.filter((e) => e.kind === "state_handoff_record");
const bytesOf = (sid) => (fs.existsSync(F.statePath(sid)) ? fs.readFileSync(F.statePath(sid)) : null);

// storedShape(input) — the event the entry is expected to store for `input`, before any truncation.
function storedShape(input) {
  return {
    kind: "state_handoff_record", cls: input.cls, at_step: input.step,
    record_key: input.key, summary: sanitizeUntrustedField(input.summary, 300),
    pointer: sanitizeUntrustedField(input.pointer, 300), origin: input.origin,
    provenance: input.origin === "procedure-point" ? "declared" : "observed", at: AT,
  };
}

// filler(i, size) — an own record whose storedBytes is exactly `size` (ASCII padding in the summary).
function filler(i, size) {
  const base = F.record({ cls: "F", at_step: "write_tests", record_key: `filler.${i}`, summary: "", pointer: "-", origin: "auto-record", at: AT });
  const pad = size - storedBytes(base);
  if (pad < 0 || pad > 300) throw new Error(`fixture: filler size ${size} not reachable (pad ${pad})`);
  return Object.assign(base, { summary: "x".repeat(pad) });
}

// fillTo(sid, total) — places own records whose storedBytes sum to exactly `total`; returns their count.
function fillTo(sid, total) {
  const evs = [];
  let left = total;
  while (left > 880) { evs.push(filler(evs.length, 440)); left -= 440; }
  if (left > 0) {
    const half = Math.floor(left / 2);
    evs.push(filler(evs.length, half));
    evs.push(filler(evs.length, left - half));
  }
  const sum = evs.reduce((s, e) => s + storedBytes(e), 0);
  if (sum !== total) throw new Error(`fixture: fillers sum to ${sum}, not ${total}`);
  F.pushEvents(sid, evs);
  return evs.length;
}

function runChild(args, timeout) {
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_CODE_SESSION_ID;
  const started = Date.now();
  const r = spawnSync(process.execPath, [CHILD].concat(args), { env, encoding: "utf8", timeout: timeout || 60000 });
  let out = null;
  try { out = JSON.parse(String(r.stdout || "").trim().split("\n").pop()); } catch (e) { out = null; }
  return { out, status: r.status, stderr: String(r.stderr || ""), elapsed: Date.now() - started, raw: String(r.stdout || "").slice(0, 300) };
}

module.exports = { F, AT, storedBytes, compactBytes, readState, records, bytesOf, storedShape, filler, fillTo, runChild };
