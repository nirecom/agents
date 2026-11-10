"use strict";
// Private fixture of tests/hooks/feature-2936-turn-tail-read.js and its #2936 siblings: transcript
// entry builders, JSONL files sized past the first tail window, a byte-counting spy on fs reads, and
// a child process that appends to (or rewrites) a transcript while readTurnTail waits for the flush.
// Self-contained: needs no workflow state, so it loads before or after the caller's isolate().
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const CHILD = path.join(__dirname, "append-child.js");
// The planned first window (S1); the reader's own export is asserted separately.
const W0 = 256 * 1024;

const U = (text, uuid, extra) => Object.assign({ type: "user", uuid, message: { role: "user", content: text } }, extra || {});
const A = (uuid, ...content) => ({ type: "assistant", uuid, message: { role: "assistant", content } });
const T = (text) => ({ type: "text", text });
const TU = (id) => ({ type: "tool_use", id, name: "Bash", input: { command: "true" } });
const TRS = (id, uuid, body) => ({ type: "user", uuid, message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content: body || "ok" }] } });

const jsonl = (entries) => entries.map((e) => JSON.stringify(e)).join("\n") + "\n";

// history(bytes, opts) -> past turns (a prompt, a tool call and an ~8 KB tool_result each) of about
// `bytes` serialized bytes. opts.prompts === false leaves every real prompt out.
function history(bytes, opts) {
  const o = opts || {};
  const out = [];
  const body = "h".repeat(8000);
  let size = 0;
  for (let i = 0; size < bytes; i++) {
    const turn = [A(`a-h${i}`, TU(`t-h${i}`)), TRS(`t-h${i}`, `u-hr${i}`, body), A(`a-ht${i}`, T(`old answer ${i}`))];
    if (o.prompts !== false) turn.unshift(U(`old prompt ${i}`, `u-h${i}`));
    for (const e of turn) { out.push(e); size += JSON.stringify(e).length + 1; }
  }
  return out;
}

let seq = 0;
// write(dir, entries, tail) -> path of a fresh JSONL file; `tail` (a string) is appended raw.
function write(dir, entries, tail) {
  const p = path.join(dir, `t-${process.pid}-${++seq}.jsonl`);
  fs.writeFileSync(p, jsonl(entries) + (tail || ""));
  return p;
}

// fullRead(p) -> {lines, entries, tail}: what a whole-file read yields (the pre-#2936 contract).
function fullRead(TR, p) {
  const lines = TR.readTranscriptLines(p);
  const entries = TR.parseLines(lines);
  return { lines, entries, tail: TR.tailOf(entries) };
}

const key = (x) => JSON.stringify(x);
// isSuffix(part, whole) -> part is whole's last part.length items, item for item.
const isSuffix = (part, whole) => Array.isArray(part) && part.length <= whole.length && key(part) === key(whole.slice(whole.length - part.length));
const uuids = (entries) => (Array.isArray(entries) ? entries.map((e) => e && e.uuid) : []);

// spyReads(target, fn) -> {value, bytes, calls, fullReads}: bytes returned by fs.readSync during fn,
// and every fs.readFileSync of `target` (a whole-file read the bounded reader must not make).
function spyReads(target, fn) {
  const origRS = fs.readSync;
  const origRF = fs.readFileSync;
  const want = path.resolve(target).toLowerCase();
  const seen = { bytes: 0, calls: 0, fullReads: 0 };
  fs.readSync = function (...a) { const n = origRS.apply(fs, a); seen.bytes += n; seen.calls += 1; return n; };
  fs.readFileSync = function (p, ...rest) {
    if (typeof p === "string" && path.resolve(p).toLowerCase() === want) seen.fullReads += 1;
    return origRF.call(fs, p, ...rest);
  };
  try {
    const value = fn();
    return Object.assign({ value }, seen);
  } finally {
    fs.readSync = origRS;
    fs.readFileSync = origRF;
  }
}

// midChar(build, ch) -> the entries build(pad) yields for the first pad that puts the first window's
// start strictly inside one `ch` of the run of `ch` characters (never on a character boundary).
function midChar(build, ch) {
  const cb = Buffer.byteLength(ch);
  const probe = Buffer.from(ch.repeat(4));
  for (let pad = 0; pad < 16; pad++) {
    const entries = build(pad);
    const buf = Buffer.from(jsonl(entries));
    const start = buf.length - W0;
    const runStart = buf.indexOf(probe);
    let runEnd = runStart;
    while (runEnd + cb <= buf.length && buf.subarray(runEnd, runEnd + cb).equals(probe.subarray(0, cb))) runEnd += cb;
    if (runStart >= 0 && start > runStart && start < runEnd && (start - runStart) % cb !== 0) return entries;
  }
  throw new Error("midChar: no pad puts the window start inside a character");
}

// appendLater(mode, file, payload, delayMs) -> Promise resolving once the child is ready; the child
// then waits delayMs and appends `payload` (mode "append") or rewrites the file with it ("rewrite").
// The returned promise's `done` resolves when the child exits.
function appendLater(mode, file, payload, delayMs) {
  const dir = path.dirname(file);
  const payloadFile = path.join(dir, `payload-${++seq}.txt`);
  const ready = path.join(dir, `ready-${seq}`);
  fs.writeFileSync(payloadFile, payload);
  const child = spawn(process.execPath, [CHILD, mode, file, payloadFile, ready, String(delayMs)], { stdio: "ignore" });
  const done = new Promise((resolve) => child.on("exit", resolve));
  const readyP = new Promise((resolve, reject) => {
    const t0 = Date.now();
    const poll = () => {
      if (fs.existsSync(ready)) return resolve();
      if (Date.now() - t0 > 20000) return reject(new Error("append child never became ready"));
      return setTimeout(poll, 5);
    };
    poll();
  });
  return { ready: readyP, done };
}

const tryRequire = (rel) => {
  try { return require(path.join(ROOT, rel)); } catch (e) { return { __missing: (e && (e.code || e.message)) || "load failed" }; }
};

module.exports = { ROOT, W0, U, A, T, TU, TRS, jsonl, history, write, fullRead, isSuffix, uuids, key, spyReads, midChar, appendLater, tryRequire };
