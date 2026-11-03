#!/usr/bin/env node
"use strict";
// Stop hook (#2877): tells the user, once, about a sentinel of this turn that workflow-mark.js
// never applied — the cases its own strong channel cannot cover (a hook timeout, a call that never
// reached it, a run that stopped mid-way). Notice only: systemMessage, never a decision. Fails open.

const fs = require("fs");
const { readHookInput } = require("./lib/read-stdin");
const { readTurnTail } = require("./lib/transcript-reader");
const { readReceipts } = require("./lib/sentinel-receipt");
const { scanTurn, buildNotice } = require("./stop-sentinel-unapplied-notice/scan");

const NOTIFIED_FILE = "sentinel-unapplied-notified.jsonl";

function notifiedIds(sid) {
  const ids = new Set();
  try {
    const { controlPath } = require("./workflow-state/state-io/control-dir");
    for (const line of fs.readFileSync(controlPath(sid, NOTIFIED_FILE), "utf8").split("\n")) {
      try { ids.add(JSON.parse(line).tool_use_id); } catch (_e) { /* skip a broken line */ }
    }
  } catch (_e) { /* nothing told yet */ }
  return ids;
}

function markNotified(sid, items) {
  try {
    const { controlPath } = require("./workflow-state/state-io/control-dir");
    const file = controlPath(sid, NOTIFIED_FILE, { forWrite: true });
    fs.appendFileSync(file, items.map((i) => JSON.stringify({ tool_use_id: i.id, kind: i.kind }) + "\n").join(""));
  } catch (_e) { /* a lost cursor only repeats a notice */ }
}

function main() {
  const hookInput = readHookInput();
  if (hookInput.kind !== "ok") return;
  const input = hookInput.input || {};
  const sid = typeof input.session_id === "string" ? input.session_id : "";
  if (!sid || typeof input.transcript_path !== "string" || input.transcript_path === "") return;
  const { readState } = require("./workflow-state");
  if (!readState(sid)) return;
  const { lines } = readTurnTail({ input });
  const told = notifiedIds(sid);
  const items = scanTurn(lines, readReceipts(sid)).filter((i) => !told.has(i.id));
  const notice = buildNotice(items);
  if (!notice) return;
  markNotified(sid, items);
  process.stdout.write(JSON.stringify({ systemMessage: notice }) + "\n");
}

try { main(); } catch (_e) { /* fail open: the backstop never blocks a stop */ }
process.exit(0);
