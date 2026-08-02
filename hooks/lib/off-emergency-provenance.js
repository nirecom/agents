// hooks/lib/off-emergency-provenance.js
// SSOT for the EMERGENCY-OFF provenance marker CONTRACT (#1780 M-2/M-4).
//
// Two entrypoints share it — hooks/record-off-skill-invocation.js writes the
// marker on UserPromptSubmit, hooks/workflow-mark/enforce-override-handlers/
// off-clearance.js consumes it when the emergency sentinel is handled — so per
// rules/coding/file-split.md the contract lives in the shared hooks/lib/ layer.
// Writer and reader MUST agree on the payload shape: a field the writer stops
// emitting silently turns every activation `unattributed`, and a field the
// reader stops checking silently widens what provenance appears to prove.
//
// WHAT THE MARKER PROVES, EXACTLY
//   The UserPromptSubmit event fires only on a real user prompt submission, so a
//   marker is evidence that A HUMAN TYPED the slash command that resolves to the
//   enforce-workflow-off skill, within EMERGENCY_PROVENANCE_MAX_AGE_MS of the
//   activation being stamped. It proves nothing about the reason text, nothing
//   about which override the human had in mind, and it is not a gate — absence
//   never blocks an activation (see off-clearance.js).
//
// M-4 (#1780 round 4) — TWO BINDINGS, because the marker used to carry neither:
//   (a) SKILL IDENTITY. The invocation regex accepts an arbitrary plugin
//       namespace (`/agents:enforce-workflow-off`), and that namespace text is
//       attacker-choosable prompt content. The marker therefore records the
//       RESOLVED skill name — a constant from this file — never the typed text,
//       and the reader requires exactly that constant. The typed namespace is
//       not recorded at all: it adds no evidence and prompts may carry private
//       content.
//   (b) TARGET. An emergency sentinel names a target (workflow | worktree), and
//       provenance for one target must not silently vouch for another. The
//       binding is honest rather than convenient: SKILL_TARGETS is the set of
//       overrides the enforce-workflow-off skill actually covers, and its own
//       description is the source of that claim — "Suspend workflow and worktree
//       enforcement for the current session (subsumes WORKTREE_OFF)". So the
//       skill authorizes BOTH targets, the marker says so explicitly, and the
//       reader checks membership. A marker that does not carry the requested
//       target in its authorized set is DOWNGRADED to unattributed rather than
//       being stretched to cover it.
//
// Anything unverifiable downgrades to `unattributed` — "not provably
// user-invoked", never an accusation.
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
