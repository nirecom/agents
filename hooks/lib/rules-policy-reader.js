"use strict";

// Reads hooks/lib/rules-injection-policy.js AS DATA — never require()s it. WHY: rules-injection-policy.js is a
// contributor-editable declaration file. Every consumer of it (the pre-commit static checker, the InstructionsLoaded
// audit hook) runs on a branch that a pull request controls, so `require()`-ing the policy would execute whatever that
// PR put in its module body, before review, with the reviewer's ambient privileges. Merely checking out a branch and
// starting a session must never do that.
//
// So the policy is read as DATA: the source TEXT is scanned for the constant declarations the policy names — six of
// them today (ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL,
// MINIMIZED_UNCONDITIONAL, MINIMIZED_MAX_BYTES) — and nothing else is evaluated, which is why every declaration must
// stay a plain one-line literal.

// Declaration contract: each name must open a `const`/`let`/`var` statement at the start of its
// line; an occurrence anywhere else (a comment, say) is not read as a declaration.

// This module is agents-owned code, not contributor-editable data, so consumers require() it normally — and it is the
// only place allowed to DERIVE one declaration from another, so the policy never repeats a fact it already states.

const fs = require("fs");

function unescapeLiteral(raw) {
  return raw.replace(/\\(.)/g, "$1");
}

// Every reader below anchors on a REAL declaration: the constant name must open a `const`/`let`/
// `var` statement at the start of a line. Unanchored, the first textual occurrence anywhere wins —
// so a commented-out `// const MINIMIZED_MAX_BYTES = "999999"` above the live declaration would
// silently become the value every consumer reads. Same anchor as READERS_DECL_RE / MINIMIZED_DECL_RE
// in bin/lib/check-on-demand-rules.js.
function declRe(name, tail) {
  return new RegExp("^[ \\t]*(?:const|let|var)[ \\t]+" + name + "[ \\t]*=[ \\t]*" + tail, "m");
}

function readStringConst(src, name) {
  const m = declRe(name, "([\"'])((?:\\\\.|(?!\\1)[^\\\\])*)\\1").exec(src);
  return m ? unescapeLiteral(m[2]) : null;
}

function readStringArrayConst(src, name) {
  const m = declRe(name, "\\[([\\s\\S]*?)\\]").exec(src);
  if (!m) return null;
  const out = [];
  const lit = /(["'])((?:\\.|(?!\1)[^\\])*)\1/g;
  let hit;
  while ((hit = lit.exec(m[1])) !== null) out.push(unescapeLiteral(hit[2]));
  return out;
}

// Decodes the "<key>|<v1>,<v2>" element shape a multi-field declaration must use.
// Split ONCE, on the first `|`: a later `|` belongs to the value half. An element
// with NO separator is MALFORMED — {values: null}, distinct from {values: []} for a
// separator followed by nothing — so a caller can name a row that declared no values
// instead of silently dropping it (same spirit as "present but unparseable" below).
function readPairArrayConst(src, name) {
  const raw = readStringArrayConst(src, name);
  if (raw === null) return null;
  return raw.map((element) => {
    const cut = element.indexOf("|");
    if (cut === -1) return { key: element, values: null };
    const tail = element.slice(cut + 1);
    return { key: element.slice(0, cut), values: tail === "" ? [] : tail.split(",") };
  });
}

// The literal is rebuilt with `new RegExp(source, flags)`, never eval'd. The /g
// flag is dropped: a stateful .test() would answer differently on alternate
// calls and mark the same file annotated on one pass and bare on the next.
// Anchored like the two above (CPR-ORTH): a commented-out marker regex must not
// out-rank the live declaration either.
function readRegexConst(src, name) {
  const m = declRe(name, "/((?:\\\\.|\\[(?:\\\\.|[^\\]])*\\]|[^\\\\/\\n])+)/([gimsuy]*)").exec(src);
  if (!m) return null;
  try {
    return new RegExp(m[1], m[2].split("g").join(""));
  } catch (_) {
    return null;
  }
}

// Throws when the policy file cannot be read; a caller that must not die on a
// missing policy is responsible for its own try/catch. A declaration that is
// present but not extractable yields null (scalars) or [] (arrays) so callers
// can tell "unreadable file" from "unparseable declaration".
function loadPolicyAsData(policyPath) {
  const src = fs.readFileSync(policyPath, "utf8");
  // ON_DEMAND_FILES is DERIVED, not declared: it is the key column of ON_DEMAND_READERS,
  // so existing consumers keep their flat list while the rule name lives in one place.
  const readers = readPairArrayConst(src, "ON_DEMAND_READERS") || [];
  return {
    ON_DEMAND_TOKEN: readStringConst(src, "ON_DEMAND_TOKEN"),
    ON_DEMAND_MARKER_RE: readRegexConst(src, "ON_DEMAND_MARKER_RE"),
    ON_DEMAND_READERS: readers,
    ON_DEMAND_FILES: readers.map((row) => row.key),
    EXPECTED_UNCONDITIONAL: readStringArrayConst(src, "EXPECTED_UNCONDITIONAL") || [],
    // null (not []) when the declaration is absent entirely: a policy that never
    // declares the minimized class is a different state from one that declares it empty.
    MINIMIZED_UNCONDITIONAL: readPairArrayConst(src, "MINIMIZED_UNCONDITIONAL"),
    MINIMIZED_MAX_BYTES: readStringConst(src, "MINIMIZED_MAX_BYTES"),
  };
}

module.exports = {
  unescapeLiteral,
  readStringConst,
  readStringArrayConst,
  readPairArrayConst,
  readRegexConst,
  loadPolicyAsData,
};
