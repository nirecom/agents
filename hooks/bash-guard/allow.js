"use strict";
// hooks/bash-guard/allow.js — the self-script allow (#2265).
//
// allow skips the permission prompt, so the match is narrow on purpose: exactly one plain
// command (no separator, redirect, substitution, group, heredoc, stripped prefix or newline), and
// either `<bash|node> <path-to-an-allow-list-entry>` whose shebang names that same interpreter,
// or a bare name that is both an allow-list entry and a PATH-exposed shim.
// The script must sit in ARGUMENT position: an exec-position path is L3's notify, not allow.
// A single-quoted `bash -c '<body>'` is re-judged once: the body must be one such plain command,
// optionally behind exactly `cd <checkout root> &&`. The body only chooses allow vs no match.

const path = require("path");
const { parse, analysisOf, resolveEffectiveSegment } = require("../lib/command-ir");
const {
  DEFAULT_ROOT,
  INTERPRETERS,
  loadAllowTargets,
  interpreterOf,
  checkoutAt,
  resolveScript,
  spellingsOf,
} = require("../lib/allow-command-list");
const { ALLOW_CODES } = require("./reasons");

const PATH_SEP_RE = /[\\/]/;
const NEWLINE_RE = /[\r\n]/;
const ENV_ROOT_RE = /^(?:\$AGENTS_MAIN_ROOT|\$\{AGENTS_MAIN_ROOT\})$/;
const ABS_RE = /^(?:[A-Za-z]:[\\/]|[\\/])/;

function interpreterName(cmd0) {
  const base = path.posix.basename(cmd0.split("\\").join("/")).replace(/\.exe$/i, "");
  return INTERPRETERS.includes(base) ? base : null;
}

const hasNewline = (text) => typeof text === "string" && NEWLINE_RE.test(text.trim());

function isFlat(ir) {
  const analysis = analysisOf(ir);
  return !(analysis.substitutions.length || analysis.groups.length || analysis.heredocs.length);
}

const noRedirects = (seg) => !Array.isArray(seg.redirects) || seg.redirects.length === 0;

// The parser folds a newline into whitespace, so `x\nrm -f y` would read as one command with
// extra arguments; any newline in the command text disqualifies it.
function isPlainSingleCommand(ir) {
  if (!ir || ir.parseFailure === true) return null;
  if (hasNewline(ir.rawText)) return null;
  if (!Array.isArray(ir.segments) || ir.segments.length !== 1) return null;
  if (Array.isArray(ir.separators) && ir.separators.length > 0) return null;
  if (!isFlat(ir)) return null;
  const seg = ir.segments[0];
  if (!seg || typeof seg.cmd0 !== "string" || seg.cmd0 === "") return null;
  if (hasNewline(seg.rawText) || !noRedirects(seg)) return null;
  const effective = resolveEffectiveSegment(seg);
  if (!effective || effective.cmd0 !== seg.cmd0) return null;
  return seg;
}

// The body of `bash -c '<body>'` exactly as bash receives it: one single-quoted token with no
// further quote inside, so the outer shell expands nothing in it. Anything else is null.
function bashCBody(seg) {
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  const raw = Array.isArray(seg.argvRaw) ? seg.argvRaw : [];
  if (argv.length !== 2 || argv[0] !== "-c" || raw[0] !== "-c" || typeof raw[1] !== "string") return null;
  const r = raw[1];
  if (r.length < 2 || r[0] !== "'" || r[r.length - 1] !== "'") return null;
  const body = r.slice(1, -1);
  return body.includes("'") || body !== argv[1] ? null : body;
}

// `cd` target -> the checkout root it names, or null: $AGENTS_MAIN_ROOT (not single-quoted or
// escaped), or an absolute path that IS the agents root or a linked worktree root of it.
function cdTarget(seg, root) {
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  if (seg.cmd0 !== "cd" || argv.length !== 1 || !noRedirects(seg)) return null;
  const effective = resolveEffectiveSegment(seg);
  if (!effective || effective.cmd0 !== "cd") return null;
  const cooked = argv[0];
  const raw = Array.isArray(seg.argvRaw) ? String(seg.argvRaw[0]) : "";
  if (ENV_ROOT_RE.test(cooked)) return raw.includes("'") || raw.includes("\\$") ? null : root;
  return typeof cooked === "string" && ABS_RE.test(cooked) ? checkoutAt(cooked, root) : null;
}

function matchBashC(body, cwd, root) {
  if (hasNewline(body)) return null;
  const inner = parse(body);
  if (!inner || inner.parseFailure === true || !Array.isArray(inner.segments)) return null;
  if (inner.segments.length === 1) return matchPlain(inner, cwd, root, 1);
  const seps = Array.isArray(inner.separators) ? inner.separators : [];
  const links = analysisOf(inner).separatorLinks;
  if (inner.segments.length !== 2 || seps.length !== 1 || seps[0] !== "&&") return null;
  if (links.length !== 1 || links[0].escaped || !isFlat(inner)) return null;
  const [cdSeg, cmdSeg] = inner.segments;
  if (!cdSeg || !cmdSeg || typeof cmdSeg.rawText !== "string") return null;
  const target = cdTarget(cdSeg, root);
  return target === null ? null : matchPlain(parse(cmdSeg.rawText), target, root, 1);
}

function matchPlain(ir, cwd, root, depth) {
  const seg = isPlainSingleCommand(ir);
  if (!seg) return null;
  const cmd0 = seg.cmd0;
  const interp = interpreterName(cmd0);
  if (interp) {
    if (interp === "bash" && depth === 0) {
      const body = bashCBody(seg);
      if (body !== null) return matchBashC(body, cwd, root);
    }
    const argv = Array.isArray(seg.argv) ? seg.argv : [];
    if (argv.length === 0) return null;
    const raw = Array.isArray(seg.argvRaw) ? seg.argvRaw[0] : undefined;
    const hit = resolveScript(spellingsOf(argv[0], raw), root, cwd);
    return hit && interpreterOf(hit.checkoutRoot, hit.entry) === interp ? ALLOW_CODES.SELF_SCRIPT : null;
  }
  if (PATH_SEP_RE.test(cmd0) || PATH_SEP_RE.test(String(seg.cmd0Raw || ""))) return null;
  return loadAllowTargets(root).exposedBare.has(cmd0) ? ALLOW_CODES.SELF_BARE : null;
}

/**
 * @param {object} ir parse()'s output
 * @param {{cwd?: string|null}} [ctx] cwd must already be verified absolute, or null
 * @param {{root?: string}} [opts] agents root override (fixture roots in tests)
 * @returns {string|null} an ALLOW_CODES value, or null
 */
function matchSelfScript(ir, ctx, opts) {
  try {
    const root = opts && typeof opts.root === "string" && opts.root !== "" ? opts.root : DEFAULT_ROOT;
    const cwd = ctx && typeof ctx.cwd === "string" && ctx.cwd !== "" ? ctx.cwd : null;
    return matchPlain(ir, cwd, root, 0);
  } catch (_e) {
    return null;
  }
}

module.exports = { matchSelfScript, isPlainSingleCommand };
