"use strict";
// POSIX ERE (as bash `[[ s =~ re ]]` compiles it under C.UTF-8) -> JS RegExp with the u flag.
// translateEre(ere) -> {status:"ok",regex} | {status:"invalid",reason} | {status:"untranslatable",reason}
// "invalid" is an ERE bash rejects (its =~ then never matches); "untranslatable" is a valid ERE
// with no faithful JS form, which a caller must treat as fail-closed.

const { POSIX_CLASSES, WORD_CLASS, NON_WORD_CLASS, cpEscape } = require("./posix-classes");

const RE_DUP_MAX = 255;
const NOT_WORD = `(?!${WORD_CLASS})`;
const IS_WORD = `(?=${WORD_CLASS})`;
const AFTER_WORD = `(?<=${WORD_CLASS})`;
const AFTER_NON_WORD = `(?<!${WORD_CLASS})`;
const ASSERTIONS = {
  "<": `${AFTER_NON_WORD}${IS_WORD}`,
  ">": `${AFTER_WORD}${NOT_WORD}`,
  b: `(?:${AFTER_NON_WORD}${IS_WORD}|${AFTER_WORD}${NOT_WORD})`,
  B: `(?:${AFTER_WORD}${IS_WORD}|${AFTER_NON_WORD}${NOT_WORD})`,
  "`": "(?<![\\s\\S])",
  "'": "(?![\\s\\S])",
};
const SHORTHANDS = {
  w: WORD_CLASS,
  W: NON_WORD_CLASS,
  s: `[${POSIX_CLASSES.space}]`,
  S: `[^${POSIX_CLASSES.space}]`,
};

class Stop extends Error {
  constructor(status, reason) {
    super(reason);
    this.status = status;
  }
}
const invalid = (reason) => new Stop("invalid", reason);

const isAsciiAlnum = (c) => /^[A-Za-z0-9]$/.test(c);
const literal = (c) => (isAsciiAlnum(c) ? c : cpEscape(c.codePointAt(0)));

// parseBracket(cs, i) -> { src, next }; i is the index just past "[".
function parseBracket(cs, i) {
  let pos = i;
  let negate = false;
  if (cs[pos] === "^") {
    negate = true;
    pos += 1;
  }
  const items = [];
  if (cs[pos] === "]" || cs[pos] === "-") {
    items.push(literal(cs[pos]));
    pos += 1;
  }
  const symbol = () => {
    if (cs[pos] === "[" && (cs[pos + 1] === "." || cs[pos + 1] === "=")) {
      const kind = cs[pos + 1];
      const close = findClose(cs, pos + 2, kind);
      if (close < 0) throw invalid("unterminated bracket symbol");
      throw new Stop("untranslatable", `bracket ${kind === "." ? "collating symbol" : "equivalence class"} [${kind}${cs.slice(pos + 2, close).join("")}${kind}] has no JS form`);
    }
    const c = cs[pos];
    pos += 1;
    return c;
  };
  for (;;) {
    if (pos >= cs.length) throw invalid("unterminated bracket expression");
    if (cs[pos] === "]") break;
    if (cs[pos] === "-") {
      if (cs[pos + 1] === "]") {
        items.push(literal("-"));
        pos += 1;
        continue;
      }
      throw invalid("range start missing");
    }
    if (cs[pos] === "[" && cs[pos + 1] === ":") {
      const close = findClose(cs, pos + 2, ":");
      if (close < 0) throw invalid("unterminated character class");
      const name = cs.slice(pos + 2, close).join("");
      if (!Object.prototype.hasOwnProperty.call(POSIX_CLASSES, name)) throw invalid(`unknown character class ${name}`);
      items.push(POSIX_CLASSES[name]);
      pos = close + 2;
      continue;
    }
    const start = symbol();
    if (cs[pos] === "-" && pos + 1 < cs.length && cs[pos + 1] !== "]") {
      pos += 1;
      const end = cs[pos] === "-" ? (pos += 1, "-") : symbol();
      if (end.codePointAt(0) < start.codePointAt(0)) throw invalid("range end before start");
      items.push(`${literal(start)}-${literal(end)}`);
      continue;
    }
    items.push(literal(start));
  }
  return { src: `[${negate ? "^" : ""}${items.join("")}]`, next: pos + 1 };
}

// Index of the "<kind>]" that closes a bracket symbol opened at <from>, or -1.
function findClose(cs, from, kind) {
  for (let k = from; k + 1 < cs.length; k += 1) {
    if (cs[k] === kind && cs[k + 1] === "]") return k;
  }
  return -1;
}

// parseBrace(cs, i) -> { src, next }; i is the index just past "{".
function parseBrace(cs, i) {
  let pos = i;
  const digits = () => {
    let s = "";
    while (pos < cs.length && /^[0-9]$/.test(cs[pos])) s += cs[pos++];
    return s;
  };
  const lo = digits();
  if (lo === "") throw invalid("repetition count missing");
  let hi = lo;
  if (cs[pos] === ",") {
    pos += 1;
    hi = digits();
  }
  if (cs[pos] !== "}") throw invalid("unterminated repetition");
  const min = Number(lo);
  const max = hi === "" ? null : Number(hi);
  if (min > RE_DUP_MAX || (max !== null && (max > RE_DUP_MAX || max < min))) throw invalid("bad repetition count");
  const src = max === null ? `{${min},}` : max === min && hi === lo ? `{${min}}` : `{${min},${max}}`;
  return { src, next: pos + 1 };
}

function parse(ere) {
  const cs = Array.from(ere);
  if (cs.length === 0) throw invalid("empty pattern");
  let out = "";
  let groups = 0;
  const closed = new Set();
  const frames = [{ alts: 1, empty: true, num: 0 }];
  let quantifiable = false;
  const top = () => frames[frames.length - 1];
  const atom = (src) => {
    out += src;
    top().empty = false;
    quantifiable = true;
  };
  const anchor = (src) => {
    out += src;
    top().empty = false;
    quantifiable = false;
  };
  const endAlt = () => {
    if (top().empty && top().alts > 1) throw invalid("empty alternative");
  };
  for (let i = 0; i < cs.length;) {
    const c = cs[i];
    if (c === "(") {
      groups += 1;
      frames.push({ alts: 1, empty: true, num: groups });
      out += "(";
      quantifiable = false;
      i += 1;
    } else if (c === ")") {
      if (frames.length === 1) throw invalid("unmatched )");
      endAlt();
      const f = frames.pop();
      closed.add(f.num);
      atom(")");
      i += 1;
    } else if (c === "|") {
      if (top().empty) throw invalid("empty alternative");
      top().alts += 1;
      top().empty = true;
      out += "|";
      quantifiable = false;
      i += 1;
    } else if (c === "*" || c === "+" || c === "?") {
      if (!quantifiable) throw invalid(`repetition operator ${c} without an operand`);
      out += c;
      quantifiable = false;
      i += 1;
    } else if (c === "{") {
      if (!quantifiable) throw invalid("repetition without an operand");
      const b = parseBrace(cs, i + 1);
      out += b.src;
      quantifiable = false;
      i = b.next;
    } else if (c === "^" || c === "$") {
      anchor(c);
      i += 1;
    } else if (c === ".") {
      atom("[\\s\\S]");
      i += 1;
    } else if (c === "[") {
      const b = parseBracket(cs, i + 1);
      atom(b.src);
      i = b.next;
    } else if (c === "\\") {
      const e = cs[i + 1];
      if (e === undefined) throw invalid("trailing backslash");
      if (Object.prototype.hasOwnProperty.call(ASSERTIONS, e)) anchor(ASSERTIONS[e]);
      else if (Object.prototype.hasOwnProperty.call(SHORTHANDS, e)) atom(SHORTHANDS[e]);
      else if (/^[1-9]$/.test(e)) {
        if (!closed.has(Number(e))) throw invalid(`back reference \\${e} to no closed group`);
        atom(`(?:\\${e})`);
      } else if (isAsciiAlnum(e)) throw invalid(`unknown escape \\${e}`);
      else atom(literal(e));
      i += 2;
    } else {
      atom(literal(c));
      i += 1;
    }
  }
  if (frames.length > 1) throw invalid("unmatched (");
  endAlt();
  if (top().empty) throw invalid("empty pattern");
  return out;
}

function translateEre(ere) {
  let src;
  try {
    src = parse(String(ere));
  } catch (e) {
    if (e instanceof Stop) return { status: e.status, reason: e.message };
    throw e;
  }
  try {
    return { status: "ok", regex: new RegExp(src, "u") };
  } catch (e) {
    return { status: "untranslatable", reason: `no JS form: ${e.message}` };
  }
}

module.exports = { translateEre };
