"use strict";
// bin/lib/codex-review-loop/review-rounds-store.js — the only owner of the review record file and
// its side files (#2938 D1 / D2 / D2a). Everything lives in the control dir of the first sid of
// the session chain; appendRow is the only writer of a row.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const rounds = require("./review-rounds");
const { readInterval } = require("./state-interval");

const HOOKS = path.resolve(__dirname, "..", "..", "..", "hooks");
const LOCK_WAIT_MS = 10000;
const LOCK_STALE_MS = 60000;

class StoreError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const firstSid = (sid) => require(path.join(HOOKS, "workflow-state", "state-ancestry")).resolveFirstSid(sid);

// files(sid, format, {forWrite}) — every path of the record of format, in the first sid's control dir.
function files(sid, format, opts) {
  if (typeof format !== "string" || !/^[a-z][a-z-]*$/.test(format)) throw new StoreError(4, `invalid format: ${format}`);
  const cd = require(path.join(HOOKS, "workflow-state", "state-io", "control-dir"));
  const fsid = firstSid(sid);
  const dir = opts && opts.forWrite ? cd.sessionControlDir(fsid, { forWrite: true }) : cd.getSessionControlDir(fsid);
  const base = path.join(dir, `${format}-review-rounds`);
  return {
    dir, firstSid: fsid,
    record: path.join(dir, `${format}-review-rounds.jsonl`),
    lock: path.join(dir, `${format}-review-rounds.jsonl.lock`),
    // Left by the CC-fallback route retired in #2478; preflight only detects and deletes them.
    legacy: [`${base}-fallback-pending.json`, `${base}-fallback-discarded.json`],
    unrecorded: `${base}-unrecorded.jsonl`,
    gapAccepted: `${base}-gap-accepted.jsonl`,
    inflightRe: new RegExp(`^${format}-review-rounds-inflight-([0-9a-f]+)\\.json$`),
    inflight: (runId) => `${base}-inflight-${runId}.json`,
  };
}

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const nowIso = () => new Date().toISOString();
const exists = (p) => { try { fs.lstatSync(p); return true; } catch { return false; } };

function withLock(lockPath, fn) {
  const deadline = Date.now() + LOCK_WAIT_MS;
  for (;;) {
    try {
      fs.closeSync(fs.openSync(lockPath, "wx"));
      break;
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      try {
        if (Date.now() - fs.statSync(lockPath).mtimeMs > LOCK_STALE_MS) { fs.rmSync(lockPath, { force: true }); continue; }
      } catch { /* the holder released it meanwhile */ }
      if (Date.now() > deadline) throw new StoreError(4, `review record lock is held: ${lockPath}`);
      sleep(25);
    }
  }
  try { return fn(); } finally { fs.rmSync(lockPath, { force: true }); }
}

// readRows(sid, format, {strict}) -> {parsed, unreadable}. A missing record is empty; strict
// rethrows any other read error (an unreadable record cannot derive anything).
function readRows(sid, format, opts) {
  let text = "";
  try {
    text = fs.readFileSync(files(sid, format).record, "utf8");
  } catch (e) {
    if (e.code !== "ENOENT" && opts && opts.strict) throw e;
  }
  const parsed = [];
  let unreadable = 0;
  for (const l of text.split(/\r?\n/)) {
    if (!l.trim()) continue;
    try { parsed.push(JSON.parse(l)); } catch { unreadable += 1; }
  }
  return { parsed, unreadable, torn: text.length > 0 && !text.endsWith("\n") };
}

// hasRun({sid, format, runId}) — whether a row of runId is in the record (#2478 C1). A missing
// record holds none; an unreadable one cannot answer and is a HALT (4).
function hasRun({ sid, format, runId }) {
  let rows;
  try {
    rows = readRows(sid, format, { strict: true }).parsed;
  } catch (e) {
    if (e instanceof StoreError) throw e;
    throw new StoreError(4, `the review record cannot be read (${e.message})`);
  }
  return rows.some((r) => r && r.run_id === runId);
}

const lastRow = (parsed) => {
  for (let i = parsed.length - 1; i >= 0; i--) {
    const r = parsed[i];
    if (r && Number.isInteger(r.loop_cycle) && Number.isInteger(r.row_no)) return r;
  }
  return null;
};

// appendRow(input) — input: {sid, format, counter_round, exit, verdict, source, run_id,
// fingerprint, writer_sid, state_sid, untilSeq, untilAt, skipIf?}. untilSeq null
// reads to the stream head; skipIf(parsed) returning a row skips the append under the same lock.
function appendRow(input) {
  const f = files(input.sid, input.format, { forWrite: true });
  return withLock(f.lock, () => {
    const cur = readRows(input.sid, input.format, { strict: true });
    const hit = input.skipIf ? input.skipIf(cur.parsed) : null;
    if (hit) return hit;
    const prev = lastRow(cur.parsed);
    const untilAt = input.untilAt || nowIso();
    const iv = readInterval(input.state_sid, prev ? prev.event_seq : 0, input.untilSeq === undefined ? null : input.untilSeq,
      { format: input.format, sinceAt: prev ? prev.at : null, untilAt });
    const c = rounds.classify(prev, input, iv);
    const eventSeq = Number.isInteger(input.untilSeq) ? input.untilSeq : iv.state === "present" ? iv.head_seq : null;
    const row = {
      schema_version: 1, format: input.format, loop_cycle: c.loop_cycle, row_no: c.row_no,
      counter_round: input.counter_round, kind: c.kind, route: c.route, interval_basis: c.interval_basis,
      interval_kinds: c.interval_kinds, state_sid: input.state_sid, event_seq: eventSeq,
      fingerprint: c.fingerprint, fingerprint_changed: c.fingerprint_changed, verdict: input.verdict,
      exit: input.exit === undefined ? null : input.exit, source: input.source, run_id: input.run_id || null,
      writer_sid: input.writer_sid || input.sid, at: untilAt,
    };
    fs.appendFileSync(f.record, (cur.torn ? "\n" : "") + JSON.stringify(row) + "\n");
    return row;
  });
}

const headSeq = (sid) => {
  const iv = readInterval(sid, 0, null, {});
  return iv.state === "present" ? iv.head_seq : null;
};

function readJson(p) {
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

// discardLegacy(f) — delete a pending / discarded file of the retired CC-fallback route (#2478).
// Its round was never counted, so counter and rows stay untouched; an undeletable one is a HALT.
function discardLegacy(f) {
  for (const p of f.legacy) {
    if (!exists(p)) continue;
    try {
      fs.rmSync(p, { force: true });
    } catch (e) {
      throw new StoreError(4, `a legacy CC-fallback pending cannot be deleted (${p}): ${e.message}`);
    }
    process.stderr.write(`review-rounds: discarded a legacy CC-fallback pending (${p}); its round was never counted — re-run the review\n`);
  }
}

const listInflight = (f) => fs.readdirSync(f.dir).map((n) => f.inflightRe.exec(n)).filter(Boolean)
  .map((m) => ({ runId: m[1], path: path.join(f.dir, m[0]) }));

function readUnrecorded(f) {
  let text;
  try { text = fs.readFileSync(f.unrecorded, "utf8"); } catch (e) {
    if (e.code === "ENOENT") return [];
    throw e;
  }
  return text.split(/\r?\n/).filter((l) => l.trim()).map((l) => JSON.parse(l));
}

function acceptGap({ sid, format, reason }) {
  const f = files(sid, format, { forWrite: true });
  const at = nowIso();
  const lines = readUnrecorded(f).map((entry) => ({ kind: "unrecorded", entry }));
  const infl = listInflight(f);
  for (const i of infl) {
    let entry;
    try { entry = readJson(i.path); } catch { entry = { run_id: i.runId }; }
    lines.push({ kind: "inflight", entry });
  }
  if (lines.length) {
    fs.appendFileSync(f.gapAccepted, lines.map((l) => JSON.stringify(Object.assign(l, { reason, accepted_at: at, accepted_by: sid }))).join("\n") + "\n");
  }
  fs.rmSync(f.unrecorded, { force: true });
  for (const i of infl) fs.rmSync(i.path, { force: true });
  return lines.length;
}

const GAP_EXIT = (sid, format) => `fix the cause and re-run, or (with the user's approval) node "<agents root>/bin/review-rounds" accept-gap --session ${sid} --format ${format} --reason "<text>"`;

// preflight — D2a steps 1-5; returns the run_id of this run.
function preflight({ sid, format }) {
  const f = files(sid, format, { forWrite: true });
  // fstat as well: Windows opens a directory for append without an error.
  try {
    const fd = fs.openSync(f.record, "a");
    try {
      if (!fs.fstatSync(fd).isFile()) throw new Error("not a regular file");
    } finally { fs.closeSync(fd); }
  } catch (e) {
    throw new StoreError(4, `the review record cannot be opened for append (${f.record}): ${e.message}`);
  }
  const parked = readUnrecorded(f);
  for (let i = 0; i < parked.length; i++) {
    const u = parked[i];
    const known = readRows(sid, format).parsed.some((r) => r && u.run_id && r.run_id === u.run_id);
    if (known) continue;
    try {
      appendRow(Object.assign({}, u, { sid, untilSeq: u.event_seq, untilAt: u.confirmed_at }));
    } catch (e) {
      writeJsonLines(f.unrecorded, parked.slice(i));
      throw new StoreError(4, `a parked review record row cannot be replayed (${e.message}); ${GAP_EXIT(sid, format)}`);
    }
  }
  fs.rmSync(f.unrecorded, { force: true });
  const runIds = new Set(readRows(sid, format).parsed.map((r) => r && r.run_id).filter(Boolean));
  for (const i of listInflight(f)) {
    if (runIds.has(i.runId)) { fs.rmSync(i.path, { force: true }); continue; }
    throw new StoreError(4, `run ${i.runId} may have committed a round that the review record does not hold (${i.path}); ${GAP_EXIT(sid, format)}`);
  }
  discardLegacy(f);
  const runId = crypto.randomBytes(8).toString("hex");
  fs.writeFileSync(f.inflight(runId), JSON.stringify({ run_id: runId, writer_sid: sid, at: nowIso() }) + "\n", { flag: "wx" });
  return runId;
}

function writeJsonLines(p, list) {
  const tmp = `${p}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, list.map((x) => JSON.stringify(x)).join("\n") + "\n");
  fs.renameSync(tmp, p);
}

function closeInflight({ sid, format, runId }) {
  if (!/^[0-9a-f]+$/.test(runId || "")) return;
  fs.rmSync(files(sid, format).inflight(runId), { force: true });
}

// appendFromWrapper — a committed wrapper round: the row, else the parked input (code 5), else 4.
// noPark (a CC-fallback round, #2478): a failed append parks nothing and is 4, since the loop undoes
// the round. The inflight is closed after the write; a close failure after a landed row only warns.
function appendFromWrapper(input) {
  const confirmedAt = nowIso();
  const full = Object.assign({ writer_sid: input.sid, state_sid: input.sid, untilSeq: null, untilAt: confirmedAt }, input);
  delete full.noPark;
  const close = () => closeInflight({ sid: input.sid, format: input.format, runId: input.run_id });
  let row;
  try {
    row = appendRow(full);
  } catch (e) {
    if (input.noPark) {
      try { close(); } catch { /* preflight halts on the leftover inflight; accept-gap is its exit */ }
      throw new StoreError(4, `the review record append failed (${e.message}); the row is not parked (--no-park)`);
    }
    const parked = {
      format: input.format, counter_round: input.counter_round, exit: input.exit, verdict: input.verdict,
      source: input.source, run_id: input.run_id || null, fingerprint: input.fingerprint || null,
      state_sid: full.state_sid, event_seq: headSeq(full.state_sid), confirmed_at: confirmedAt, writer_sid: full.writer_sid,
    };
    try {
      fs.appendFileSync(files(input.sid, input.format).unrecorded, JSON.stringify(parked) + "\n");
    } catch (e2) {
      throw new StoreError(4, `the review record append failed (${e.message}) and the row could not be parked (${e2.message})`);
    }
    try { close(); } catch { /* the parked row carries the run_id; preflight skips a known one */ }
    throw new StoreError(5, `the review record append failed (${e.message}); the row is parked in ${files(input.sid, input.format).unrecorded}`);
  }
  try {
    close();
  } catch (e) {
    process.stderr.write(`review-rounds: the row is recorded but the inflight of run ${input.run_id} could not be closed (${e.message})\n`);
  }
  return row;
}

module.exports = {
  StoreError, files, readRows, hasRun, appendRow, appendFromWrapper, acceptGap, preflight, closeInflight,
};
