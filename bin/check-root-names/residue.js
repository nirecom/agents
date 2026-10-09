"use strict";

// Residue check (#2561): no retired root name is left in tracked content or paths.
// The retired spellings live in one place only — between the two marker lines of the
// residue test — and are read from there, so this module carries none of them.

const { escapeRe } = require("./line-scan");

const BEGIN = "# retired-names:begin";
const END = "# retired-names:end";
const ENTRY_RE = /^# (env|name|stem|keep) (\S.*)$/;
const WORD_RE = /[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+/g;
const GAP_RE = /^[_\-\s]*$/;

class ListError extends Error {}

// parseList(text, listRel) → matcher data; throws ListError when the section is unreadable.
function parseList(text, listRel) {
  const lines = text.split(/\r?\n/);
  const begin = lines.indexOf(BEGIN);
  const end = lines.indexOf(END);
  if (begin < 0 || end < begin) throw new ListError("the retired-name list has no complete marked section");
  const list = { exact: [], stems: [], keep: [], listRel };
  for (const line of lines.slice(begin + 1, end)) {
    const m = ENTRY_RE.exec(line);
    if (!m) continue;
    const spelling = m[2].trim();
    if (m[1] === "keep") list.keep.push(spelling);
    else if (m[1] === "stem") list.stems.push({ spelling, words: spelling.toLowerCase().split(/\s+/) });
    else {
      // A hyphenated name is one word: a longer hyphenated label is another name.
      const id = spelling.includes("-") ? "[A-Za-z0-9_-]" : "[A-Za-z0-9_]";
      list.exact.push({ kind: m[1], spelling, re: new RegExp(`(?<!${id})${escapeRe(spelling)}(?!${id})`) });
    }
  }
  if (list.exact.length + list.stems.length === 0) throw new ListError("the retired-name list has no entry");
  list.keep.sort((a, b) => b.length - a.length);
  list.quick = quickRe(list);
  return list;
}

// A cheap first pass: a line that matches none of these fragments cannot hold a hit.
function quickRe(list) {
  const parts = list.exact.map((e) => escapeRe(e.spelling));
  for (const s of list.stems) parts.push(s.words.map(escapeRe).join("[_\\-\\s]*"));
  return new RegExp(parts.join("|"), "i");
}

function stemHit(text, stem) {
  const words = [...text.matchAll(WORD_RE)];
  const n = stem.words.length;
  for (let i = 0; i + n <= words.length; i++) {
    let ok = true;
    for (let k = 0; k < n && ok; k++) {
      const w = words[i + k];
      if (w[0].toLowerCase() !== stem.words[k]) ok = false;
      else if (k > 0) {
        const prev = words[i + k - 1];
        ok = GAP_RE.test(text.slice(prev.index + prev[0].length, w.index));
      }
    }
    if (ok) return true;
  }
  return false;
}

// hitIn(text, list) → "<kind> <spelling>" of the first retired entry in the text, or null.
function hitIn(text, list) {
  if (!list.quick.test(text)) return null;
  let rest = text;
  for (const keep of list.keep) {
    if (rest.includes(keep)) rest = rest.split(keep).join(" ".repeat(keep.length));
  }
  for (const e of list.exact) if (e.re.test(rest)) return `${e.kind} "${e.spelling}"`;
  for (const s of list.stems) if (stemHit(rest, s)) return `stem "${s.spelling}"`;
  return null;
}

// History documents and the list's own file are the only places an old name may stay.
function isExempt(rel, list) {
  return rel.startsWith("docs/history") || rel === "CHANGELOG.md" || rel.startsWith("changelog/") || rel === list.listRel;
}

function check(ctx) {
  const list = ctx.list();
  const out = [];
  for (const file of ctx.files) {
    if (isExempt(file.rel, list)) continue;
    const pathHit = hitIn(file.rel, list);
    if (pathHit) out.push(`${file.rel}: residue: the path carries the retired ${pathHit}`);
    if (file.text === null || !list.quick.test(file.text)) continue;
    const lines = file.text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const hit = hitIn(lines[i], list);
      if (hit) out.push(`${file.rel}:${i + 1}: residue: retired ${hit}`);
    }
  }
  return out;
}

module.exports = { check, parseList, ListError };
