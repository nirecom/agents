"use strict";
// hooks/lib/sentinel-command.js
// #2256 S5-a (CPR-SSOT): one place that decides how a command-tool call decomposes
// into workflow sentinel sub-commands and whether it is a clean emission or a
// chain-guard violation. Shared by workflow-gate.js and workflow-mark.js so both
// judge Bash / runInTerminal / runCommands identically. Two orthogonal axes (CPR-SC):
//   1. `&&` WITHIN one string: order-independent all-or-nothing (a sentinel mixed
//      with a non-sentinel is IMPURE, whichever leads); a standalone strict sentinel
//      is never split (its reason text may contain `&&`).
//   2. runCommands ARRAY order: leading non-sentinel setup allowed; a non-sentinel
//      element AFTER a sentinel rides the approval and rejects the whole call.

const {
  isSentinel,
  isStrictSentinel,
  USER_VERIFIED_RE_DQ,
  CHAIN_BOUNDARY_SENTINEL_DQ_RE,
  CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE,
} = require("./sentinel-patterns");
const { commandListOf } = require("./tool-command-text");

function splitParts(s) {
  return s
    .split(/\s*&&\s*/)
    .map((p) => p.trim())
    .filter(Boolean);
}

// classifyElement -> "SENTINEL" | "IMPURE" | "PLAIN".
//   SENTINEL a lone strict sentinel, or an all-sentinel `&&` chain.
//   IMPURE   a sentinel chained via `&&` with a non-sentinel (rejected either order).
//   PLAIN    no sentinel content, OR a single command that merely resembles one
//            (bare form / incidental substring) — a lone command is never a chain.
// The IMPURE test mirrors workflow-gate.js's historical chain guard exactly: it
// fires only on a real `&&` split (>1 part) whose boundary carries a sentinel echo.
function classifyElement(el) {
  const s = (el || "").trim();
  if (!s) return "PLAIN";
  if (isStrictSentinel(s)) return "SENTINEL";
  const parts = splitParts(s);
  if (parts.length > 0 && parts.every(isSentinel)) return "SENTINEL";
  if (parts.length <= 1) return "PLAIN";
  const boundarySentinel =
    CHAIN_BOUNDARY_SENTINEL_DQ_RE.test(s) ||
    CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE.test(s);
  return boundarySentinel ? "IMPURE" : "PLAIN";
}

// Analyze a whole command-tool call. Returns:
//   sentinelPresent any sentinel content anywhere (SENTINEL or IMPURE element).
//   clean           processable emission: >=1 SENTINEL, no IMPURE, no PLAIN after a SENTINEL.
//   sentinelParts   ordered sentinel sub-commands to dispatch (only when clean).
//   uvHit           a <<WORKFLOW_USER_VERIFIED>> strict sentinel appears.
function analyzeSentinelCommand(toolName, toolInput) {
  const elements = commandListOf(toolName, toolInput)
    .map((e) => e.trim())
    .filter(Boolean);
  const cls = elements.map(classifyElement);

  const hasImpure = cls.some((c) => c === "IMPURE");
  const sentinelIdxs = [];
  cls.forEach((c, i) => {
    if (c === "SENTINEL") sentinelIdxs.push(i);
  });
  const sentinelPresent = hasImpure || sentinelIdxs.length > 0;

  const firstSentinel = sentinelIdxs.length ? sentinelIdxs[0] : -1;
  const plainAfterSentinel =
    firstSentinel >= 0 && cls.slice(firstSentinel + 1).some((c) => c === "PLAIN");
  const clean =
    sentinelPresent && !hasImpure && sentinelIdxs.length > 0 && !plainAfterSentinel;

  const sentinelParts = [];
  if (clean) {
    for (let i = 0; i < elements.length; i++) {
      if (cls[i] !== "SENTINEL") continue;
      const el = elements[i];
      if (isStrictSentinel(el)) {
        sentinelParts.push(el);
      } else {
        for (const p of splitParts(el)) if (isSentinel(p)) sentinelParts.push(p);
      }
    }
  }

  const uvHit = elements.some((el) => {
    if (isStrictSentinel(el)) return USER_VERIFIED_RE_DQ.test(el);
    return splitParts(el).some((p) => USER_VERIFIED_RE_DQ.test(p));
  });

  return {
    elements,
    sentinelPresent,
    clean,
    hasImpure,
    plainAfterSentinel,
    sentinelParts,
    uvHit,
  };
}

module.exports = { analyzeSentinelCommand, classifyElement };
