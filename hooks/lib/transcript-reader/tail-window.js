"use strict";
// hooks/lib/transcript-reader/tail-window.js — the byte window behind readTurnTail (#2936). It reads
// the transcript from its end, TAIL_INITIAL_BYTES first and x4 per growth up to BOF, reading only the
// bytes not read yet, and later only what was appended. Bytes are cut at 0x0A before each line is
// decoded: 0x0A never occurs inside a UTF-8 multibyte character, so no character is split.
// A window is {lines, entries, span: {start, end, pending}, complete}: [start, end) holds whole lines;
// pending marks one unterminated last line, parsed when it can be but never committed (end stays).

const fs = require("fs");

const TAIL_INITIAL_BYTES = 256 * 1024;
const GROWTH = 4;
const NL = 0x0a;

function parseLine(line) {
  try {
    const e = JSON.parse(line);
    return e && typeof e === "object" ? e : null;
  } catch (_) {
    return null;
  }
}

// readRange(file, start, end) -> the bytes of [start, end); a short read returns what was read.
function readRange(file, start, end) {
  const buf = Buffer.alloc(Math.max(0, end - start));
  if (buf.length === 0) return buf;
  const fd = fs.openSync(file, "r");
  try {
    let got = 0;
    while (got < buf.length) {
      const n = fs.readSync(fd, buf, got, buf.length - got, start + got);
      if (n <= 0) break;
      got += n;
    }
    return got === buf.length ? buf : buf.subarray(0, got);
  } finally {
    fs.closeSync(fd);
  }
}

function sizeOf(file) {
  const fd = fs.openSync(file, "r");
  try {
    return fs.fstatSync(fd).size;
  } finally {
    fs.closeSync(fd);
  }
}

// linesOf(buf) -> {lines, entries} of the non-empty lines of buf, split at 0x0A.
function linesOf(buf) {
  const lines = [];
  const entries = [];
  for (let at = 0; at < buf.length;) {
    const nl = buf.indexOf(NL, at);
    const stop = nl === -1 ? buf.length : nl;
    const s = buf.toString("utf8", at, stop);
    if (s.trim() !== "") {
      lines.push(s);
      const e = parseLine(s);
      if (e) entries.push(e);
    }
    at = stop + 1;
  }
  return { lines, entries };
}

// pendingOf(buf) -> {line, entry} of the unterminated last line, or null when it is blank.
function pendingOf(buf) {
  const s = buf.toString("utf8");
  if (s.trim() === "") return null;
  return { line: s, entry: parseLine(s) };
}

function build(committed, pending, span, complete) {
  const lines = committed.lines.slice();
  const entries = committed.entries.slice();
  if (pending) {
    lines.push(pending.line);
    if (pending.entry) entries.push(pending.entry);
  }
  return { lines, entries, span: Object.assign({}, span, { pending: !!pending }), complete };
}

// readWindow(file, {deadlineAt, boundary}) -> a window, or null when the file cannot be read.
// boundary() returns a fresh reached(batch), fed each newly read batch of entries once (later
// batches lie earlier in the file), true once the window holds every boundary the caller needs.
// The first window is always read; no growth starts at or past deadlineAt (complete false).
function readWindow(file, { deadlineAt, boundary } = {}) {
  try {
    if (typeof file !== "string" || !file) return null;
    const size = sizeOf(file);
    const reached = typeof boundary === "function" ? boundary() : () => true;
    let committed = { lines: [], entries: [] };
    let pending = null;
    let head = size;
    let end = null;
    let windowBytes = TAIL_INITIAL_BYTES;
    for (let first = true; ; first = false) {
      if (!first && Number.isFinite(deadlineAt) && Date.now() >= deadlineAt) {
        return build(committed, pending, { start: head, end }, false);
      }
      const start = Math.max(0, size - windowBytes);
      const chunk = readRange(file, start, head);
      let from = 0;
      if (start > 0) {
        const nl = chunk.indexOf(NL);
        from = nl === -1 ? -1 : nl + 1;
      }
      if (from !== -1) {
        let body = chunk.subarray(from);
        let batchPending = null;
        if (end === null) {
          const last = body.lastIndexOf(NL);
          batchPending = pendingOf(body.subarray(last + 1));
          end = start + from + last + 1;
          body = body.subarray(0, last + 1);
          pending = batchPending;
        }
        const got = linesOf(body);
        committed = { lines: got.lines.concat(committed.lines), entries: got.entries.concat(committed.entries) };
        head = start + from;
        const batch = batchPending && batchPending.entry ? got.entries.concat([batchPending.entry]) : got.entries;
        if (reached(batch) || start === 0) return build(committed, pending, { start: head, end }, true);
      }
      windowBytes *= GROWTH;
    }
  } catch (_) {
    return null;
  }
}

// appendWindow(file, win, want) -> win extended by the bytes appended after win.span.end, a fresh
// readWindow when the file shrank below it (rewritten) or win has no whole line, or null when the
// file cannot be read.
function appendWindow(file, win, want) {
  try {
    const span = win && win.span;
    if (!span || !Number.isInteger(span.end)) return readWindow(file, want);
    const size = sizeOf(file);
    if (size < span.end) return readWindow(file, want);
    const lines = win.lines.slice();
    const entries = win.entries.slice();
    if (span.pending) {
      const line = lines.pop();
      if (parseLine(line)) entries.pop();
    }
    const chunk = readRange(file, span.end, size);
    const last = chunk.lastIndexOf(NL);
    const got = linesOf(chunk.subarray(0, last + 1));
    const pending = pendingOf(chunk.subarray(last + 1));
    const committed = { lines: lines.concat(got.lines), entries: entries.concat(got.entries) };
    return build(committed, pending, { start: span.start, end: span.end + last + 1 }, win.complete);
  } catch (_) {
    return null;
  }
}

module.exports = { TAIL_INITIAL_BYTES, readWindow, appendWindow };
