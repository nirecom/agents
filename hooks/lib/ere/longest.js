"use strict";
// POSIX leftmost-longest matching on top of a translated JS RegExp: JS already picks the leftmost
// start, so only the end is widened to the longest one the pattern can reach from that start.
// leftmostLongest(regex, text) -> { index, text } | null

const cache = new WeakMap();

// Each candidate end is tested on the input cut one code point past it, so a lookahead never
// scans the remainder; the translator only emits one-character lookaheads, `$` and lookbehinds.
function variants(regex) {
  let v = cache.get(regex);
  if (!v) {
    v = {
      first: new RegExp(regex.source, "u"),
      atEnd: new RegExp(`(?:${regex.source})$`, "uy"),
      beforeLast: new RegExp(`(?:${regex.source})(?=[\\s\\S]$)`, "uy"),
    };
    cache.set(regex, v);
  }
  return v;
}

function endsAt(v, text, start, end, next) {
  const re = end === text.length ? v.atEnd : v.beforeLast;
  re.lastIndex = start;
  return re.test(end === text.length ? text : text.slice(0, next));
}

function leftmostLongest(regex, text) {
  const v = variants(regex);
  const m = v.first.exec(text);
  if (!m) return null;
  const start = m.index;
  const firstEnd = start + m[0].length;
  const ends = [];
  for (let i = firstEnd; i < text.length;) {
    i += text.codePointAt(i) > 0xffff ? 2 : 1;
    ends.push(i);
  }
  for (let k = ends.length - 1; k >= 0; k -= 1) {
    if (endsAt(v, text, start, ends[k], ends[k + 1])) return { index: start, text: text.slice(start, ends[k]) };
  }
  return { index: start, text: m[0] };
}

module.exports = { leftmostLongest };
