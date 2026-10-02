"use strict";
// hooks/lib/read-stdin.js — EOF-safe hook stdin reader shared by hooks (#2479, #1810).
// Never prints and never exits: callers decide fail-open vs fail-close.
// Every chunk is copied out of the reused read buffer: a slice aliases it, so a
// later read overwrote earlier chunks and corrupted multi-chunk payloads.
// The EAGAIN budget is wall-clock (hrtime), not a retry count, because Windows
// timer granularity (~15 ms) makes the 1 ms wait length unpredictable; it measures
// consecutive unreadable time and restarts after every successful read.

const fs = require("fs");

const BUF_SIZE = 65536;
const DEFAULT_EAGAIN_BUDGET_MS = 5000;
const RETRY_WAIT_MS = 1;
const waitCell = new Int32Array(new SharedArrayBuffer(4));

function pause() {
  Atomics.wait(waitCell, 0, 0, RETRY_WAIT_MS);
}

function readAll(fd, readSyncImpl = fs.readSync, opts = {}) {
  const budgetMs = (opts && opts.eagainBudgetMs) ?? DEFAULT_EAGAIN_BUDGET_MS;
  const buf = Buffer.alloc(BUF_SIZE);
  const chunks = [];
  let eagainStart = null;
  for (;;) {
    let n;
    try {
      n = readSyncImpl(fd, buf, 0, buf.length, null);
    } catch (e) {
      const code = e && e.code;
      if (code === "EOF") break;
      if (code === "EAGAIN") {
        const now = process.hrtime.bigint();
        if (eagainStart === null) eagainStart = now;
        if (Number(now - eagainStart) / 1e6 > budgetMs) {
          const error = new Error("stdin read stalled: EAGAIN beyond " + budgetMs + " ms");
          error.code = "EAGAIN";
          return { kind: "read-error", error };
        }
        pause();
        continue;
      }
      if (code === "EINTR") {
        pause();
        continue;
      }
      return { kind: "read-error", error: e };
    }
    if (n === 0) break;
    eagainStart = null;
    chunks.push(Buffer.from(buf.subarray(0, n)));
  }
  return { kind: "ok", text: Buffer.concat(chunks).toString("utf8") };
}

function readStdinText() {
  return readAll(0, fs.readSync, {});
}

function readHookInput() {
  const r = readStdinText();
  if (r.kind !== "ok") return r;
  if (r.text.trim() === "") return { kind: "json-invalid", text: "", error: new Error("empty stdin") };
  try {
    return { kind: "ok", input: JSON.parse(r.text), text: r.text };
  } catch (error) {
    return { kind: "json-invalid", text: r.text, error };
  }
}

function errorCode(error) {
  return (error && (error.code || error.name)) || "unknown";
}

function readFailureReason(hookName, error) {
  return `[${hookName}] stdin read-error (${errorCode(error)}): hook input unreadable; blocking (fail-close)`;
}

function readFailOpenDiagnostic(hookName, result, effect = "hook skipped") {
  if (!result || result.kind === "ok") return null;
  if (result.kind === "read-error") {
    return `[${hookName}] stdin read-error (${errorCode(result.error)}): ${effect} (fail-open)`;
  }
  const text = typeof result.text === "string" ? result.text : "";
  const detail = text === "" ? "0 bytes, empty" : `${Buffer.byteLength(text, "utf8")} bytes, ${(result.error && result.error.name) || "unknown"}`;
  return `[${hookName}] stdin json-invalid (${detail}): ${effect} (fail-open)`;
}

module.exports = { readAll, readStdinText, readHookInput, readFailureReason, readFailOpenDiagnostic };
