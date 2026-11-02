"use strict";
// --- BEGIN temporary: jev-decisions.log -> jev-decisions.jsonl migration added 2026-11-01 ---
// deletion-condition: no jev-decisions.log* remains under resolveLogDir() on any host
// Moves the old decision log and its rotated generations to the new name, once, and only
// while no new-name file exists (a new file means the move already happened or a newer
// writer started fresh: the old file is then left for the operator, never merged).
const fs = require("fs");
const path = require("path");
const { withLock, DEFAULT_MAX_ROTATED } = require("../jsonl-rotating-log");

const OLD_NAME = "jev-decisions.log";
const NEW_NAME = "jev-decisions.jsonl";
const done = new Set();

const generations = (base) => [base].concat(Array.from({ length: DEFAULT_MAX_ROTATED }, (_v, i) => `${base}.${i + 1}`));

function moveUnderLock(oldBase, newBase) {
  if (generations(newBase).some((f) => fs.existsSync(f))) return;
  generations(oldBase).forEach((from, i) => {
    if (fs.existsSync(from)) fs.renameSync(from, generations(newBase)[i]);
  });
}

// migrateOnce(logDir) — best effort: a failure leaves the old files and the append goes on.
function migrateOnce(logDir) {
  if (typeof logDir !== "string" || done.has(logDir)) return;
  const oldBase = path.join(logDir, OLD_NAME);
  const newBase = path.join(logDir, NEW_NAME);
  try {
    if (!generations(oldBase).some((f) => fs.existsSync(f))) {
      done.add(logDir);
      return;
    }
    fs.mkdirSync(logDir, { recursive: true });
    // The append lock is not re-entrant, so the move takes its own lock.
    withLock(`${newBase}.migrate.lock`, {}, () => moveUnderLock(oldBase, newBase));
    done.add(logDir);
  } catch (_e) { /* retried by the next append of this process */ }
}

module.exports = { migrateOnce, OLD_NAME, NEW_NAME };
// --- END temporary: jev-decisions.log -> jev-decisions.jsonl migration ---
