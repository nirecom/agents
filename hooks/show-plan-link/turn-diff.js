"use strict";
// hooks/show-plan-link/turn-diff.js — the one "[plan-sync] turn diff" line for a hook run (#2768).
// Shown only when the remote refuses force push, so a turn spans several commits on main.

const TURN_DIFF_DUTY = "Show the turn diff line above once in this summary, placed before the [plan-link] line(s) so they " +
  "still end the text block as required; do not repeat it in later turns.";

function validLinks(l) {
  if (!l || typeof l !== "object" || !Array.isArray(l.urls) || l.urls.length === 0) return false;
  if (!l.urls.every((u) => typeof u === "string" && u && !/[\r\n\s]/.test(u))) return false;
  return l.kind === "compare" || l.kind === "commits";
}

// turnDiffLine(results) -> the line for the latest result carrying turnLinks, or "".
function turnDiffLine(results) {
  if (!Array.isArray(results)) return "";
  let links = null;
  for (const run of results) {
    const l = run && run.result && run.result.turnLinks;
    if (validLinks(l)) links = l;
  }
  if (!links) return "";
  if (links.kind === "compare") return `[plan-sync] turn diff: ${links.urls[0]}`;
  const more = Number.isInteger(links.more) && links.more > 0 ? ` (+${links.more} more)` : "";
  return `[plan-sync] turn diff (other commits interleave, one link per commit of this turn): ${links.urls.join(" ")}${more}`;
}

// renderTurnDiff(results) -> "<line>\n<TURN_DIFF_DUTY>", or "" when no result carries turnLinks.
function renderTurnDiff(results) {
  const line = turnDiffLine(results);
  return line ? `${line}\n${TURN_DIFF_DUTY}` : "";
}

module.exports = { TURN_DIFF_DUTY, turnDiffLine, renderTurnDiff };
