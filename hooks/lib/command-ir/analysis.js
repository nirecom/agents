"use strict";
// hooks/lib/command-ir/analysis.js — the non-enumerable `analysis` side-channel.
//
// parse()'s enumerable shape is pinned byte-for-byte by the equivalence snapshot, so
// the richer reading (heredocs, substitutions, brace groups, separator linkage) rides
// along as a NON-ENUMERABLE, frozen property. analysisOf() degrades to a neutral,
// fully-shaped default so a consumer holding a spread copy (`{...parse(cmd)}`, which
// drops non-enumerable properties) reads `.separatorLinks.length === 0` instead of
// throwing. Ownership: docs/architecture/claude-code/shell-command-parsing.md.

const { scanHeredocs } = require("./heredoc");
const { scanOperators } = require("./scan");
const { linkSeparators } = require("./separator-links");

const NEUTRAL_ANALYSIS = Object.freeze({
  heredocs: Object.freeze([]),
  substitutions: Object.freeze([]),
  groups: Object.freeze([]),
  separatorLinks: Object.freeze([]),
});

function buildAnalysis(cmd, lexText, heredocs, opts) {
  const ops = scanOperators(lexText);
  return Object.freeze({
    heredocs: Object.freeze(heredocs.slice()),
    substitutions: Object.freeze(ops.substitutions),
    groups: Object.freeze(ops.groups),
    separatorLinks: Object.freeze(linkSeparators(lexText, opts)),
  });
}

// Attach `analysis` without perturbing Object.keys(ir) or JSON.stringify(ir).
function attachAnalysis(ir, analysis) {
  Object.defineProperty(ir, "analysis", {
    value: analysis,
    enumerable: false,
    writable: false,
    configurable: true,
  });
  return ir;
}

/**
 * Read the analysis off an IR, degrading to a neutral default.
 * @param {object} ir a parse() result, or any object standing in for one
 */
function analysisOf(ir) {
  const a = ir && ir.analysis;
  if (!a || typeof a !== "object") return NEUTRAL_ANALYSIS;
  return {
    heredocs: Array.isArray(a.heredocs) ? a.heredocs : [],
    substitutions: Array.isArray(a.substitutions) ? a.substitutions : [],
    groups: Array.isArray(a.groups) ? a.groups : [],
    separatorLinks: Array.isArray(a.separatorLinks) ? a.separatorLinks : [],
  };
}

module.exports = { NEUTRAL_ANALYSIS, buildAnalysis, attachAnalysis, analysisOf, scanHeredocs };
