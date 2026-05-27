#!/usr/bin/env node
// Stop hook: structurally enforce the confirm-plan Step 2 protocol.
//
// When show-plan-link.js emits a breadcrumb during a turn (regardless of
// CONFIRM_<STEP>), it drops a per-turn marker. On Stop, this hook
// reads+deletes those markers, then scans the last assistant message for any
// forbidden representation of the WORKFLOW_PLANS_DIR path (native,
// forward-slash, tilde, or file:/// URI). If found, the turn is blocked
// (decision:block + exit 2) so the orchestrator must re-issue the response
// without the path.
//
// Fail-open everywhere: missing markers, missing transcript, parse errors —
// all silently pass through. The guard activates only when (a) a marker
// exists AND (b) the assistant message clearly contains the path.
"use strict";

const fs = require("fs");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_) {}
  return Buffer.concat(chunks).toString("utf8");
}

if (require.main === module) {
  let input = {};
  try {
    const raw = readStdin();
    if (!raw) process.exit(0);
    input = JSON.parse(raw);
  } catch (_) {
    process.exit(0);
  }

  if (input.stop_hook_active === true) process.exit(0);

  const { resolveSessionId } = require("./lib/workflow-state");
  const sid = resolveSessionId({
    sessionIdFromInput: input.session_id,
    transcriptPath: input.transcript_path,
  });
  if (!sid) process.exit(0);

  const { readAndDeleteTurnMarkers } = require("./lib/turn-marker");
  const markers = readAndDeleteTurnMarkers(sid);
  if (markers.length === 0) process.exit(0);
  // #563: path-emission scan is CONFIRM_<STEP>-independent. Marker presence
  // alone (written by show-plan-link.js whenever a final plan artifact is
  // produced) is sufficient to activate the scan.

  // Read transcript and scan backward for the most recent assistant message.
  let lastAssistantText = "";
  try {
    const raw = fs.readFileSync(input.transcript_path, "utf8");
    const lines = raw.split("\n");
    const tail = lines.slice(Math.max(0, lines.length - 50));
    for (let i = tail.length - 1; i >= 0; i--) {
      const line = tail[i];
      if (!line) continue;
      let entry;
      try {
        entry = JSON.parse(line);
      } catch (_) {
        continue;
      }
      if (!entry || entry.type !== "assistant") continue;
      const content = entry.message && entry.message.content;
      if (!Array.isArray(content)) process.exit(0);
      const texts = [];
      for (const item of content) {
        if (item && item.type === "text" && typeof item.text === "string") {
          texts.push(item.text);
        }
      }
      lastAssistantText = texts.join("\n");
      break;
    }
    if (!lastAssistantText) process.exit(0);
  } catch (_) {
    process.exit(0);
  }

  const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
  const { workspaceFolderUriFrom } = require("./show-plan-link");
  let plansDir;
  try {
    plansDir = getWorkflowPlansDir();
  } catch (_) {
    process.exit(0);
  }

  const patternsRaw = [
    plansDir,
    plansDir.replace(/\\/g, "/"),
    "~/.workflow-plans",
    workspaceFolderUriFrom(plansDir),
  ];
  const seen = new Set();
  const patterns = [];
  for (const p of patternsRaw) {
    if (typeof p !== "string" || p.length === 0) continue;
    if (seen.has(p)) continue;
    seen.add(p);
    patterns.push(p);
  }

  for (const pat of patterns) {
    if (lastAssistantText.includes(pat)) {
      process.stdout.write(JSON.stringify({
        decision: "block",
        reason: "[confirm-plan] Step 2 violation: orchestrator emitted a `~/.workflow-plans/` path representation. `show-plan-link.js` is the sole authoritative path surface. Re-issue the response without the path. (Hook: stop-confirm-plan-guard.js)",
      }));
      process.exit(2);
    }
  }

  process.exit(0);
}
