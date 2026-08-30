#!/usr/bin/env node
// UserPromptSubmit hook: PROVENANCE for the EMERGENCY OFF escape hatch (#1780
// M-2). The model cannot fire UserPromptSubmit, so a marker written here is
// evidence a human asked for the bypass. Writes <workflowDir>/<sid>
// .off-emergency-invoked when the prompt invokes enforce-workflow-off, clears
// it otherwise; off-clearance.js consumes it and stamps the audit record
// provenance=user_skill_invocation vs unattributed.
// Audit signal, never a gate: every error path exits 0, and `unattributed`
// means "not provably user-invoked" (prose requests under-attribute by design),
// not "the model acted maliciously". Contract: lib/off-emergency-provenance.js;
// forgery deterrent and its limits: block-clearance-token-write.js.
"use strict";

const fs = require("fs");
const path = require("path");
const { getWorkflowDir } = require("./workflow-state");
const { EMERGENCY_PROVENANCE_MARKER_KIND } = require("./lib/protected-basenames");
const { buildProvenanceMarker } = require("./lib/off-emergency-provenance");

const SID_RE = /^[A-Za-z0-9_-]+$/;

// Matches the user typing the skill's slash command, with or without a plugin
// namespace prefix and with or without trailing arguments. A real invocation
// arrives expanded, with the command on its own `<command-name>` line, so the
// match is per-line and tolerates that one wrapper tag; the skill-body form the
// model can also produce carries no such line and stays unattributed. The
// namespace is matched but NOT captured: it is arbitrary prompt text, and the
// marker records the resolved skill identity instead (#1780 M-4).
const OFF_SKILL_INVOCATION_RE = /^[ \t]*(?:<command-name>)?\/(?:[A-Za-z0-9_-]+:)?enforce-workflow-off(?![\w-])/m;

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_e) {}
  return Buffer.concat(chunks).toString("utf8");
}

function markerPathFor(sessionId) {
  return path.join(getWorkflowDir(), `${sessionId}.${EMERGENCY_PROVENANCE_MARKER_KIND}`);
}

// The marker payload is the SHARED contract in lib/off-emergency-provenance.js:
// the resolved skill identity (never the typed namespace text) and the target
// set that skill covers, so the consumer can bind attribution to both (#1780
// M-4). Building it here from the typed prompt would let prompt content decide
// what the marker claims.
function writeProvenanceMarker(sessionId) {
  const dir = getWorkflowDir();
  fs.mkdirSync(dir, { recursive: true });
  const target = markerPathFor(sessionId);
  const tmp = target + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(buildProvenanceMarker()), { mode: 0o600 });
  fs.renameSync(tmp, target);
}

function clearProvenanceMarker(sessionId) {
  // Any later user prompt invalidates an unconsumed marker: the sentinel is
  // emitted in the same turn as the invocation, so a survivor is stale.
  try { fs.unlinkSync(markerPathFor(sessionId)); } catch (_e) {}
}

if (require.main === module) {
  let input = null;
  try { input = JSON.parse(readStdin()); } catch (_e) { input = null; }

  let sessionId = input && typeof input.session_id === "string" ? input.session_id : null;
  if (!sessionId) {
    try { sessionId = require("./workflow-state").resolveSessionId() || null; } catch (_e) { sessionId = null; }
  }

  if (sessionId && SID_RE.test(sessionId)) {
    const prompt = input && typeof input.prompt === "string" ? input.prompt : "";
    try {
      if (OFF_SKILL_INVOCATION_RE.test(prompt)) writeProvenanceMarker(sessionId);
      else clearProvenanceMarker(sessionId);
    } catch (_e) { /* fail-open */ }
  }

  console.log(JSON.stringify({}));
}

module.exports = { OFF_SKILL_INVOCATION_RE, markerPathFor, writeProvenanceMarker, clearProvenanceMarker };
