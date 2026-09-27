"use strict";
// hooks/bash-guard/allow.js — the self-script allow (#2265).
//
// allow skips the permission prompt, so the match is narrow on purpose: exactly one plain
// command (no separator, redirect, substitution, group, heredoc or stripped prefix), and
// either `<bash|node> <path-to-an-allow-list-entry>` whose shebang names that same
// interpreter, or a bare name that is both an allow-list entry and a PATH-exposed shim.
// The script must sit in ARGUMENT position: an exec-position path is L3's notify, not allow.

const path = require("path");
const { analysisOf, resolveEffectiveSegment } = require("../lib/command-ir");
const {
  DEFAULT_ROOT,
  INTERPRETERS,
  loadAllowTargets,
  interpreterOf,
  resolveEntry,
  spellingsOf,
} = require("../lib/allow-command-list");
const { ALLOW_CODES } = require("./reasons");

const PATH_SEP_RE = /[\\/]/;

function interpreterName(cmd0) {
  const base = path.posix.basename(cmd0.split("\\").join("/")).replace(/\.exe$/i, "");
  return INTERPRETERS.includes(base) ? base : null;
}

function isPlainSingleCommand(ir) {
  if (!ir || ir.parseFailure === true) return null;
  if (!Array.isArray(ir.segments) || ir.segments.length !== 1) return null;
  if (Array.isArray(ir.separators) && ir.separators.length > 0) return null;
  const analysis = analysisOf(ir);
  if (analysis.substitutions.length || analysis.groups.length || analysis.heredocs.length) return null;
  const seg = ir.segments[0];
  if (!seg || typeof seg.cmd0 !== "string" || seg.cmd0 === "") return null;
  if (Array.isArray(seg.redirects) && seg.redirects.length > 0) return null;
  const effective = resolveEffectiveSegment(seg);
  if (!effective || effective.cmd0 !== seg.cmd0) return null;
  return seg;
}

/**
 * @param {object} ir parse()'s output
 * @param {{cwd?: string|null}} [ctx] cwd must already be verified absolute, or null
 * @param {{root?: string}} [opts] agents root override (fixture roots in tests)
 * @returns {string|null} an ALLOW_CODES value, or null
 */
function matchSelfScript(ir, ctx, opts) {
  try {
    const seg = isPlainSingleCommand(ir);
    if (!seg) return null;
    const root = opts && typeof opts.root === "string" && opts.root !== "" ? opts.root : DEFAULT_ROOT;
    const cwd = ctx && typeof ctx.cwd === "string" && ctx.cwd !== "" ? ctx.cwd : null;
    const cmd0 = seg.cmd0;

    const interp = interpreterName(cmd0);
    if (interp) {
      const argv = Array.isArray(seg.argv) ? seg.argv : [];
      if (argv.length === 0) return null;
      const raw = Array.isArray(seg.argvRaw) ? seg.argvRaw[0] : undefined;
      const entry = resolveEntry(spellingsOf(argv[0], raw), root, cwd);
      return entry && interpreterOf(root, entry) === interp ? ALLOW_CODES.SELF_SCRIPT : null;
    }

    if (PATH_SEP_RE.test(cmd0) || PATH_SEP_RE.test(String(seg.cmd0Raw || ""))) return null;
    return loadAllowTargets(root).exposedBare.has(cmd0) ? ALLOW_CODES.SELF_BARE : null;
  } catch (_e) {
    return null;
  }
}

module.exports = { matchSelfScript };
