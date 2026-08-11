"use strict";

// Reads hooks/lib/rules-injection-policy.js AS DATA — never require()s it.
//
// WHY THIS MODULE EXISTS
// ----------------------
// rules-injection-policy.js is a contributor-editable declaration file. Every
// consumer of it (the pre-commit static checker, the InstructionsLoaded audit
// hook) runs on a branch that a pull request controls, so `require()`-ing the
// policy would execute whatever that PR put in its module body, before review,
// with the reviewer's ambient privileges. Merely checking out a branch and
// starting a session must never do that.
//
// So the policy is read as DATA: the source TEXT is scanned for the four
// constant declarations and nothing else is evaluated. That is also why the
// policy file is required to keep every declaration a plain one-line literal.
//
// This module itself is agents-owned code, not contributor-editable declaration
// data, so consumers require() it normally.

const fs = require("fs");

function unescapeLiteral(raw) {
  return raw.replace(/\\(.)/g, "$1");
}

function readStringConst(src, name) {
  const re = new RegExp(name + "\\s*=\\s*([\"'])((?:\\\\.|(?!\\1)[^\\\\])*)\\1");
  const m = re.exec(src);
  return m ? unescapeLiteral(m[2]) : null;
}

function readStringArrayConst(src, name) {
  const m = new RegExp(name + "\\s*=\\s*\\[([\\s\\S]*?)\\]").exec(src);
  if (!m) return null;
  const out = [];
  const lit = /(["'])((?:\\.|(?!\1)[^\\])*)\1/g;
  let hit;
  while ((hit = lit.exec(m[1])) !== null) out.push(unescapeLiteral(hit[2]));
  return out;
}

// The literal is rebuilt with `new RegExp(source, flags)`, never eval'd. The /g
// flag is dropped: a stateful .test() would answer differently on alternate
// calls and mark the same file annotated on one pass and bare on the next.
function readRegexConst(src, name) {
  const re = new RegExp(
    name + "\\s*=\\s*/((?:\\\\.|\\[(?:\\\\.|[^\\]])*\\]|[^\\\\/\\n])+)/([gimsuy]*)"
  );
  const m = re.exec(src);
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
  return {
    ON_DEMAND_TOKEN: readStringConst(src, "ON_DEMAND_TOKEN"),
    ON_DEMAND_MARKER_RE: readRegexConst(src, "ON_DEMAND_MARKER_RE"),
    ON_DEMAND_FILES: readStringArrayConst(src, "ON_DEMAND_FILES") || [],
    EXPECTED_UNCONDITIONAL: readStringArrayConst(src, "EXPECTED_UNCONDITIONAL") || [],
  };
}

module.exports = {
  unescapeLiteral,
  readStringConst,
  readStringArrayConst,
  readRegexConst,
  loadPolicyAsData,
};
