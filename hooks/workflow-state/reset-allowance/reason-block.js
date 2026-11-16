"use strict";
// Wording of the RESET_FROM gate's answers (#2852). The ask block gives the user what the
// approval needs: this reset, how many came before, the allowance left and the recent history.

const { toDisplayLine: d } = require("../../lib/display-line");

const RECENT_ROWS = 5;

// allowReason(target, result) — the allow text names the allowance left after this reset.
function allowReason(target, result) {
  const left = result && result.replay && Number.isInteger(result.replay.allowance) ? result.replay.allowance - 1 : "?";
  return `RESET_FROM_${target}: within the reset allowance (allowance left after this reset: ${left}).`;
}

// askReason(target, reason, result) — the multi-line block shown with the permission prompt.
function askReason(target, reason, result) {
  const replay = (result && result.replay) || {};
  const rows = Array.isArray(replay.rows) ? replay.rows : [];
  const left = Number.isInteger(replay.allowance) ? replay.allowance : "unknown";
  const lines = [
    `RESET_FROM_${d(target)} needs your approval: ${d(String(reason || "").trim())}`,
    `why: ${d((result && result.why) || "unknown")}`,
    `reset count: ${rows.length} before this one`,
    `allowance left: ${left}`,
  ];
  const recent = rows.slice(-RECENT_ROWS);
  if (recent.length > 0) {
    lines.push(`recent resets (last ${recent.length}):`);
    for (const row of recent) lines.push(`- #${d(row.seq)} ${d(row.at)} -> ${d(row.from_step)} [${d(row.outcome)}] ${d(row.reason)}`);
  }
  return lines.join("\n");
}

module.exports = { allowReason, askReason };
