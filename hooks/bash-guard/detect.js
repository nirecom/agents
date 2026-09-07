"use strict";
// hooks/bash-guard/detect.js — IR -> Hit[].
//
// Reads parse()'s output and analysisOf(ir) only; a regex over raw command text would
// re-create the quoting bugs the IR exists to remove (`grep 'a;b' file` is not a chain).
// Separator ids match EXACTLY (sep === "&&"), never by substring: includes("|") would
// drag `||` in, and `||` is outside the approved set.
// There is deliberately NO "is this a single command" predicate — that shape dropped
// every hit for `echo $(date)` and `A=1 cmd`. Single-ness is just "zero hits".

const { analysisOf, resolveEffectiveSegment } = require("../lib/command-ir");

const SEPARATOR_LITERALS = Object.freeze({ "&&": "chain-and", ";": "chain-semicolon", "|": "pipe" });
const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;
const WRITE_REDIRECT_RE = /^(?:\d+|&)?(>>?)$/;

const hit = (literalId, kind, index, sample) => ({ literalId, at: { kind, index }, sample });

// separatorLinks, not ir.separators: the links carry the `escaped` flag, so `find ... \;`
// and `echo a \&\& b` never become hits. Link index mirrors the separators index.
function separatorHits(analysis) {
  const out = [];
  analysis.separatorLinks.forEach((link) => {
    if (link.escaped) return;
    const literalId = SEPARATOR_LITERALS[link.sep];
    if (literalId) out.push(hit(literalId, "separator", link.index, link.sep));
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
    ...separatorHits(analysis),
    ...analysisHits(analysis),
    ...redirectHits(ir),
    ...envPrefixHits(ir),
  ];
}

module.exports = { detect, SEPARATOR_LITERALS };
