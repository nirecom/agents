"use strict";
// hooks/lib/shell-snapshot-notice.js — the additionalContext wording for a snapshot scan (#2221).
// The exit-127 sentence is used only when the hook saw "Exit code 127"; otherwise the neutral
// sentence, because a PostToolUse or a non-127 failure proves nothing about the last command.
// Lines that report a snapshot left alone never promise deletion: the sweep only lists or
// removes old files, it never fixes the current session.

const SWEEP_HOLDBACK_NOTE_MINUTES = 1440;

const CONFIRMED_SENTENCE = "The previous Bash command exited with code 127 (command not found). " +
  "PATH has been repaired and takes effect for subsequent Bash calls. " +
  "Before re-running the previous command, check whether it changed any state before exiting 127; " +
  "re-run it only if needed. This hook did not re-run it.";
const NEUTRAL_SENTENCE = "PATH has been repaired. The repair takes effect for subsequent Bash calls.";
const ADVICE = "Restart Claude Code so it takes a fresh snapshot; run /sweep-shell-snapshots --dry-run " +
  `to list stale snapshots (it only considers ones older than ${SWEEP_HOLDBACK_NOTE_MINUTES} minutes).`;

const n = (k) => `${k} snapshot(s)`;
const arr = (x) => (Array.isArray(x) ? x : []);
const num = (x) => (Array.isArray(x) ? x.length : (typeof x === "number" ? x : 0));

function groupBy(items, keyOf) {
  const m = new Map();
  for (const it of items) {
    const k = keyOf(it);
    if (!m.has(k)) m.set(k, []);
    m.get(k).push(it);
  }
  return m;
}

function formatRepairNotice(results, { trigger, failedCommandExit127 = false, affectsCurrentSession = false } = {}) {
  const r = results || {};
  const lines = [];
  const repaired = arr(r.repaired);
  if (repaired.length > 0) {
    lines.push(`${n(repaired.length)}: PATH line rewritten to POSIX form, /usr/bin before System32.`);
    lines.push(failedCommandExit127 ? CONFIRMED_SENTENCE : NEUTRAL_SENTENCE);
  }
  for (const [key, items] of groupBy(arr(r.failed), (f) => `${f.verdictBefore || "windows-form"}, ${f.reason}`)) {
    lines.push(`${n(items.length)} not rewritten (${key}): ${items.map((f) => f.name).join(", ")}. ${ADVICE}`);
  }
  const unrep = arr(r.unrepairable);
  if (unrep.length > 0) {
    lines.push(`${n(unrep.length)} not rewritten (windows-unrepairable: the PATH value cannot be converted safely): ${unrep.join(", ")}. ${ADVICE}`);
  }
  for (const [reason, items] of groupBy(arr(r.deferred), (d) => d.reason)) {
    lines.push(`${n(items.length)} not repaired yet (${reason}): ${items.map((d) => d.name).join(", ")}; the next check retries them.`);
  }
  const unscanned = num(r.unscanned);
  if (unscanned > 0) lines.push(`${n(unscanned)} unscanned (time budget ran out); the next check scans them.`);
  const missingCore = num(r.missingCore);
  if (missingCore > 0) {
    lines.push(`${n(missingCore)} have a PATH without /usr/bin or /bin (missing-core); run /sweep-shell-snapshots --dry-run to review them.`);
  }
  if (lines.length > 0 && affectsCurrentSession) {
    lines.push("The newest snapshot was affected, so it is likely this session's own snapshot.");
  }
  if (trigger === "session-start") return lines.map((l) => `WARNING (shell snapshot): ${l}`);
  return lines;
}

module.exports = { formatRepairNotice, SWEEP_HOLDBACK_NOTE_MINUTES, CONFIRMED_SENTENCE, NEUTRAL_SENTENCE };
