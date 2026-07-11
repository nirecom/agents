"use strict";

const { parse } = require("../command-ir");
const { resolveEffectiveCommand, resolveEffectiveArgv } = require("../bash-write-patterns/segment-utils");

// PowerShell cmdlets that write to a single positional/named -Path target.
const PWSH_SINGLE_TARGET_CMDLETS = new Set([
  "set-content", "add-content", "out-file", "new-item", "remove-item",
  "sc", "ac", "ni", "ri",
]);

// PowerShell cmdlets where the destination is the SECOND positional arg (source = first).
const PWSH_DEST_SECOND_CMDLETS = new Set([
  "move-item", "copy-item", "mi", "ci",
]);

// Tokens whose stripped values carry unresolvable shell/pwsh expansion → fail-closed.
function isUnresolvablePwshTok(t) {
  return t.includes("$") || t.includes("`") || t.includes("(");
}

/**
 * Extract PowerShell write cmdlet targets from a SegmentIR.
 *
 * For Set-Content/Add-Content/Out-File/New-Item/Remove-Item (and aliases sc/ac/ni/ri):
 *   - named: -Path/-LiteralPath/-FilePath → that value
 *   - positional fallback: first non-flag token
 * For Move-Item/Copy-Item (and aliases mi/ci):
 *   - named: -Destination/-Target → that value (source -Path is ignored)
 *   - positional fallback: SECOND non-flag token (source = first, destination = second)
 *
 * Uses resolveEffectiveCommand (C4: penetrate env-prefix) for cmdlet detection and
 * resolveEffectiveArgv (C1: argv WITHOUT the command) so the walk starts at index 0.
 * pwsh uses stripped argv values — no raw expansion.
 *
 * Backward-compat: a raw command string is parsed and its cmdlet segment used.
 * Returns: string[] on success, null on parse failure.
 */
function extractPwshWriteTargets(seg) {
  // Backward compat: accept a raw command string.
  if (typeof seg === "string") {
    const ir = parse(seg);
    if (!ir || ir.parseFailure) return null;
    const s = (ir.segments || []).find((x) => {
      const c = resolveEffectiveCommand(x);
      return c != null && (PWSH_SINGLE_TARGET_CMDLETS.has(c.toLowerCase()) || PWSH_DEST_SECOND_CMDLETS.has(c.toLowerCase()));
    }) || ir.segments[0];
    seg = s;
  }
  if (!seg || !Array.isArray(seg.argv)) return null;

  const effCmd = resolveEffectiveCommand(seg);
  if (effCmd == null) return null;
  const cmdletRaw = effCmd.toLowerCase();
  const isSingle = PWSH_SINGLE_TARGET_CMDLETS.has(cmdletRaw);
  const isDest = PWSH_DEST_SECOND_CMDLETS.has(cmdletRaw);
  if (!isSingle && !isDest) return null;

  const argv = resolveEffectiveArgv(seg);

  // Fail-closed: any token carrying unresolvable expansion.
  for (const t of argv) {
    if (isUnresolvablePwshTok(t)) return null;
  }

  let namedTarget = null;
  const positionals = [];
  let i = 0;

  while (i < argv.length) {
    const t = argv[i];
    const tl = t.toLowerCase();
    if (tl === "-path" || tl === "-literalpath" || tl === "-filepath") {
      if (isDest) {
        // For Move/Copy, -Path is the source — skip the value.
        i += 2;
        continue;
      }
      if (i + 1 < argv.length) {
        namedTarget = argv[i + 1];
        i += 2;
        continue;
      }
      return null;
    }
    if (tl === "-destination" || tl === "-target") {
      if (i + 1 < argv.length) {
        namedTarget = argv[i + 1];
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
      i += (i + 1 < argv.length && !argv[i + 1].startsWith("-")) ? 2 : 1;
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
