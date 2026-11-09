"use strict";
// --require preload for tests/hooks/feature-2936-stop-budget-kill.js: counts what the hook process
// reads from one file (CC_READ_TARGET) and writes {bytes, fullReads} to CC_READ_LOG on exit.
// bytes: every byte read from the file (fs.readSync on an fd opened on it, or fs.readFileSync of it);
// fullReads: the fs.readFileSync calls of it, i.e. whole-file reads the bounded reader must not make.
const fs = require("fs");
const path = require("path");

const target = process.env.CC_READ_TARGET ? path.resolve(process.env.CC_READ_TARGET).toLowerCase() : "";
const log = process.env.CC_READ_LOG || "";
if (target && log) {
  const seen = { bytes: 0, fullReads: 0, readSyncCalls: 0 };
  const fds = new Set();
  let inWhole = 0;
  const isTarget = (p) => (typeof p === "string" || p instanceof URL || Buffer.isBuffer(p)) && path.resolve(String(p)).toLowerCase() === target;
  const origOpen = fs.openSync;
  const origClose = fs.closeSync;
  const origRead = fs.readSync;
  const origWhole = fs.readFileSync;
  fs.openSync = function (p, ...rest) {
    const fd = origOpen.call(fs, p, ...rest);
    if (isTarget(p)) fds.add(fd);
    return fd;
  };
  fs.closeSync = function (fd) {
    fds.delete(fd);
    return origClose.call(fs, fd);
  };
  fs.readSync = function (fd, ...rest) {
    const n = origRead.call(fs, fd, ...rest);
    if (!inWhole && fds.has(fd)) { seen.bytes += n; seen.readSyncCalls += 1; }
    return n;
  };
  fs.readFileSync = function (p, ...rest) {
    const whole = isTarget(p) || (typeof p === "number" && fds.has(p));
    inWhole += 1;
    try {
      const out = origWhole.call(fs, p, ...rest);
      if (whole) { seen.fullReads += 1; seen.bytes += Buffer.byteLength(out); }
      return out;
    } finally {
      inWhole -= 1;
    }
  };
  process.on("exit", () => {
    try { origWhole && fs.writeFileSync(log, JSON.stringify(seen)); } catch (_) { /* the test then reads no log */ }
  });
}
