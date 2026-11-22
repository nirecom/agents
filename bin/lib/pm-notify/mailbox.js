"use strict";
// The PM mailboxes (#2942): <state root>/pm-mailbox/<tag>.jsonl, one notification JSON object per line,
// each with a unique id. The caller holds the PM lock for every write.
//   readBox(name) -> [entry]; an unreadable line is dropped.
//   moveMailbox(from, to) — merges from's entries into to's (deduplicated by id; a retry after an
//     interrupted move adds nothing twice), then removes from's file.
//   deliver(name, entry) — appends entry unless its id is in the box already.

const fs = require("fs");
const path = require("path");
const { listStateRoots } = require("../../../hooks/workflow-state/state-io/state-root");

const BOX_DIR = "pm-mailbox";
const NAME_RE = /^[A-Za-z0-9-]{1,40}$/;

function boxPath(name) {
  if (!NAME_RE.test(String(name))) throw new Error(`invalid mailbox name: ${name}`);
  return path.join(listStateRoots()[0], BOX_DIR, `${name}.jsonl`);
}

function readBox(name) {
  let raw;
  try { raw = fs.readFileSync(boxPath(name), "utf8"); } catch (e) {
    if (e.code === "ENOENT") return [];
    throw e;
  }
  const out = [];
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try { const e = JSON.parse(line); if (e && typeof e === "object") out.push(e); } catch (_) { /* a torn line */ }
  }
  return out;
}

// writeBox(name, entries) — replaces the file atomically (temp file + rename).
function writeBox(name, entries) {
  const file = boxPath(name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, entries.map((e) => `${JSON.stringify(e)}\n`).join(""));
  fs.renameSync(tmp, file);
}

function moveMailbox(from, to) {
  const moving = readBox(from);
  if (moving.length > 0) {
    const target = readBox(to);
    const ids = new Set(target.map((e) => e.id));
    const merged = target.slice();
    for (const e of moving) {
      if (ids.has(e.id)) continue;
      ids.add(e.id);
      merged.push(e);
    }
    writeBox(to, merged);
  }
  fs.rmSync(boxPath(from), { force: true });
}

// deliver(name, entry) -> false when the box already holds entry.id (a retried settle adds nothing twice).
function deliver(name, entry) {
  const box = readBox(name);
  if (box.some((e) => e.id === entry.id)) return false;
  writeBox(name, box.concat([entry]));
  return true;
}

module.exports = { boxPath, readBox, writeBox, moveMailbox, deliver };
