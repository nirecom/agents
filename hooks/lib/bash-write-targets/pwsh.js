"use strict";

const { parse } = require("../command-ir");
const {
  resolveEffectiveCommand,
  resolveEffectiveArgv,
  commandBasename,
} = require("../bash-write-patterns/segment-utils");

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

// Returns the write targets as string[], or null on parse failure.
function extractPwshWriteTargets(seg) {
  // Backward compat: accept a raw command string.
  if (typeof seg === "string") {
    const ir = parse(seg);
    if (!ir || ir.parseFailure) return null;
    const s = (ir.segments || []).find((x) => {
      const c = commandBasename(resolveEffectiveCommand(x));
      return c != null && (PWSH_SINGLE_TARGET_CMDLETS.has(c) || PWSH_DEST_SECOND_CMDLETS.has(c));
    }) || ir.segments[0];
    seg = s;
  }
  if (!seg || !Array.isArray(seg.argv)) return null;

  const effCmd = resolveEffectiveCommand(seg);
  if (effCmd == null) return null;
  const cmdletRaw = commandBasename(effCmd);
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

// PowerShell delete cmdlets/aliases that accept -Recurse (#2210).
const PWSH_RECURSIVE_DELETE_CMDLETS = new Set([
  "remove-item", "ri", "rd", "rm", "rmdir", "erase", "del",
]);

// Cmdlets/aliases that ENUMERATE recursively and can feed a delete downstream.
const PWSH_CHILDITEM_CMDLETS = new Set(["get-childitem", "gci", "dir", "ls", "childitem"]);

// `minNameLen` raises the shortest accepted abbreviation: the pipeline judge asks
// for 2 so POSIX `ls -r` (reverse sort) cannot masquerade as the pwsh switch.
function recurseFlagVerdict(argv, minNameLen = 1) {
  for (const tok of argv) {
    if (typeof tok !== "string" || !tok.startsWith("-")) continue;
    const body = tok.slice(1);
    const colon = body.indexOf(":");
    const flagName = colon === -1 ? body : body.slice(0, colon);
    const suffix = colon === -1 ? null : body.slice(colon + 1);
    if (isUnresolvablePwshTok(flagName)) return null;
    if (flagName.length < minNameLen || !"recurse".startsWith(flagName.toLowerCase())) continue;
    if (suffix === null) return true;
    const sl = suffix.toLowerCase();
    if (sl === "$false") continue;
    if (sl === "$true") return true;
    if (isUnresolvablePwshTok(suffix)) return null;
    return true;
  }
  return false;
}

// Three-valued: null = unresolvable flag content, so the caller fails closed.
// Only `-`-leading tokens are judged — a bare token is a TARGET, so
// `Remove-Item -Recurse "$dir"` must not fail closed on the path.
// Contract: detail.md Step 2.
function hasRecursivePwshFlag(seg) {
  const effCmd = resolveEffectiveCommand(seg);
  if (effCmd == null || !PWSH_RECURSIVE_DELETE_CMDLETS.has(commandBasename(effCmd))) return false;
  return recurseFlagVerdict(resolveEffectiveArgv(seg));
}

// These heads run a script block per item, so the delete sits inside `{ ... }`
// and the segment's own command is never it. The parser can glue the brace onto
// either side (`%{`, `{ ri`), hence the split before classifying.
const PWSH_BLOCK_PIPELINE_HEADS = new Set(["foreach-object", "foreach", "%", "where-object", "where", "?"]);

function braceParts(tok) {
  return typeof tok === "string" ? tok.split(/[{};|]/) : [];
}

function blockBodyDeletes(seg) {
  const toks = [seg.cmd0, ...(Array.isArray(seg.argv) ? seg.argv : [])];
  return toks.some((tok) => braceParts(tok).some((part) => {
    const base = commandBasename(part);
    return base != null && PWSH_RECURSIVE_DELETE_CMDLETS.has(base);
  }));
}

// Only the SAME pipeline counts: with aligned `separators` the walk stops at the
// first non-`|` join, and without them it looks no further than the neighbour.
function upstreamRecurseInPipeline(segments, index, separators) {
  const aligned = Array.isArray(separators) && separators.length === segments.length - 1;
  for (let j = index - 1; j >= (aligned ? 0 : index - 1); j--) {
    if (aligned && separators[j] !== "|") return false;
    const prev = segments[j];
    if (!prev) return false;
    const prevCmd = resolveEffectiveCommand(prev);
    if (prevCmd != null && PWSH_CHILDITEM_CMDLETS.has(commandBasename(prevCmd)) &&
        recurseFlagVerdict(resolveEffectiveArgv(prev), 2) !== false) return true;
  }
  return false;
}

// The recursion can live UPSTREAM: `Get-ChildItem dir -Recurse | Remove-Item`
// deletes a tree though the delete segment carries no `-Recurse` of its own.
// Scope: top-level segments of one pipeline, not one crossing a subshell or an
// interpreter body.
function hasRecursivePwshPipelineFlag(segments, index, separators) {
  if (!Array.isArray(segments) || index < 1) return false;
  const cur = segments[index];
  if (!cur) return false;
  const curCmd = resolveEffectiveCommand(cur);
  const curBase = curCmd == null ? null : commandBasename(curCmd);
  if (curBase == null) return false;
  const isDelete = PWSH_RECURSIVE_DELETE_CMDLETS.has(curBase);
  const isBlock = PWSH_BLOCK_PIPELINE_HEADS.has(curBase.split("{")[0]) && blockBodyDeletes(cur);
  if (!isDelete && !isBlock) return false;
  return upstreamRecurseInPipeline(segments, index, separators);
}

// PWSH_BLOCK_PIPELINE_HEADS is exported so recursive-delete-scan.js's
// transparent-head peel shares this set instead of keeping a second copy.
module.exports = {
  extractPwshWriteTargets,
  hasRecursivePwshFlag,
  hasRecursivePwshPipelineFlag,
  PWSH_BLOCK_PIPELINE_HEADS,
};
