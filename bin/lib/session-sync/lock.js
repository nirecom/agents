"use strict";
// Cross-process lock at <projects>/.git/agents-session-sync.lock (#2658).

const fs = require("node:fs");
const path = require("node:path");

const LOCK_NAME = "agents-session-sync.lock";
const STALE_MS = 10 * 60 * 1000;
const POLL_MS = 200;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function holderAlive(file) {
  let pid = NaN;
  try {
    pid = Number(JSON.parse(fs.readFileSync(file, "utf8")).pid);
  } catch (_) {
    return false;
  }
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === "EPERM";
  }
}

function isStale(file) {
  try {
    const age = Date.now() - fs.statSync(file).mtimeMs;
    return age > STALE_MS && !holderAlive(file);
  } catch (_) {
    return false;
  }
}

function tryCreate(file) {
  try {
    fs.writeFileSync(file, JSON.stringify({ pid: process.pid, time: new Date().toISOString() }), { flag: "wx" });
    return true;
  } catch (e) {
    if (e.code !== "EEXIST") throw e;
    return false;
  }
}

async function acquire(gitDir, { waitMs = 0 } = {}) {
  const file = path.join(gitDir, LOCK_NAME);
  const until = Date.now() + waitMs;
  for (;;) {
    if (tryCreate(file)) break;
    if (isStale(file)) {
      fs.rmSync(file, { force: true });
      continue;
    }
    if (Date.now() >= until) return null;
    await sleep(Math.min(POLL_MS, Math.max(1, until - Date.now())));
  }
  let released = false;
  return {
    file,
    release: async () => {
      if (released) return;
      released = true;
      fs.rmSync(file, { force: true });
    },
  };
}

module.exports = { LOCK_NAME, acquire };
