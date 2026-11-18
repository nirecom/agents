"use strict";
// Windows rename retry (#3094): replacing a file another process holds open fails with a transient
// EPERM; retry it with backoff until a deadline, then rethrow the last original error unchanged.
// Leaf module (requires only fs): mirrors state-lock.js's acquire EPERM retry without importing it.
// fs.renameSync and process.platform are read at call time so tests can stub them.

const fs = require("fs");

// Measured retry success took up to 407ms (#3094); state-lock.js's 500ms leaves too little margin.
const RENAME_EPERM_RETRY_MS = 750;
const MIN_BACKOFF_MS = 5;
const MAX_BACKOFF_MS = 25;
const RETRY_ERRNO = "EPERM";

function sleepSync(ms) {
  const view = new Int32Array(new SharedArrayBuffer(4));
  Atomics.wait(view, 0, 0, ms);
}

function backoffMs() {
  return MIN_BACKOFF_MS + Math.floor(Math.random() * (MAX_BACKOFF_MS - MIN_BACKOFF_MS));
}

const retryable = (e) => process.platform === "win32" && e && e.code === RETRY_ERRNO;

function renameWithRetry(from, to) {
  try {
    fs.renameSync(from, to);
    return;
  } catch (e) {
    if (!retryable(e)) throw e;
  }
  const deadline = Date.now() + RENAME_EPERM_RETRY_MS;
  for (;;) {
    sleepSync(backoffMs());
    try {
      fs.renameSync(from, to);
      return;
    } catch (e) {
      if (!retryable(e) || Date.now() >= deadline) throw e;
    }
  }
}

module.exports = { renameWithRetry, RENAME_EPERM_RETRY_MS };
