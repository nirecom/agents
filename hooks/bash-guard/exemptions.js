"use strict";
// hooks/bash-guard/exemptions.js — the two approved carve-outs, and their scopes.
//
// SCOPE IS THE WHOLE POINT. Round 1 forgave a command wholesale the moment any reason to
// forgive appeared, so one excused `|` also excused the `>` beside it. An exemption now
// declares what it may forgive: a "hit" exemption removes only the literal ids it names
// at the position it matched, while a "command" exemption clears the line because the
// grant it reads blessed the line. Only allow-rule-match may be command-scoped — the user
// wrote that command into permissions.allow themselves, and denying it for its shape
// would overrule an explicit grant.

const path = require("path");
const { resolveEffectiveSegment } = require("../lib/command-ir");
const { isAllowRuleMatch, isDenyRuleMatch } = require("../lib/settings-allow-match");

const XARGS_BASENAMES = new Set(["xargs", "xargs.exe"]);

// The right-hand side of the pipe, read through separatorLinks.
function rightSegmentOf(hitAt, ctx) {
  const links = (ctx.analysis && ctx.analysis.separatorLinks) || [];
  const link = links.find((l) => l.index === hitAt.index);
  if (!link || link.rightSegment == null) return null;
  const segments = (ctx.ir && ctx.ir.segments) || [];
  return segments[link.rightSegment] || null;
}

function pipesIntoXargs(hit, ctx) {
  if (!hit || hit.literalId !== "pipe" || !hit.at || hit.at.kind !== "separator") return false;
  const seg = rightSegmentOf(hit.at, ctx);
  const effective = seg ? resolveEffectiveSegment(seg) : null;
  if (!effective || typeof effective.cmd0 !== "string" || effective.cmd0 === "") return false;
  return XARGS_BASENAMES.has(path.posix.basename(effective.cmd0.split("\\").join("/")));
}

// permissions.allow globs match the WHOLE command string, so an allow rule covering
// `cd /repo && git commit -m x` would blanket-forgive a push --force appended after
// the commit. Deny rules are anchored (#2280) and no longer catch the whole string
// from a cd-prefixed form, so each &&/;/||/newline segment is checked on its own —
// a hit here withholds the exemption and forces the model to resubmit the chain as
// separate commands.
function anySegmentDenyMatched(ctx) {
  const raw = (ctx && ctx.commandText) || "";
  if (!raw) return false;
  const segs = raw.split(/&&|;|\|\||\n/);
  return segs.some((s) => isDenyRuleMatch(s.trim()));
}

const EXEMPTIONS = Object.freeze([
  Object.freeze({
    id: "xargs-pipe",
    scope: "hit",
    excuses: Object.freeze(["pipe"]),
    applies: pipesIntoXargs,
  }),
  Object.freeze({
    id: "allow-rule-match",
    scope: "command",
    excuses: "*",
    applies: (_hit, ctx) => isAllowRuleMatch(ctx && ctx.commandText) && !anySegmentDenyMatched(ctx),
  }),
]);

const excusesId = (exemption, literalId) =>
  exemption.excuses === "*" ||
  (Array.isArray(exemption.excuses) && exemption.excuses.indexOf(literalId) !== -1);

/**
 * @param {Array} hits detect()'s output
 * @param {{ir: object, analysis: object, commandText: string}} ctx
 * @param {Array} [exemptions] injection point for tests; defaults to EXEMPTIONS
 * @returns {Array} the hits that no exemption forgave
 */
function applyExemptions(hits, ctx, exemptions) {
  const list = Array.isArray(exemptions) ? exemptions : EXEMPTIONS;
  const safeCtx = ctx || {};
  const commandScoped = list.filter((e) => e.scope === "command");
  for (const e of commandScoped) {
    try {
      if (e.applies(null, safeCtx) && e.excuses === "*") return [];
    } catch (_err) { /* an exemption that throws forgives nothing */ }
  }
  const hitScoped = list.filter((e) => e.scope !== "command");
  return (Array.isArray(hits) ? hits : []).filter((h) => {
    for (const e of hitScoped) {
      try {
        if (excusesId(e, h && h.literalId) && e.applies(h, safeCtx)) return false;
      } catch (_err) { /* keep the hit */ }
    }
    return true;
  });
}

module.exports = { EXEMPTIONS, applyExemptions };
