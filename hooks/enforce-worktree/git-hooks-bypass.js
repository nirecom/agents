"use strict";

const { stripQuotedArgs } = require("../lib/strip-quoted-args");

function isPositionInsideQuotes(cmd, pos) {
  let inSingle = false, inDouble = false;
  for (let i = 0; i < pos; i++) {
    const c = cmd[i];
    if (c === "\\" && i + 1 < cmd.length) { i++; continue; }
    if (c === "'" && !inDouble) inSingle = !inSingle;
    else if (c === '"' && !inSingle) inDouble = !inDouble;
  }
  return inSingle || inDouble;
}

function findEndOfEnvVarValue(cmd, startPos) {
  let inSingle = false, inDouble = false;
  for (let i = startPos; i < cmd.length; i++) {
    const c = cmd[i];
    if (c === "\\" && i + 1 < cmd.length) { i++; continue; }
    if (c === "'" && !inDouble) { inSingle = !inSingle; continue; }
    if (c === '"' && !inSingle) { inDouble = !inDouble; continue; }
    if (!inSingle && !inDouble && /\s/.test(c)) return i;
  }
  return cmd.length;
}

function envVarPrefixesGit(cmd, startPos) {
  const findNextTopLevel = (re) => {
    const r = new RegExp(re.source, re.flags.includes("g") ? re.flags : re.flags + "g");
    r.lastIndex = startPos;
    let m;
    while ((m = r.exec(cmd)) !== null) {
      if (!isPositionInsideQuotes(cmd, m.index)) return m;
    }
    return null;
  };
  const gitMatch = findNextTopLevel(/\bgit\b/);
  const sepMatch = findNextTopLevel(/[;|&]/);
  if (!gitMatch) return false;
  if (!sepMatch) return true;
  return gitMatch.index < sepMatch.index;
}

/**
 * True if cmd attempts to bypass git hooks via:
 *   - git -c core.hooksPath=<value>              (Pass A2, unquoted)
 *   - git -c "core.hooksPath=<value>"            (Pass B, double-quoted value)
 *   - git -c 'core.hooksPath=<value>'            (Pass B, single-quoted value)
 *   - git --config-env=core.hooksPath=VAR        (Pass A1, env-var indirection)
 *   - git --config-env core.hooksPath=VAR        (Pass A1, separated)
 *   - GIT_CONFIG_PARAMETERS=<value-containing-core.hooksPath> git ...
 *                                                 (Pass C1, env-var prefix)
 *   - GIT_CONFIG_KEY_<n>=core.hooksPath ... git ... (Pass C2, batch env-var)
 *
 * Out of scope: bash/sh/pwsh wrapper bypass, shell variable/alias/command-substitution
 * bypass, persistent git config writes. See plan for rationale.
 */
function hasGitHooksBypass(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  if (!/\bgit\b/.test(cmd)) return false;
  if (
    !/core\.hooksPath/i.test(cmd) &&
    !/--config-env\b/i.test(cmd) &&
    !/\bGIT_CONFIG_(?:PARAMETERS|COUNT|KEY_\d+|VALUE_\d+)\s*=/i.test(cmd)
  ) {
    return false;
  }

  const G =
    "(?:\\s+(?:--[A-Za-z][\\w-]*(?:=\\S+)?|-[A-Za-z]\\S*)(?:\\s+[^-\\s]\\S*)?)*";

  const stripped = stripQuotedArgs(cmd);

  // Pass A1: --config-env=core.hooksPath= or --config-env core.hooksPath=
  if (new RegExp("\\bgit\\b" + G + "\\s+--config-env(?:=|\\s+)core\\.hooksPath\\s*=", "i").test(stripped))
    return true;

  // Pass A2: -c core.hooksPath= (unquoted)
  if (new RegExp("\\bgit\\b" + G + "\\s+-c\\s+core\\.hooksPath\\s*=", "i").test(stripped))
    return true;

  // Pass B: -c "core.hooksPath=…" / -c 'core.hooksPath=…' (raw cmd, loop all matches)
  const reB = new RegExp("\\bgit\\b" + G + "\\s+-c\\s+[\"']core\\.hooksPath\\s*=", "ig");
  for (let mB; (mB = reB.exec(cmd)) !== null; ) {
    if (!isPositionInsideQuotes(cmd, mB.index)) return true;
  }

  // Pass C1: GIT_CONFIG_PARAMETERS=<value> where value contains core.hooksPath,
  // value is parsed via findEndOfEnvVarValue (NOT cmd-wide), and the env-var
  // actually prefixes a git invocation. Loop over all matches.
  const reC1 = /(?:^|[\s;|&])GIT_CONFIG_PARAMETERS\s*=/ig;
  for (let mC1; (mC1 = reC1.exec(cmd)) !== null; ) {
    if (isPositionInsideQuotes(cmd, mC1.index)) continue;
    const valStart = mC1.index + mC1[0].length;
    const valEnd = findEndOfEnvVarValue(cmd, valStart);
    const value = cmd.slice(valStart, valEnd);
    if (/core\.hooksPath/i.test(value) && envVarPrefixesGit(cmd, valEnd)) {
      return true;
    }
  }

  // Pass C2: GIT_CONFIG_KEY_<n>=core.hooksPath ... git ... (batch env-var config),
  // gated by envVarPrefixesGit. Loop over all matches.
  const reC2 = /(?:^|[\s;|&])GIT_CONFIG_KEY_\d+\s*=['"]?core\.hooksPath\b/ig;
  for (let mC2; (mC2 = reC2.exec(cmd)) !== null; ) {
    if (isPositionInsideQuotes(cmd, mC2.index)) continue;
    if (envVarPrefixesGit(cmd, mC2.index + mC2[0].length)) return true;
  }

  return false;
}

module.exports = { hasGitHooksBypass };
