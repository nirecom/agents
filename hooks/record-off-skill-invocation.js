#!/usr/bin/env node
// Claude Code UserPromptSubmit hook: record PROVENANCE for the EMERGENCY OFF
// escape hatch (#1780 M-2).
//
// WHY THIS EXISTS: skills/enforce-workflow-off/SKILL.md tells the model to emit
// <<WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: ...>> and asserts that the user's
// invocation of the skill IS the human decision that justifies bypassing the
// Phase1 clearance examination. But nothing downstream could tell a
// user-invoked emission apart from one the model produced on its own
// initiative — the audit record read identically either way, so the audit trail
// could not answer the only question that matters about an escape hatch: who
// opened it. A prompt-level instruction ("never emit this on your own") cannot
// supply that evidence; it is exactly the thing under suspicion.
//
// MECHANISM: UserPromptSubmit fires ONLY on a real user prompt submission. The
// model cannot trigger this event, so a marker written here is evidence the
// human acted. On each user prompt this hook either
//   - writes <workflowDir>/<sid>.off-emergency-invoked when the prompt invokes
//     the enforce-workflow-off skill, or
//   - removes any existing marker otherwise.
// hooks/workflow-mark/enforce-override-handlers/off-clearance.js consumes and
// unlinks it when the emergency sentinel is handled, and stamps the resulting
// audit record + override marker with provenance=user_skill_invocation vs
// provenance=unattributed.
//
// The marker basename is in hooks/lib/protected-basenames.js's protected set,
// so hooks/block-off-clearance-write.js refuses Edit/Write/MultiEdit/editFiles/
// NotebookEdit calls naming it and refuses Bash write targets that spell it —
// literally, through backslash escapes or intra-word quoting, through a glob,
// and through a `$VAR` the same command line assigns. That is a BEST-EFFORT
// deterrent, not a proof: the hook's own TRUST MODEL comment lists what stays
// out of reach (dynamic path construction, base64, alternate interpreters, and
// edits to the hook itself). Read the guarantee as "the ordinary spellings of
// forging this marker are blocked and the attempt is visible", not "forgery is
// impossible".
//
// Nothing here depends on that being airtight: provenance is an audit signal,
// never a gate (see the fail-open note below). A forged marker cannot by itself
// grant clearance — it only mislabels an emergency activation as
// user_skill_invocation in the audit record.
//
// LIMITATION (accepted, documented in skills/enforce-workflow-off/SKILL.md):
// provenance is EVIDENCE OF, not proof of, user intent, and it under-attributes
// by design — a user who asks for the escape hatch in prose instead of typing
// the slash command is recorded as `unattributed`. `unattributed` therefore
// means "not provably user-invoked", not "model acted maliciously".
//
// SCOPE OF THE EVIDENCE (#1780 M-4): the marker attests that the user invoked
// THIS skill, and the skill covers both the workflow and the worktree override
// (its own description: "subsumes WORKTREE_OFF"). It does NOT attest to a
// reason, and it does not attest to any target outside that declared set — the
// payload names the skill and its target set explicitly so the consumer checks
// both rather than assuming. See lib/off-emergency-provenance.js.
//
// Fail-open: every error path exits 0 with an empty result. Provenance is an
// audit signal, never a gate.
"use strict";

const fs = require("fs");
const path = require("path");
const { getWorkflowDir } = require("./workflow-state");
const { EMERGENCY_PROVENANCE_MARKER_KIND } = require("./lib/protected-basenames");
const { buildProvenanceMarker } = require("./lib/off-emergency-provenance");

const SID_RE = /^[A-Za-z0-9_-]+$/;

// Matches the user typing the skill's slash command, with or without a plugin
// namespace prefix and with or without trailing arguments. The namespace is
// matched but NOT captured or recorded: it is arbitrary prompt text, and the
// marker records the resolved skill identity instead (#1780 M-4).
const OFF_SKILL_INVOCATION_RE = /^\s*\/(?:[A-Za-z0-9_-]+:)?enforce-workflow-off(?![\w-])/;

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
