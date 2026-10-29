"use strict";
// POSIX bracket classes as JS class bodies (u flag), matching what bash's regcomp and glob
// matching accept under the hook's C.UTF-8 locale; digit and xdigit stay ASCII as there.

const GRAPH = "\\p{L}\\p{M}\\p{N}\\p{P}\\p{S}";

const POSIX_CLASSES = Object.freeze({
  alpha: "\\p{Alphabetic}",
  digit: "0-9",
  alnum: "\\p{Alphabetic}\\p{Nd}",
  upper: "\\p{Uppercase}",
  lower: "\\p{Lowercase}",
  space: "\\p{White_Space}",
  blank: "\\t\\p{Zs}",
  punct: "\\p{P}\\p{S}",
  xdigit: "0-9A-Fa-f",
  cntrl: "\\p{Cc}",
  graph: GRAPH,
  print: `${GRAPH}\\p{Zs}`,
});

// The GNU word characters ([_[:alnum:]]) shared by \w \W \< \> \b \B.
const WORD_CHARS = `_${POSIX_CLASSES.alnum}`;
const WORD_CLASS = `[${WORD_CHARS}]`;
const NON_WORD_CLASS = `[^${WORD_CHARS}]`;

// cpEscape(cp) -> a \u{...} escape usable inside and outside a u-flag class.
const cpEscape = (cp) => `\\u{${cp.toString(16)}}`;

module.exports = { POSIX_CLASSES, WORD_CLASS, NON_WORD_CLASS, cpEscape };
