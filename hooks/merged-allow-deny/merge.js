"use strict";
// hooks/merged-allow-deny/merge.js — folds member judge results into one PreToolUse output:
// deny > ask > allow > approve > none. "none" never becomes approve. systemMessage and
// additionalContext of every member are joined with newlines unless the result is a deny.

const output = require("../lib/permission-decision-output");

const RANK = Object.freeze({ none: 0, approve: 1, allow: 2, ask: 3, deny: 4 });

const rankOf = (result) => (result && Object.prototype.hasOwnProperty.call(RANK, result.decision) ? RANK[result.decision] : 0);

function joinField(results, field) {
  const parts = results.map((result) => result && result[field]).filter((value) => typeof value === "string" && value !== "");
  return parts.length > 0 ? parts.join("\n") : undefined;
}

/**
 * @param {Array<{decision: string, reason?: string, systemMessage?: string,
 *                additionalContext?: string, omitOutput?: boolean}>} results
 * @returns {object|null} the output object, or null when nothing is to be printed
 */
function mergeResults(results) {
  const list = (results || []).filter(Boolean);
  const winner = list.reduce((best, result) => (rankOf(result) > rankOf(best) ? result : best), { decision: "none" });
  if (winner.decision === "deny") return output.deny(winner.reason);
  const extras = { systemMessage: joinField(list, "systemMessage"), additionalContext: joinField(list, "additionalContext") };
  switch (winner.decision) {
    case "ask": return output.ask(winner.reason, extras);
    case "allow": return output.allow(winner.reason, extras);
    case "approve": return output.approve(extras);
    default:
      if (list.length > 0 && list.every((result) => result.omitOutput === true)) return null;
      return output.none(extras);
  }
}

module.exports = { mergeResults, RANK };
