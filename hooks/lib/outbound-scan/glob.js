"use strict";
// The allowlist `file:value` file side, matched the way bash `[[ file == glob ]]` does: the whole
// path, `*` and `?` crossing "/", bracket expressions with POSIX classes, backslash escapes, and
// the extglob forms @( ) ?( ) *( ) +( ) !( ) that bash enables inside [[ ]].
// globMatch(glob, subject) -> boolean

const { POSIX_CLASSES, cpEscape } = require("../ere/posix-classes");

const EXT_OPS = new Set(["@", "?", "*", "+", "!"]);

// parseBracket(cs, i) -> { token, next } | null when no closing "]" makes "[" a literal.
function parseBracket(cs, i) {
  let pos = i;
  let negate = false;
  if (cs[pos] === "!" || cs[pos] === "^") {
    negate = true;
    pos += 1;
  }
  const items = [];
  let first = true;
  const one = () => {
    if (cs[pos] === "\\" && pos + 1 < cs.length) pos += 1;
    return cs[pos++];
  };
  while (pos < cs.length) {
    if (cs[pos] === "]" && !first) {
      const body = items.join("");
      return { token: { type: "class", re: new RegExp(`^[${negate ? "^" : ""}${body}]$`, "u") }, next: pos + 1 };
    }
    first = false;
    if (cs[pos] === "[" && cs[pos + 1] === ":") {
      const close = cs.indexOf(":", pos + 2);
      if (close > 0 && cs[close + 1] === "]") {
        const name = cs.slice(pos + 2, close).join("");
        if (!Object.prototype.hasOwnProperty.call(POSIX_CLASSES, name)) return null;
        items.push(POSIX_CLASSES[name]);
        pos = close + 2;
        continue;
      }
    }
    const lo = one();
    if (cs[pos] === "-" && pos + 1 < cs.length && cs[pos + 1] !== "]") {
      pos += 1;
      const hi = one();
      if (hi.codePointAt(0) >= lo.codePointAt(0)) items.push(`${cpEscape(lo.codePointAt(0))}-${cpEscape(hi.codePointAt(0))}`);
      continue;
    }
    items.push(cpEscape(lo.codePointAt(0)));
  }
  return null;
}

// parseAlts(cs, i) -> { alts: [tokens], next } for an extglob body starting just past "(".
function parseAlts(cs, i) {
  const alts = [];
  let depth = 0;
  let start = i;
  for (let k = i; k < cs.length; k += 1) {
    const c = cs[k];
    if (c === "\\") {
      k += 1;
    } else if (c === "(") {
      depth += 1;
    } else if (c === ")" && depth > 0) {
      depth -= 1;
    } else if (c === "|" && depth === 0) {
      alts.push(parse(cs.slice(start, k)));
      start = k + 1;
    } else if (c === ")") {
      alts.push(parse(cs.slice(start, k)));
      return { alts, next: k + 1 };
    }
  }
  return null;
}

function parse(cs) {
  const tokens = [];
  for (let i = 0; i < cs.length;) {
    const c = cs[i];
    if (EXT_OPS.has(c) && cs[i + 1] === "(") {
      const ext = parseAlts(cs, i + 2);
      if (ext) {
        tokens.push({ type: "ext", op: c, alts: ext.alts });
        i = ext.next;
        continue;
      }
    }
    if (c === "*") {
      tokens.push({ type: "star" });
      i += 1;
    } else if (c === "?") {
      tokens.push({ type: "any" });
      i += 1;
    } else if (c === "[") {
      const b = parseBracket(cs, i + 1);
      tokens.push(b ? b.token : { type: "lit", ch: "[" });
      i = b ? b.next : i + 1;
    } else if (c === "\\" && i + 1 < cs.length) {
      tokens.push({ type: "lit", ch: cs[i + 1] });
      i += 2;
    } else {
      tokens.push({ type: "lit", ch: c });
      i += 1;
    }
  }
  return tokens;
}

// Whole-match of tokens[ti..] against s[from..to).
function matchFrom(tokens, ti, s, from, to) {
  if (ti === tokens.length) return from === to;
  const t = tokens[ti];
  if (t.type === "lit") return from < to && s[from] === t.ch && matchFrom(tokens, ti + 1, s, from + 1, to);
  if (t.type === "any") return from < to && matchFrom(tokens, ti + 1, s, from + 1, to);
  if (t.type === "class") return from < to && t.re.test(s[from]) && matchFrom(tokens, ti + 1, s, from + 1, to);
  if (t.type === "star") {
    for (let e = to; e >= from; e -= 1) if (matchFrom(tokens, ti + 1, s, e, to)) return true;
    return false;
  }
  return matchExt(tokens, ti, s, from, to);
}

const anyAlt = (alts, s, from, to) => alts.some((a) => matchFrom(a, 0, s, from, to));

// One or more consecutive alt matches covering s[from..to).
function repeats(alts, s, from, to) {
  if (anyAlt(alts, s, from, to)) return true;
  for (let mid = from + 1; mid < to; mid += 1) {
    if (anyAlt(alts, s, from, mid) && repeats(alts, s, mid, to)) return true;
  }
  return false;
}

function matchExt(tokens, ti, s, from, to) {
  const t = tokens[ti];
  for (let e = from; e <= to; e += 1) {
    let ok;
    if (t.op === "@") ok = anyAlt(t.alts, s, from, e);
    else if (t.op === "?") ok = e === from || anyAlt(t.alts, s, from, e);
    else if (t.op === "*") ok = e === from || repeats(t.alts, s, from, e);
    else if (t.op === "+") ok = repeats(t.alts, s, from, e);
    else ok = !anyAlt(t.alts, s, from, e);
    if (ok && matchFrom(tokens, ti + 1, s, e, to)) return true;
  }
  return false;
}

function globMatch(glob, subject) {
  const s = Array.from(String(subject));
  return matchFrom(parse(Array.from(String(glob))), 0, s, 0, s.length);
}

module.exports = { globMatch };
