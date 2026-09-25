#!/usr/bin/env node
// tests/fix-1780-round12-parser-unit-tables/mutate.js
// MUTATION EVIDENCE helper (skills/_shared/test-design/parser-regex-tests.md).
//
// A table row that passes proves nothing on its own: it may be passing because
// the regex under test is exercised, or because some unrelated code path happens
// to produce the same answer. The evidence that a row is actually keyed on its
// regex is that the row FLIPS when that regex is neutered.
//
// bin/mutation-probe.sh performs the same neutering, but only for the
// single-line `const NAME = /regex/;` form (it says so in its own header). Every
// interesting constant in interpreter-scan.js / argv-scan.js / assignment-text.js
// is built with `new RegExp(String.raw\`…\`)` spanning several lines, so this
// helper does the paren-balanced version: find `const NAME =`, scan forward
// balancing (), [], {} and skipping strings/templates/comments, and replace the
// whole initializer up to its terminating `;` with the never-matching `/(?!)/`.
//
// Usage: node mutate.js <file> <CONST_NAME>
//   Rewrites <file> IN PLACE. Callers must point it at a COPY of hooks/ — this
//   script must never be aimed at the real tree, and the suite that drives it
//   builds a throwaway copy first.
// Exit 0 on success (prints "ok"), 1 when the constant was not found.
"use strict";

const fs = require("fs");

const file = process.argv[2];
const name = process.argv[3];
const src = fs.readFileSync(file, "utf8");

const decl = new RegExp(String.raw`(^|\n)(\s*)const\s+` + name + String.raw`\s*=\s*`);
const m = decl.exec(src);
if (!m) {
  process.stdout.write("not-found");
  process.exit(1);
}

const start = m.index + m[0].length;
let i = start;
let depth = 0;
let end = -1;
// A bare regex literal initializer (`const NAME = /[*?[]/;`) has to be consumed
// as a unit BEFORE the bracket balancer runs: `/[*?[]/` opens two `[` and closes
// one, so a balancer that walked into it would never return to depth 0 and the
// mutation would silently no-op — the failure mode that makes a mutation probe
// report "covered" for a constant it never touched.
if (src[start] === "/") {
  let k = start + 1;
  let inClass = false;
  while (k < src.length) {
    const ch = src[k];
    if (ch === "\\") { k += 2; continue; }
    if (ch === "[") { inClass = true; k++; continue; }
    if (ch === "]") { inClass = false; k++; continue; }
    if (ch === "/" && !inClass) { k++; break; }
    if (ch === "\n") break;
    k++;
  }
  while (k < src.length && /[a-z]/.test(src[k])) k++;   // flags
  if (src[k] === ";") {
    fs.writeFileSync(file, src.slice(0, start) + "/(?!)/" + src.slice(k), "utf8");
    process.stdout.write("ok");
    process.exit(0);
  }
}
while (i < src.length) {
  const c = src[i];
  // Skip over string / template / regex-literal-ish spans so a `;` or a bracket
  // inside a pattern cannot be mistaken for structure.
  if (c === '"' || c === "'" || c === "`") {
    const q = c;
    i++;
    while (i < src.length) {
      if (src[i] === "\\") { i += 2; continue; }
      if (src[i] === q) { i++; break; }
      i++;
    }
    continue;
  }
  if (c === "/" && src[i + 1] === "/") {
    while (i < src.length && src[i] !== "\n") i++;
    continue;
  }
  if (c === "/" && src[i + 1] === "*") {
    i = src.indexOf("*/", i + 2);
    if (i === -1) break;
    i += 2;
    continue;
  }
  if (c === "(" || c === "[" || c === "{") { depth++; i++; continue; }
  if (c === ")" || c === "]" || c === "}") { depth--; i++; continue; }
  if (c === ";" && depth === 0) { end = i; break; }
  i++;
}
if (end === -1) {
  process.stdout.write("no-terminator");
  process.exit(1);
}

fs.writeFileSync(file, src.slice(0, start) + "/(?!)/" + src.slice(end), "utf8");
process.stdout.write("ok");
