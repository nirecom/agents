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

// Write targets of a cmdlet segment (or a raw command string): -Path/-LiteralPath/-FilePath or the
// first positional for single-target cmdlets; -Destination/-Target or the second positional for
// Move/Copy. string[] on success, null on parse failure or unresolvable expansion (fail-closed).
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

const PWSH_RENAME_CMDLETS = new Set(["move-item", "mi", "rename-item", "rni"]);
const PWSH_SWITCHES = new Set([
  "-force", "-recurse", "-whatif", "-confirm", "-passthru", "-noclobber", "-append",
  "-verbose", "-debug", "-nonewline", "-container",
]);

// Named parameters (lower-cased name -> value) and positionals of a cmdlet argv.
function pwshOperands(argv) {
  const named = {};
  const positionals = [];
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (!t.startsWith("-") || t === "-") { positionals.push(t); continue; }
    const tl = t.toLowerCase();
    if (PWSH_SWITCHES.has(tl) || t.includes(":")) continue;
    if (i + 1 < argv.length) named[tl] = argv[++i];
  }
  return { named, positionals };
}

// Move-Item / Rename-Item parameter grammar. Names match case-insensitively; a parameter outside
// these sets (including an abbreviated prefix such as -Li) makes the segment unreadable (null).
const RENAME_PATH_PARAMS = new Set(["-path", "-literalpath", "-lp", "-pspath"]);
const RENAME_VALUE_PARAMS = new Set([
  "-destination", "-newname", "-filter", "-include", "-exclude", "-credential",
  "-erroraction", "-ea", "-warningaction", "-wa", "-informationaction", "-infa",
  "-errorvariable", "-ev", "-warningvariable", "-wv", "-informationvariable", "-iv",
  "-outvariable", "-ov", "-outbuffer", "-ob", "-pipelinevariable", "-pv", "-progressaction", "-proga",
]);
const RENAME_SWITCHES = new Set([
  "-force", "-passthru", "-whatif", "-wi", "-confirm", "-cf", "-usetransaction",
  "-verbose", "-vb", "-debug", "-db",
]);

const isRenameSegment = (seg) => {
  const c = seg ? resolveEffectiveCommand(seg) : null;
  return c != null && PWSH_RENAME_CMDLETS.has(c.toLowerCase());
};

const splitPathList = (v) => v.split(",").filter((p) => p !== "");

function segmentRenameSources(seg) {
  if (!isRenameSegment(seg)) return [];
  const argv = resolveEffectiveArgv(seg);
  const named = [];
  const positionals = [];
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (!t.startsWith("-") || t === "-") { positionals.push(t); continue; }
    const colon = t.indexOf(":");
    const name = (colon === -1 ? t : t.slice(0, colon)).toLowerCase();
    const inline = colon === -1 ? null : t.slice(colon + 1);
    if (RENAME_SWITCHES.has(name)) continue;
    const isPath = RENAME_PATH_PARAMS.has(name);
    if (!isPath && !RENAME_VALUE_PARAMS.has(name)) return null;
    let value = inline;
    if (value === null) {
      if (i + 1 >= argv.length) return null;
      value = argv[++i];
    }
    if (isPath) named.push(...splitPathList(value));
  }
  if (named.length > 0) return named;
  return positionals.length > 0 ? splitPathList(positionals[0]) : [];
}

// The single implementation of "which items does Move-Item / Rename-Item (or an alias) rename away".
// A SegmentIR yields its own sources; a command string yields the sources of every rename segment.
// [] when there is no rename; null on parse failure or on any unreadable rename segment.
function extractRenameSources(seg) {
  if (typeof seg !== "string") return segmentRenameSources(seg);
  const ir = parse(seg);
  if (!ir || ir.parseFailure) return null;
  const out = [];
  for (const s of ir.segments || []) {
    const src = segmentRenameSources(s);
    if (src === null) return null;
    out.push(...src);
  }
  return out;
}

module.exports = {
  extractPwshWriteTargets,
  extractRenameSources,
  pwshOperands,
  PWSH_SINGLE_TARGET_CMDLETS,
  PWSH_DEST_SECOND_CMDLETS,
  PWSH_RENAME_CMDLETS,
};
