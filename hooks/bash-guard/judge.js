"use strict";
// hooks/bash-guard/judge.js — the 4-value verdict, deny > notify > allow > passThrough.
//
// tool_name must be exactly "Bash" (runInTerminal / runCommands may drive pwsh, where a
// backtick is a line continuation and `{ }` a script block) -> the early-write-gate
// interlock silences the guard while that gate owns the screen -> parse() failing is
// FAIL-OPEN, the one named exception to deny-on-doubt in hooks/ -> detect() decides deny
// -> detectIneffective() decides notify -> matchSelfScript() decides allow. Every failure
// lands on passThrough, never allow: allow skips the permission prompt.

const path = require("path");
const { parse, analysisOf } = require("../lib/command-ir");
const { earlyWriteGateStatus } = require("../lib/early-write-gate");
const { normalizeCwd } = require("../lib/path-normalize");
const { detect, detectIneffective } = require("./detect");
const { matchSelfScript } = require("./allow");
const { PASS_THROUGH_CODES, reasonCodeFor } = require("./reasons");
const { buildDenyMessage, buildNotifyMessage } = require("./message");

const IN_SCOPE_TOOL = "Bash";

const verdictOf = (verdict, code, fields) => ({
  verdict,
  code,
  literalId: null,
  notifyId: null,
  sample: null,
  message: "",
  ...fields,
});
const passThrough = (code) => verdictOf("passThrough", code);

function readCommand(input) {
  const toolInput = (input && input.tool_input) || {};
  const command = toolInput.command;
  return typeof command === "string" ? command : null;
}

// tool_input.cwd first, then input.cwd; the first non-blank string decides. No
// process.cwd() fallback: the hook's own cwd says nothing about where the command runs.
function readCwd(input) {
  const toolInput = (input && input.tool_input) || {};
  for (const candidate of [toolInput.cwd, input && input.cwd]) {
    if (typeof candidate !== "string" || candidate.trim() === "") continue;
    const normalized = normalizeCwd(candidate);
    return typeof normalized === "string" && path.isAbsolute(normalized) ? normalized : null;
  }
  return null;
}

/**
 * @param {object} input a PreToolUse hook payload
 * @returns {{verdict: "allow"|"deny"|"notify"|"passThrough", code: string,
 *            literalId: string|null, notifyId: string|null, sample: string|null,
 *            message: string}}
 */
function judgeBashCommand(input) {
  try {
    if (!input || input.tool_name !== IN_SCOPE_TOOL) return passThrough(PASS_THROUGH_CODES.TOOL_OUT_OF_SCOPE);

    const commandText = readCommand(input);
    if (!commandText || commandText.trim() === "") return passThrough(PASS_THROUGH_CODES.NO_HIT);

    // Interlock (C6): defer only while the early write gate is actually blocking. The
    // status reader reads WORKFLOW_OFF first, so a marker that deactivates the gate does
    // not silence this guard — the marker never bypassed a presentation rule.
    if (earlyWriteGateStatus(input.session_id).active) return passThrough(PASS_THROUGH_CODES.INTERLOCK_QUIET);

    const ir = parse(commandText);
    if (ir.parseFailure === true) return passThrough(PASS_THROUGH_CODES.PARSE_FAILURE);

    const hits = detect(ir);
    if (hits.length > 0) {
      const hit = hits[0];
      const code = reasonCodeFor(hit.literalId);
      return verdictOf("deny", code, {
        literalId: hit.literalId,
        // The sample is the operator's own text, never the command line: a later segment can
        // carry a token, and a deny transcript must not be where it gets echoed back.
        sample: String(hit.sample == null ? "" : hit.sample),
        message: buildDenyMessage(hit, code),
      });
    }

    const ctx = { ir, analysis: analysisOf(ir), commandText, cwd: readCwd(input) };
    const notices = detectIneffective(ir, ctx);
    if (notices.length > 0) {
      const notifyId = notices[0].notifyId;
      return verdictOf("notify", notifyId, { notifyId, message: buildNotifyMessage(notices[0], notifyId) });
    }

    const allowCode = matchSelfScript(ir, ctx);
    if (allowCode) return verdictOf("allow", allowCode);

    return passThrough(PASS_THROUGH_CODES.NO_HIT);
  } catch (_e) {
    return passThrough(PASS_THROUGH_CODES.PARSE_FAILURE);
  }
}

module.exports = { judgeBashCommand };
