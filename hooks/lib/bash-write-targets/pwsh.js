"use strict";

// PowerShell cmdlets that write to a single positional/named -Path target.
const PWSH_SINGLE_TARGET_CMDLETS = new Set([
  "set-content", "add-content", "out-file", "new-item", "remove-item",
  "sc", "ac", "ni", "ri",
]);

// PowerShell cmdlets where the destination is the SECOND positional arg (source = first).
const PWSH_DEST_SECOND_CMDLETS = new Set([
  "move-item", "copy-item", "mi", "ci",
]);

// Quote-aware tokenizer for PowerShell command strings.
// Returns string[] of tokens on success, null on parse failure (unresolvable).
function tokenizePwsh(cmd) {
  const tokens = [];
  let i = 0;
  while (i < cmd.length) {
    while (i < cmd.length && /\s/.test(cmd[i])) i++;
    if (i >= cmd.length) break;
    if (cmd[i] === '"') {
      let content = "", j = i + 1;
      while (j < cmd.length && cmd[j] !== '"') {
        if (cmd[j] === "$" || cmd[j] === "`") return null;
        if (cmd[j] === "\\" && j + 1 < cmd.length) { content += cmd[j + 1]; j += 2; }
        else content += cmd[j++];
      }
      tokens.push(content);
      i = j + 1;
    } else if (cmd[i] === "'") {
      let content = "", j = i + 1;
      while (j < cmd.length && cmd[j] !== "'") content += cmd[j++];
      tokens.push(content);
      i = j + 1;
    } else {
      let content = "", j = i;
      while (j < cmd.length && !/\s/.test(cmd[j])) {
        if (cmd[j] === "$" || cmd[j] === "`" || cmd[j] === "(") return null;
        content += cmd[j++];
      }
      if (content) tokens.push(content);
      i = j;
    }
  }
  return tokens;
}

/**
 * Extract PowerShell write cmdlet targets from a command string.
 *
 * For Set-Content/Add-Content/Out-File/New-Item/Remove-Item (and aliases sc/ac/ni/ri):
 *   - named: -Path/-LiteralPath/-FilePath → that value
 *   - positional fallback: first non-flag token
 * For Move-Item/Copy-Item (and aliases mi/ci):
 *   - named: -Destination/-Target → that value (source -Path is ignored)
 *   - positional fallback: SECOND non-flag token (source = first, destination = second)
 *   - no destination → null (fail-closed)
 *
 * Returns: string[] on success, null on parse failure.
 */
function extractPwshWriteTargets(cmd) {
  if (!cmd || typeof cmd !== "string") return null;

  const tokens = tokenizePwsh(cmd);
  if (tokens === null || tokens.length === 0) return null;

  const cmdletRaw = tokens[0].toLowerCase();
  const isSingle = PWSH_SINGLE_TARGET_CMDLETS.has(cmdletRaw);
  const isDest = PWSH_DEST_SECOND_CMDLETS.has(cmdletRaw);

  if (!isSingle && !isDest) return null;

  let namedTarget = null;
  const positionals = [];
  let i = 1;

  while (i < tokens.length) {
    const t = tokens[i];
    const tl = t.toLowerCase();
    if (tl === "-path" || tl === "-literalpath" || tl === "-filepath") {
      if (isDest) {
        // For Move/Copy, -Path is the source — skip the value.
        i += 2;
        continue;
      }
      if (i + 1 < tokens.length) {
        namedTarget = tokens[i + 1];
        i += 2;
        continue;
      }
      return null;
    }
    if (tl === "-destination" || tl === "-target") {
      if (i + 1 < tokens.length) {
        namedTarget = tokens[i + 1];
        i += 2;
        continue;
      }
      return null;
    }
    if (tl === "-value" || tl === "-encoding" || tl === "-force" ||
        tl === "-recurse" || tl === "-itemtype" || tl === "-whatif" ||
        tl === "-confirm" || tl === "-passthru" || tl === "-noclobber" ||
        tl === "-append" || tl === "-width" || tl === "-inputobject") {
      // Known non-path named params — skip name and value.
      i += (i + 1 < tokens.length && !tokens[i + 1].startsWith("-")) ? 2 : 1;
      continue;
    }
    if (t.startsWith("-")) {
      i++;
      continue;
    }
    positionals.push(t);
    i++;
  }

  if (namedTarget !== null) return [namedTarget];

  if (isSingle) {
    return positionals.length > 0 ? [positionals[0]] : null;
  }

  // isDest: destination = second positional.
  if (positionals.length < 2) return null;
  return [positionals[1]];
}

module.exports = { extractPwshWriteTargets };
