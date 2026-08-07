// hooks/lib/off-emergency-provenance.js
// SSOT for the EMERGENCY-OFF provenance marker contract, shared by the writer
// (record-off-skill-invocation.js, on UserPromptSubmit — an event the model
// can't trigger) and the reader (off-clearance.js). A marker proves only that
// a human typed the enforce-workflow-off command recently; it is evidence, not
// a gate — absence downgrades to `unattributed`, never blocks. It binds skill
// identity (a constant, never raw prompt text) and target, so neither field
// can be spoofed via prompt content or stretched to cover an unrelated target.
"use strict";

// The skill whose invocation this marker attests to. A constant, not prompt text.
const OFF_EMERGENCY_SKILL = "enforce-workflow-off";

// The override targets that skill covers (see its SKILL.md description).
const OFF_EMERGENCY_SKILL_TARGETS = ["workflow", "worktree"];

const OFF_EMERGENCY_PROVENANCE_SOURCE = "user_skill_invocation";
const OFF_EMERGENCY_PROVENANCE_UNATTRIBUTED = "unattributed";

// Belt-and-braces bound: record-off-skill-invocation.js already clears an
// unconsumed marker on the next user prompt, so a survivor older than this is
// stale by definition and must not vouch for a later emission.
const EMERGENCY_PROVENANCE_MAX_AGE_MS = 10 * 60 * 1000;
// Clock skew between the writing and reading processes is real but small; a
// marker dated further into the future than this is not evidence of anything.
const EMERGENCY_PROVENANCE_FUTURE_TOLERANCE_MS = 60 * 1000;

// buildProvenanceMarker(): the payload record-off-skill-invocation.js writes.
// The prompt text itself is deliberately NOT recorded — the fact of the
// invocation is the whole signal, and prompts may carry private content.
function buildProvenanceMarker(nowMs) {
  const now = typeof nowMs === "number" ? nowMs : Date.now();
  return {
    invoked_at: new Date(now).toISOString(),
    source: OFF_EMERGENCY_PROVENANCE_SOURCE,
    skill: OFF_EMERGENCY_SKILL,
    targets: OFF_EMERGENCY_SKILL_TARGETS.slice(),
  };
}

// verifyProvenanceMarker(raw, target, nowMs) -> { attributed, reason }
// `raw` is the marker file's contents as read; `target` is the override being
// activated. `reason` is null when attributed, and otherwise names the ONE check
// that failed, so the audit trail records why attribution was withheld.
// Never throws: every unparseable / unexpected shape downgrades.
function verifyProvenanceMarker(raw, target, nowMs) {
  let marker = null;
  try {
    marker = JSON.parse(raw);
  } catch (_e) {
    return { attributed: false, reason: "marker unparseable" };
  }
  if (!marker || typeof marker !== "object" || Array.isArray(marker)) {
    return { attributed: false, reason: "marker is not an object" };
  }
  if (marker.source !== OFF_EMERGENCY_PROVENANCE_SOURCE) {
    return { attributed: false, reason: "marker source is not " + OFF_EMERGENCY_PROVENANCE_SOURCE };
  }
  if (marker.skill !== OFF_EMERGENCY_SKILL) {
    return { attributed: false, reason: "marker does not name skill=" + OFF_EMERGENCY_SKILL };
  }
  if (!Array.isArray(marker.targets) || marker.targets.indexOf(target) === -1) {
    return { attributed: false, reason: "marker does not authorize target=" + target };
  }
  const invokedAt = new Date(marker.invoked_at).getTime();
  if (!isFinite(invokedAt)) {
    return { attributed: false, reason: "marker has no usable invoked_at" };
  }
  const now = typeof nowMs === "number" ? nowMs : Date.now();
  if (now - invokedAt > EMERGENCY_PROVENANCE_MAX_AGE_MS) {
    return { attributed: false, reason: "marker is stale" };
  }
  if (invokedAt - now > EMERGENCY_PROVENANCE_FUTURE_TOLERANCE_MS) {
    return { attributed: false, reason: "marker is future-dated" };
  }
  return { attributed: true, reason: null };
}

module.exports = {
  OFF_EMERGENCY_SKILL,
  OFF_EMERGENCY_SKILL_TARGETS,
  OFF_EMERGENCY_PROVENANCE_SOURCE,
  OFF_EMERGENCY_PROVENANCE_UNATTRIBUTED,
  EMERGENCY_PROVENANCE_MAX_AGE_MS,
  EMERGENCY_PROVENANCE_FUTURE_TOLERANCE_MS,
  buildProvenanceMarker,
  verifyProvenanceMarker,
};
