"use strict";
// hooks/lib/bash-write-targets/encoded.js
// PowerShell encoded-command / stop-parsing (--%) write detection (#1402 canary-7).
//
// -EncodedCommand / -enc: base64-encoded PS command body — opaque to IR.
// --%: PowerShell stop-parsing operator — remainder passed verbatim to a native
//      command, opaque to static analysis.
// Both are FAIL-CLOSED: when a pwsh/powershell invocation carries them, treat as
// write (no local target is extractable). This predicate is SCOPED to PowerShell
// interpreters — it does NOT fire for arbitrary commands that happen to have an
// `-enc` flag (e.g. `ffmpeg -enc ...`) or a literal `--%` in prose.

const { resolveEffectiveCommand, resolveEffectiveArgv, commandBasename } = require("../bash-write-patterns/segment-utils");

const PWSH_INTERP = new Set(["pwsh", "powershell"]);

function isPwshInterp(effCmd) {
  if (typeof effCmd !== "string" || effCmd === "") return false;
  const base = commandBasename(effCmd);
  if (base == null) return false;
  return PWSH_INTERP.has(base.replace(/\.exe$/i, "").toLowerCase());
}

/**
 * isEncodedCommandWriteIR: true only when a PowerShell interpreter segment
 * carries -EncodedCommand/-enc, OR a PowerShell segment uses the --% stop-parsing
 * operator. Fail-closed for those forms only; false for everything else.
 * @param {object} ir
 * @returns {boolean}
 */
function isEncodedCommandWriteIR(ir) {
  if (!ir || ir.parseFailure === true) return false;
  if (!Array.isArray(ir.segments)) return false;
  for (const seg of ir.segments) {
    const effCmd = resolveEffectiveCommand(seg);
    if (!isPwshInterp(effCmd)) continue;
    const argv = resolveEffectiveArgv(seg) || [];
    for (const tok of argv) {
      if (typeof tok !== "string") continue;
      const tl = tok.toLowerCase();
      if (tl === "-encodedcommand" || tl === "-enc") return true;
      if (tok === "--%") return true; // PS stop-parsing under a pwsh interp
    }
  }
  return false;
}

module.exports = { isEncodedCommandWriteIR, isPwshInterp };
