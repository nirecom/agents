"use strict";
// Sentinel receipts (#2877): workflow-mark.js appends a receipt when a sentinel reaches it and an
// outcome when it finishes, keyed by the Bash tool_use_id. The Stop backstop
// (hooks/stop-sentinel-unapplied-notice.js) reads them to tell a sentinel that never reached the
// hook from one that stopped mid-way. Diagnostics only: every function fails open.

const fs = require("fs");

const RECEIPT_FILE = "sentinel-receipts.jsonl";

function append(sid, record) {
  if (!sid || typeof record.tool_use_id !== "string" || record.tool_use_id === "") return false;
  try {
    const { controlPath } = require("../workflow-state/state-io/control-dir");
    const file = controlPath(sid, RECEIPT_FILE, { forWrite: true });
    fs.appendFileSync(file, JSON.stringify({ ts: new Date().toISOString(), ...record }) + "\n", { mode: 0o600 });
    return true;
  } catch (_e) {
    return false;
  }
}

function recordReceipt(sid, toolUseId, parts) {
  return append(sid, { kind: "receipt", tool_use_id: toolUseId, parts: Array.isArray(parts) ? parts : [] });
}

function recordOutcome(sid, toolUseId, { applied = [], unapplied = [] } = {}) {
  return append(sid, { kind: "outcome", tool_use_id: toolUseId, applied, unapplied });
}

// readReceipts(sid) -> {receipts:Set, outcomes:Set} of tool_use_ids; empty sets when unreadable.
function readReceipts(sid) {
  const receipts = new Set();
  const outcomes = new Set();
  try {
    const { controlPath } = require("../workflow-state/state-io/control-dir");
    const text = fs.readFileSync(controlPath(sid, RECEIPT_FILE), "utf8");
    for (const line of text.split("\n")) {
      let r = null;
      try { r = JSON.parse(line); } catch (_e) { continue; }
      if (!r || typeof r.tool_use_id !== "string") continue;
      if (r.kind === "receipt") receipts.add(r.tool_use_id);
      else if (r.kind === "outcome") outcomes.add(r.tool_use_id);
    }
  } catch (_e) { /* no receipts yet */ }
  return { receipts, outcomes };
}

module.exports = { RECEIPT_FILE, recordReceipt, recordOutcome, readReceipts };
