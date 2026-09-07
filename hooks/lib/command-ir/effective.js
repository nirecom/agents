"use strict";
// hooks/lib/command-ir/effective.js — resolve the EXECUTED command inside a segment.
//
// Penetrates env-prefix assignments (`FOO=1 head` -> head) and control-structure
// keywords. Condition headers (if/elif/while/until) and body keywords (do/then/else)
// are stripped because what follows them runs as a real command; non-executable
// headers (for/select/case) and terminators (done/fi/esac) resolve to null.

const { syncRaw } = require("./segments");

const CONTROL_COND_HEADERS = new Set(["if", "elif", "while", "until"]);
const CONTROL_BODY_KEYWORDS = new Set(["do", "then", "else"]);
const CONTROL_NONEXEC_HEADERS = new Set(["for", "select", "case"]);
const CONTROL_TERMINATORS = new Set(["done", "fi", "esac"]);
const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// Returns null when every token is an assignment (no real command follows).
function stripEnvPrefix(seg) {
  if (!seg || seg.cmd0 == null) return null;
  if (!ASSIGN_RE.test(seg.cmd0)) return seg;
  if (!Array.isArray(seg.argv)) return null;
  const idx = seg.argv.findIndex((a) => !ASSIGN_RE.test(a));
  if (idx === -1) return null;
  return { ...seg, cmd0: seg.argv[idx], argv: seg.argv.slice(idx + 1), ...syncRaw(seg, idx + 1) };
}

/**
 * @param {object} segmentIR a SegmentIR from parse()
 * @returns {object|null} effective SegmentIR, or null for headers/terminators
 */
function resolveEffectiveSegment(segmentIR) {
  if (!segmentIR || segmentIR.cmd0 == null) return null;
  const cmd0 = segmentIR.cmd0;
  if (cmd0 === "") return null;

  if (CONTROL_NONEXEC_HEADERS.has(cmd0) || CONTROL_TERMINATORS.has(cmd0)) return null;

  if (CONTROL_COND_HEADERS.has(cmd0) || CONTROL_BODY_KEYWORDS.has(cmd0)) {
    if (!Array.isArray(segmentIR.argv) || segmentIR.argv.length === 0) return null;
    const effective = {
      ...segmentIR,
      cmd0: segmentIR.argv[0],
      argv: segmentIR.argv.slice(1),
      ...syncRaw(segmentIR, 1),
    };
    return stripEnvPrefix(effective);
  }

  return stripEnvPrefix(segmentIR);
}

module.exports = { resolveEffectiveSegment, stripEnvPrefix, ASSIGN_RE };
