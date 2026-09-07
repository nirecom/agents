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

/**
 * Extract PowerShell write cmdlet targets from a SegmentIR (or a raw string).
 * Single-target cmdlets: -Path/-LiteralPath/-FilePath, else first positional.
 * Move/Copy: -Destination/-Target, else SECOND positional (first = source).
 * Env-prefix is penetrated via resolveEffectiveCommand/Argv; stripped values
 * only — no raw expansion. Returns string[], or null on parse failure.
 */
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

// Three-valued `-Recurse` verdict over an argv. `minNameLen` raises the shortest
// accepted abbreviation: the pipeline judge asks for 2 so POSIX `ls -r`/`-R`
// (reverse sort / recursive LIST) cannot masquerade as the pwsh switch.
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

/**
 * hasRecursivePwshFlag(seg) — does this PowerShell delete request recursion?
 * true = yes; null = recursive-capable cmdlet with unresolvable flag content
 * (caller fails closed); false = out of scope / no recursion. Only `-`-leading
 * tokens are judged — a bare token is a TARGET, so `Remove-Item -Recurse
 * "$dir"` must not fail closed on the path. `-Recurse:$false` is an explicit
 * opt-out; any other static suffix counts as on. Contract: detail.md Step 2.
 */
function hasRecursivePwshFlag(seg) {
  const effCmd = resolveEffectiveCommand(seg);
  if (effCmd == null || !PWSH_RECURSIVE_DELETE_CMDLETS.has(commandBasename(effCmd))) return false;
  return recurseFlagVerdict(resolveEffectiveArgv(seg));
}

// Pipeline heads that run a SCRIPT BLOCK once per upstream item. The delete
// cmdlet then sits INSIDE `{ ... }`, so the segment's own command is the block
// head and never the delete (#2210 round-5). The parser can glue the brace onto
// either side (`%{`, `{ ri`), so both the head name and the body tokens are
// split on brace/separator characters before being classified.
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

// The nearest upstream enumerator in the SAME pipeline. When `separators` aligns
// with the segment list the walk stops at the first non-`|` join; without that
// alignment only the adjacent segment is considered, as before.
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

/**
 * hasRecursivePwshPipelineFlag(segments, index, separators) — the recursion
 * lives UPSTREAM: `Get-ChildItem dir -Recurse | Remove-Item` deletes a whole
 * tree though the delete segment carries no `-Recurse` of its own (#2210 C11),
 * and `... | ForEach-Object { Remove-Item $_ }` hides the delete one level
 * further in, inside the script block (#2210 round-5). Scope limitation:
 * top-level segments of ONE pipeline — a pipeline crossing a subshell or an
 * interpreter body is not tracked. Two-valued: an unresolvable upstream flag
 * also blocks.
 */
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

// PWSH_BLOCK_PIPELINE_HEADS is exported because recursive-delete-scan.js's
// transparent-head peel needs the SAME set (#2210 round-6) — it previously kept
// a byte-identical copy, which is two owners for one fact (CPR-SSOT).
module.exports = {
  extractPwshWriteTargets,
  hasRecursivePwshFlag,
  hasRecursivePwshPipelineFlag,
  PWSH_BLOCK_PIPELINE_HEADS,
};
