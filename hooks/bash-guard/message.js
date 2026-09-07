"use strict";
// hooks/bash-guard/message.js — what the deny actually says.
//
// #2120 is the precedent: a guard that only says "denied" trades one compound command for
// a round of guessing. The text therefore carries the four things the model would
// otherwise re-derive — which literal tripped, what IS allowed, the sanctioned way to run
// the compound anyway, and the rule that owns the policy. Only the literal that tripped is
// named: listing the whole table would make every deny read the same.

const { literalById } = require("./forbidden-literals");
const { buildScriptEscapeHatch } = require("../lib/alt-target-remedy");

const RULE_OWNER = 'rules/shell-commands.md "Command-Line Issuance Discipline"';

function escapeHatch() {
  try {
    return buildScriptEscapeHatch();
  } catch (_e) {
    return (
      "Write the steps to a scratchpad script with the Write tool, then issue it as one " +
      "call: bash <absolute-path-to-that-script>."
    );
  }
}

/**
 * @param {{literalId: string, sample: string}} hit the first surviving hit
 * @param {string} code the reasons.js code reported alongside it
 */
function buildDenyMessage(hit, code) {
  const literalId = (hit && hit.literalId) || "unknown";
  const entry = literalById(literalId);
  const literal = entry ? entry.literal : literalId;
  return [
    `Bash command not issued: the command line carries the prohibited literal \`${literal}\`` +
      ` (${literalId}, ${code}).`,
    "",
    "ALLOWED: one standalone command with its own flags and arguments — however many of " +
      "them there are. What is prohibited is the compound, not the argument count.",
    escapeHatch(),
    "",
    `Policy owner: ${RULE_OWNER}.`,
  ].join("\n");
}

module.exports = { buildDenyMessage, RULE_OWNER };
