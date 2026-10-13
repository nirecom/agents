"use strict";
// hooks/lib/jev/two-stage/paths.js — shared pieces of the jev-judge CLI path (#2460): ticket
// ids, the dispatch-time copies dir, the done markers, error stdout, and the test-only crash.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const { sessionDir, readVersioned, writeJsonAtomic } = require("../state-paths");
const { sessionControlDir } = require("../../../workflow-state/state-io/control-dir");

const TICKET_RE = /^[0-9a-f]{16}$/;
const DONE_VERSION = 1;
// Every frozen policy field a ticket must carry before finalize, replay or the sweep uses it.
const FROZEN_FIELDS = Object.freeze(["mode", "recording_owner", "threshold", "short_circuit_answer"]);

const sha256 = (buf) => crypto.createHash("sha256").update(buf).digest("hex");
const own = (o, k) => Boolean(o) && Object.prototype.hasOwnProperty.call(o, k);

function newTicketId() {
  return crypto.randomBytes(8).toString("hex");
}

function sourcesDir(sid, tid, forWrite) {
  return path.join(sessionControlDir(sid, { forWrite: Boolean(forWrite) }), "jev-sources", tid);
}

function removeSources(sid, tid) {
  try {
    fs.rmSync(sourcesDir(sid, tid, false), { recursive: true, force: true });
  } catch (_e) { /* no control dir: nothing to remove */ }
}

function donePath(sid, tid) {
  return path.join(sessionDir(sid), "tickets-done", `${tid}.json`);
}

function readDone(sid, tid) {
  const d = readVersioned(donePath(sid, tid), DONE_VERSION);
  return d && Array.isArray(d.stdout_lines) ? d : null;
}

function writeDone(sid, tid, obj) {
  writeJsonAtomic(donePath(sid, tid), Object.assign({ version: DONE_VERSION }, obj));
}

function errorResult(reason) {
  return { exit: 4, stdout_lines: ["RESULT=error", `REASON=${reason}`] };
}

// Test-only stop at a named boundary (module API only; never reachable from the CLI).
function crash(opts, at) {
  if (opts && opts.crashAt === at) process.exit(99);
}

// The hand's frozen threshold as the decision record's entry shape.
function frozenEntry(hand) {
  return { confidence_threshold_by_answer: hand.threshold, short_circuit_answer: hand.short_circuit_answer };
}

// The entry of a registered point whose stages include stage, else null (CLI argument check).
function pointStageEntry(point, stage, resolveEntry) {
  if (typeof point !== "string" || typeof stage !== "string") return null;
  const entry = resolveEntry(point);
  return entry && Array.isArray(entry.stages) && entry.stages.includes(stage) ? entry : null;
}

// Paths printed on stdout use "/" so a POSIX shell caller can use them as-is.
const slashed = (p) => String(p).replace(/\\/g, "/");

// A ticket hand is usable when it is a cli-ticket of a registered point and stage carrying
// every frozen field; the registry is consulted for registration only, never for policy.
function validHand(hand, resolveEntry) {
  if (!hand || typeof hand !== "object" || hand.kind !== "cli-ticket") return null;
  const entry = pointStageEntry(hand.point, hand.stage, resolveEntry);
  if (!entry) return null;
  if (!FROZEN_FIELDS.every((k) => own(hand, k) && hand[k] !== undefined)) return null;
  if (!hand.threshold || typeof hand.threshold !== "object") return null;
  return entry;
}

module.exports = {
  TICKET_RE, DONE_VERSION, FROZEN_FIELDS, sha256, own, newTicketId, sourcesDir, removeSources,
  donePath, readDone, writeDone, errorResult, crash, frozenEntry, pointStageEntry, slashed, validHand,
};
