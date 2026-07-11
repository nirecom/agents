"use strict";

const { resolveEffectiveCommand } = require("./bash-write-patterns/segment-utils");
const { extractRedirectTargets } = require("./bash-write-targets/redirect");
const { extractTeeTargets } = require("./bash-write-targets/tee");
const { extractPwshWriteTargets } = require("./bash-write-targets/pwsh");
const { extractCpMvDestination } = require("./bash-write-targets/cp-mv");
const { extractRmTargets } = require("./bash-write-targets/rm");
const { extractStagedFiles } = require("./bash-write-targets/staged");

const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// Return the RAW argv tokens that follow the env-prefix (VAR=val) run and the
// effective command. Shared with the per-verb extractors.
function resolveRawArgvAfterEnvPrefix(seg) {
  if (!seg || !Array.isArray(seg.argv) || !Array.isArray(seg.argvRaw)) return [];
  const skipCmd = ASSIGN_RE.test(seg.cmd0 || "");
  if (!skipCmd) return seg.argvRaw.slice();
  const idx = seg.argv.findIndex((a) => !ASSIGN_RE.test(a));
  if (idx === -1) return [];
  return seg.argvRaw.slice(idx + 1);
}

// Verb sets: the switch between full write-scope scanning and the narrower
// shell-config guard (rm excluded — rm is a delete, not a config-file write).
const FULL_VERB_SET = new Set(["redirect", "tee", "pwsh", "cp", "mv", "rm"]);
const SHELL_CONFIG_VERB_SET = new Set(["redirect", "tee", "pwsh", "cp", "mv"]);

const PWSH_CMDLET_RE = /^(?:set-content|add-content|out-file|new-item|remove-item|move-item|copy-item|sc|ac|ni|ri|mi|ci)$/;

/**
 * Collect write targets from ALL segments of a parsed command (#1069 fix:
 * every pipeline segment is scanned, not just the first verb).
 *
 * @param {object[]} segments - SegmentIR array from parse().segments
 * @param {object} opts - { verbs?: Set<string> } (defaults to FULL_VERB_SET)
 * @returns {{targets: string[]|null, parseFailure: boolean}}
 *   targets: collected write targets (null when none), parseFailure: any
 *   extractor returned null (fail-closed).
 */
function collectWriteTargetsFromSegments(segments, opts) {
  const verbs = (opts && opts.verbs) ? opts.verbs : FULL_VERB_SET;
  const targets = [];
  let parseFailure = false;

  for (const seg of segments) {
    if (verbs.has("redirect") && seg.redirects && seg.redirects.some((r) => r.op !== "<" && r.op !== "<<<")) {
      const r = extractRedirectTargets(seg);
      if (r === null) parseFailure = true; else targets.push(...r);
    }
    const effCmd = resolveEffectiveCommand(seg);
    if (effCmd == null) continue;
    const effCmdLower = effCmd.toLowerCase();

    if (verbs.has("tee") && effCmd === "tee") {
      const t = extractTeeTargets(seg);
      if (t === null) parseFailure = true; else targets.push(...t);
    } else if (verbs.has("pwsh") && PWSH_CMDLET_RE.test(effCmdLower)) {
      const p = extractPwshWriteTargets(seg);
      if (p === null) parseFailure = true; else targets.push(...p);
    } else if ((verbs.has("cp") && effCmd === "cp") || (verbs.has("mv") && effCmd === "mv")) {
      const d = extractCpMvDestination(seg);
      if (d === null) parseFailure = true; else if (d !== undefined) targets.push(d);
    } else if (verbs.has("rm") && effCmd === "rm") {
      const r = extractRmTargets(seg);
      if (r === null) parseFailure = true; else targets.push(...r);
    }
  }
  return { targets: targets.length > 0 ? targets : null, parseFailure };
}

module.exports = {
  extractRedirectTargets,
  extractTeeTargets,
  extractPwshWriteTargets,
  extractCpMvDestination,
  extractRmTargets,
  extractStagedFiles,
  collectWriteTargetsFromSegments,
  resolveRawArgvAfterEnvPrefix,
  FULL_VERB_SET,
  SHELL_CONFIG_VERB_SET,
};
