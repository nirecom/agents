"use strict";
// hooks/bash-guard/message.js — what the deny and the notify actually say.
//
// #2120 is the precedent: a guard that only says "denied" trades one compound command for
// a round of guessing. The text therefore carries the four things the model would
// otherwise re-derive — which literal tripped, what IS allowed, the sanctioned way to run
// the compound anyway, and the rule that owns the policy. Only the literal that tripped is
// named: listing the whole table would make every deny read the same.

const { literalById } = require("./forbidden-literals");
const { buildScriptEscapeHatch } = require("../lib/alt-target-remedy");
const { NOTIFY_CODES } = require("./reasons");

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

// Fixed text per notify id: the command itself is never quoted back into the transcript.
const NOTIFY_REMEDIES = Object.freeze({
  [NOTIFY_CODES.SENTINEL_NO_ECHO]:
    "A workflow sentinel issued as the command itself marks nothing; issue it through echo, " +
    'as a standalone echo "<<WORKFLOW_...>>" command.',
  [NOTIFY_CODES.SENTINEL_UNRECOGNIZED]:
    "This sentinel echo is not in a recognized form and marks nothing; issue it as a " +
    'standalone echo "<<WORKFLOW_...>>" with no flags, extra arguments or chained commands.',
  [NOTIFY_CODES.SCRIPT_NO_INTERPRETER]:
    "Run the script through its interpreter in argument position (bash <path> or " +
    "node <path>); an exec-position script is never auto-allowed and prompts every time.",
});

/**
 * @param {{notifyId: string}} hit the first detectIneffective() notice
 * @param {string} code the NOTIFY_CODES value reported alongside it
 * @returns {string} one line: the remedy, then the [bash-guard <code>] tag
 */
function buildNotifyMessage(hit, code) {
  const id = code || (hit && hit.notifyId) || "";
  const remedy = NOTIFY_REMEDIES[id] || "This command runs but has no effect.";
  return `${remedy} [bash-guard ${id}]`;
}

module.exports = { buildDenyMessage, buildNotifyMessage, RULE_OWNER };
