"use strict";
// tests/fixtures/spawn-record-preload/held-results.js — what a held call answers instead of running
// (#2590): a sync call gets an empty success, an async call a child that exits 0 on the next tick.

const { EventEmitter } = require("events");
const { PassThrough } = require("stream");

function emptyOutput(options) {
  const text = options && options.encoding && options.encoding !== "buffer";
  return text ? "" : Buffer.alloc(0);
}

function spawnSyncResult(options) {
  const empty = emptyOutput(options);
  return { pid: 0, output: [null, empty, empty], stdout: empty, stderr: empty, status: 0, signal: null };
}

// A ChildProcess look-alike: ended stdio, then exit(0) and close(0) on the next tick.
function fakeChild(callback, options) {
  const child = new EventEmitter();
  child.pid = 0;
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.stdio = [child.stdin, child.stdout, child.stderr];
  child.exitCode = null;
  child.signalCode = null;
  child.killed = false;
  child.connected = false;
  child.kill = () => true;
  child.send = () => false;
  child.disconnect = () => {};
  child.ref = () => {};
  child.unref = () => {};
  process.nextTick(() => {
    child.stdout.end();
    child.stderr.end();
    child.exitCode = 0;
    child.emit("spawn");
    child.emit("exit", 0, null);
    if (typeof callback === "function") {
      const empty = options && options.encoding === "buffer" ? Buffer.alloc(0) : "";
      callback(null, empty, empty);
    }
    setImmediate(() => child.emit("close", 0, null));
  });
  return child;
}

module.exports = { emptyOutput, spawnSyncResult, fakeChild };
