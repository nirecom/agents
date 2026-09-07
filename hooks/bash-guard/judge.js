"use strict";
// hooks/bash-guard/judge.js — the verdict, in a fixed order.
//
// tool_name must be exactly "Bash" (runInTerminal / runCommands may drive pwsh, where a
// backtick is a line continuation and `{ }` a script block) -> the early-write-gate
// interlock silences the guard while that gate owns the screen -> parse() failing is
// FAIL-OPEN, the one named exception to deny-on-doubt in hooks/ -> detect() minus
// applyExemptions() decides. Everything is wrapped: a presentation guard that stops work
// on its own bug is worse than one that misses a case.

const { parse, analysisOf } = require("../lib/command-ir");
const { earlyWriteGateStatus } = require("../lib/early-write-gate");
const { detect } = require("./detect");
const { applyExemptions } = require("./exemptions");
const { ALLOW_CODES, reasonCodeFor } = require("./reasons");
const { buildDenyMessage } = require("./message");

const IN_SCOPE_TOOL = "Bash";

const allow = (code) => ({ verdict: "allow", code, literalId: null, sample: null, message: "" });

function readCommand(input) {
  const toolInput = (input && input.tool_input) || {};
  const command = toolInput.command;
  return typeof command === "string" ? command : null;
}

/**
 * @param {object} input a PreToolUse hook payload
 * @returns {{verdict: "allow"|"deny", code: string, literalId: string|null,
 *            sample: string|null, message: string}}
 */
function judgeBashCommand(input) {
  try {
    if (!input || input.tool_name !== IN_SCOPE_TOOL) return allow(ALLOW_CODES.TOOL_OUT_OF_SCOPE);

    const commandText = readCommand(input);
    if (!commandText || commandText.trim() === "") return allow(ALLOW_CODES.NO_HIT);

    // Interlock (C6): defer only while the early write gate is actually blocking. The
    // status reader reads WORKFLOW_OFF first, so a marker that deactivates the gate does
    // not silence this guard — the marker never bypassed a presentation rule.
    if (earlyWriteGateStatus(input.session_id).active) return allow(ALLOW_CODES.INTERLOCK_QUIET);

    const ir = parse(commandText);
    if (ir.parseFailure === true) return allow(ALLOW_CODES.PARSE_FAILURE);

    const ctx = { ir, analysis: analysisOf(ir), commandText };
    const surviving = applyExemptions(detect(ir), ctx);
    if (surviving.length === 0) return allow(ALLOW_CODES.NO_HIT);

    const hit = surviving[0];
    const code = reasonCodeFor(hit.literalId);
    return {
      verdict: "deny",
      code,
      literalId: hit.literalId,
      // The sample is the operator's own text, never the command line: a later segment can
      // carry a token, and a deny transcript must not be where it gets echoed back.
      sample: String(hit.sample == null ? "" : hit.sample),
      message: buildDenyMessage(hit, code),
    };
  } catch (_e) {
    return allow(ALLOW_CODES.PARSE_FAILURE);
  }
}

module.exports = { judgeBashCommand };
