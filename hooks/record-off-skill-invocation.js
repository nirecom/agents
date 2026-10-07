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
const { getSessionStateDir } = require("./workflow-state");
const { EMERGENCY_PROVENANCE_MARKER_KIND } = require("./lib/protected-basenames");
const { buildProvenanceMarker, promptInvokesOffSkill } = require("./lib/off-emergency-provenance");

const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

const SID_RE = /^[A-Za-z0-9_-]+$/;

function markerPathFor(sessionId) {
  return path.join(getSessionStateDir(sessionId), `${sessionId}.${EMERGENCY_PROVENANCE_MARKER_KIND}`);
}

// The marker payload is the SHARED contract in lib/off-emergency-provenance.js:
// the resolved skill identity (never the typed namespace text) and the target
// set that skill covers, so the consumer can bind attribution to both (#1780
// M-4). Building it here from the typed prompt would let prompt content decide
// what the marker claims.
function writeProvenanceMarker(sessionId) {
  const dir = getSessionStateDir(sessionId);
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
  const r = readHookInput();
  if (r.kind !== "ok") {
    try { fs.writeSync(2, readFailOpenDiagnostic("record-off-skill-invocation", r, "session id from env fallback") + "\n"); } catch (_) {}
  }
  const input = r.kind === "ok" ? r.input : null;

  let sessionId = input && typeof input.session_id === "string" ? input.session_id : null;
  if (!sessionId) {
    try { sessionId = require("./workflow-state").resolveSessionId() || null; } catch (_e) { sessionId = null; }
  }

  if (sessionId && SID_RE.test(sessionId)) {
    const prompt = input && typeof input.prompt === "string" ? input.prompt : "";
    try {
      if (promptInvokesOffSkill(prompt)) writeProvenanceMarker(sessionId);
      else clearProvenanceMarker(sessionId);
    } catch (_e) { /* fail-open */ }
  }

  console.log(JSON.stringify({}));
}

module.exports = { promptInvokesOffSkill, markerPathFor, writeProvenanceMarker, clearProvenanceMarker };
