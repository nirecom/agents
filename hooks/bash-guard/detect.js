"use strict";
// hooks/bash-guard/detect.js — IR -> Hit[] (deny) and IR -> Notice[] (notify).
//
// Reads parse()'s output and analysisOf(ir) only; a regex over raw command text would
// re-create the quoting bugs the IR exists to remove (`grep 'a;b' file` is not a chain).
// Separator ids match EXACTLY (sep === "&&"), never by substring: includes("|") would
// drag `||` in, and `||` is outside the approved set.
// There is deliberately NO "is this a single command" predicate — that shape dropped
// every hit for `echo $(date)` and `A=1 cmd`. Single-ness is just "zero hits".
// detectIneffective() finds commands that run but achieve nothing (a sentinel issued
// without echo or in an unrecognized shape, a script executed with no interpreter).

const path = require("path");
const { analysisOf, resolveEffectiveSegment } = require("../lib/command-ir");
const { isSentinel, isStrictSentinel } = require("../lib/sentinel-patterns");
const { resolveEntry, spellingsOf, INTERPRETERS } = require("../lib/allow-command-list");
const { NOTIFY_CODES } = require("./reasons");

const SEPARATOR_LITERALS = Object.freeze({ "&&": "chain-and", ";": "chain-semicolon", "|": "pipe" });
const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;
const WRITE_REDIRECT_RE = /^(?:\d+|&)?(>>?)$/;
const XARGS_BASENAMES = Object.freeze(["xargs", "xargs.exe"]);
const SENTINEL_TOKEN_RE = /^<<WORKFLOW_[A-Za-z0-9_]+(?:[: ][^>]*)?>>$/;
const SCRIPT_EXT_RE = /\.(?:sh|js|cjs|mjs)$/i;
const PATH_SEP_RE = /[\\/]/;

const hit = (literalId, kind, index, sample) => ({ literalId, at: { kind, index }, sample });
const notice = (notifyId, index) => ({ notifyId, at: { kind: "segment", index }, sample: null });
const basenameAny = (p) => path.posix.basename(String(p).split("\\").join("/"));

// `find ... | xargs cmd` is the one sanctioned pipe: the right-hand segment comes from
// separatorLinks, because segments[i+1] is wrong for leading/trailing separators.
function pipesIntoXargs(link, ir) {
  if (link.sep !== "|" || link.rightSegment == null) return false;
  const seg = (Array.isArray(ir.segments) ? ir.segments : [])[link.rightSegment];
  const effective = seg ? resolveEffectiveSegment(seg) : null;
  if (!effective || typeof effective.cmd0 !== "string" || effective.cmd0 === "") return false;
  return XARGS_BASENAMES.includes(basenameAny(effective.cmd0));
}

// separatorLinks, not ir.separators: the links carry the `escaped` flag, so `find ... \;`
// and `echo a \&\& b` never become hits. Link index mirrors the separators index.
function separatorHits(analysis, ir) {
  const out = [];
  analysis.separatorLinks.forEach((link) => {
    if (link.escaped) return;
    const literalId = SEPARATOR_LITERALS[link.sep];
    if (!literalId || pipesIntoXargs(link, ir)) return;
    out.push(hit(literalId, "separator", link.index, link.sep));
  });
  return out;
}

// Substitutions, groups and heredocs come from the quote-aware scan, so `echo '$(date)'`
// yields nothing while `echo "$(pwd)"` yields a hit — double quotes do not stop a
// substitution from executing. A heredoc opener counts even when the body is never
// terminated: the `<<` was still issued on the command line.
function analysisHits(analysis) {
  const out = [];
  analysis.substitutions.forEach((s) =>
    out.push(hit(s.kind === "backtick" ? "backtick" : "cmd-subst", "span", s.index, s.text))
  );
  analysis.groups.forEach((g) => out.push(hit("brace-group", "span", g.index, "{ ... }")));
  analysis.heredocs.forEach((h, i) => out.push(hit("heredoc", "span", i, "<<" + String(h.tag))));
  return out;
}

// Only file-writing redirects. `<`, `<<` and `>&` share the redirect token class but are
// not what the discipline table names, and a heredoc is already its own literal.
// An `&`-prefixed TARGET is fd duplication or closure (`2>&1`, `2>&-`): the operator still
// spells `2>`, but nothing is written to a file, so it is not the redirect the table names.
function redirectHits(ir) {
  const out = [];
  let n = 0;
  (Array.isArray(ir.segments) ? ir.segments : []).forEach((seg) => {
    (seg && Array.isArray(seg.redirects) ? seg.redirects : []).forEach((r) => {
      if (String(r.target || "").startsWith("&")) return;
      const m = WRITE_REDIRECT_RE.exec(String(r.op));
      if (!m) return;
      out.push(hit(m[1] === ">>" ? "redirect-append" : "redirect-out", "redirect", n++, r.op));
    });
  });
  return out;
}

// An env prefix is what resolveEffectiveSegment() had to strip: the assignment is only a
// prefix when a real command follows it, so a bare `A=1` (no command) is not a hit.
function envPrefixHits(ir) {
  const out = [];
  (Array.isArray(ir.segments) ? ir.segments : []).forEach((seg, index) => {
    if (!seg || typeof seg.cmd0 !== "string" || !ASSIGN_RE.test(seg.cmd0)) return;
    const effective = resolveEffectiveSegment(seg);
    if (effective && effective.cmd0 && effective.cmd0 !== seg.cmd0) {
      out.push(hit("env-prefix", "segment", index, seg.cmd0));
    }
  });
  return out;
}

/**
 * @param {object} ir the value parse() returned — pass it through, never a spread copy,
 *                    or the non-enumerable analysis is lost and detection under-reports.
 * @returns {Array<{literalId: string, at: {kind: string, index: number}, sample: string}>}
 */
function detect(ir) {
  if (!ir || typeof ir !== "object") return [];
  const analysis = analysisOf(ir);
  return [
    ...separatorHits(analysis, ir),
    ...analysisHits(analysis),
    ...redirectHits(ir),
    ...envPrefixHits(ir),
  ];
}

// command-ir reads a quoted `"<<WORKFLOW_X>>"` as a `<` redirect whose target is
// `<WORKFLOW_X>>`, so the sentinel token is rebuilt from the redirect here.
function recoveredTokens(seg) {
  return (Array.isArray(seg.redirects) ? seg.redirects : [])
    .filter((r) => r && r.op === "<" && typeof r.target === "string" && r.target.startsWith("<"))
    .map((r) => "<" + r.target);
}

const isSentinelToken = (t) => typeof t === "string" && SENTINEL_TOKEN_RE.test(t);

// L1: the sentinel is the command itself (echo forgotten). L2: echo of a sentinel-shaped
// token in a shape neither the strict nor the LOOKSLIKE regexes accept, judged per segment.
function sentinelNotice(seg) {
  const recovered = recoveredTokens(seg);
  const effective = resolveEffectiveSegment(seg);
  if (!effective || !effective.cmd0) {
    const argv = Array.isArray(seg.argv) ? seg.argv : [];
    return argv.length === 0 && recovered.some(isSentinelToken) ? NOTIFY_CODES.SENTINEL_NO_ECHO : null;
  }
  if (isSentinelToken(effective.cmd0)) return NOTIFY_CODES.SENTINEL_NO_ECHO;
  if (effective.cmd0 !== "echo") return null;
  const argv = Array.isArray(effective.argv) ? effective.argv : [];
  if (!argv.concat(recovered).some(isSentinelToken)) return null;
  const text = String(seg.rawText || "").trim();
  return isStrictSentinel(text) || isSentinel(text) ? null : NOTIFY_CODES.SENTINEL_UNRECOGNIZED;
}

// L3: a path-shaped cmd0 that is a script (by extension, or by being an allow-list entry)
// run with no interpreter. The interpreters themselves are never the script.
function scriptNotice(seg, ctx) {
  const effective = resolveEffectiveSegment(seg);
  if (!effective || typeof effective.cmd0 !== "string" || effective.cmd0 === "") return null;
  const cooked = effective.cmd0;
  const raw = typeof effective.cmd0Raw === "string" ? effective.cmd0Raw : "";
  if (!PATH_SEP_RE.test(cooked) && !PATH_SEP_RE.test(raw)) return null;
  const base = basenameAny(cooked);
  if (INTERPRETERS.includes(base.replace(/\.exe$/i, ""))) return null;
  if (SCRIPT_EXT_RE.test(base)) return NOTIFY_CODES.SCRIPT_NO_INTERPRETER;
  const cwd = ctx && typeof ctx.cwd === "string" && ctx.cwd !== "" ? ctx.cwd : null;
  const root = ctx && typeof ctx.agentsRoot === "string" ? ctx.agentsRoot : undefined;
  return resolveEntry(spellingsOf(cooked, raw), root, cwd) ? NOTIFY_CODES.SCRIPT_NO_INTERPRETER : null;
}

/**
 * @param {object} ir parse()'s output
 * @param {{cwd?: string|null, agentsRoot?: string}} [ctx]
 * @returns {Array<{notifyId: string, at: {kind: "segment", index: number}, sample: null}>}
 */
function detectIneffective(ir, ctx) {
  if (!ir || typeof ir !== "object" || !Array.isArray(ir.segments)) return [];
  const out = [];
  ir.segments.forEach((seg, index) => {
    if (!seg) return;
    const id = sentinelNotice(seg) || scriptNotice(seg, ctx);
    if (id) out.push(notice(id, index));
  });
  return out;
}

module.exports = { detect, detectIneffective, SEPARATOR_LITERALS };
