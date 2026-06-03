"use strict";
// Validates the human-readable `: <reason>` portion of *_NOT_NEEDED sentinels.
// Rejects placeholder values ("none", "skip", etc.) and overly short strings.

const SKIP_REASON_DUDS = new Set([
  "none", "n/a", "na", "nope", "no", "nothing",
  "skip", "skipped", "not needed", "not required", "nil",
  "スキップ", "スキップする", "省略する", "特になし", "無し",
]);

function validateSkipReason(raw) {
  const trimmed = (raw || "").trim();
  const nonSpace = trimmed.replace(/\s+/g, "");
  if (nonSpace.length < 3) {
    return { ok: false, msg: "reason too short — provide at least 3 non-space characters explaining why this step is unnecessary in this task's context." };
  }
  if (SKIP_REASON_DUDS.has(trimmed.toLowerCase())) {
    return { ok: false, msg: `reason "${trimmed}" is a placeholder — explain why this step is unnecessary in this task's context.` };
  }
  if (/^(.)\1+$/u.test(nonSpace)) {
    return { ok: false, msg: "reason is a single repeated character — provide a real explanation." };
  }
  return { ok: true, reason: trimmed };
}

module.exports = { SKIP_REASON_DUDS, validateSkipReason };
