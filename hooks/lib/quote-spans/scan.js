"use strict";
// hooks/lib/quote-spans/scan.js
// Frame-stack shell quote/substitution scanner (#1569).
//
// Single source of truth for "where do the quoted and substitution regions of
// this command string start and end". Replaces four ad-hoc walkers that each
// guessed at the grammar (depth-counted `$()`, regex-paired `'...'`, DQ-only
// newline folding, unclosed-quote detection).
//
// The scan is a single left-to-right pass over a stack of frames. Each opened
// frame becomes a Span; the span list is FLAT and in start order, with nesting
// expressed through `parent` / `depth`.
//
// Fail-closed contract: an unbalanced input yields { ok:false } with the kinds
// of the frames still open at EOF, and every consumer resolves that to the
// danger side rather than guessing at the intended structure.

// Kinds whose body is a quoted literal (quoteContextAt reports these).
const QUOTE_KINDS = ["dq", "sq", "ansic"];
// Kinds whose body is command text (quoteContextAt reports "unquoted" inside).
const EXPANDING_KINDS = ["cmdsubst", "backtick", "subshell", "arith"];

// `expands` = does the shell perform expansions inside this frame's body.
const EXPANDS = {
  dq: true,
  sq: false,
  ansic: false,
  cmdsubst: true,
  backtick: true,
  subshell: true,
  arith: true,
};

const CACHE_LIMIT = 8;
const cache = new Map();

// Hard ceiling on simultaneously-open frames. The renderers in transform.js walk
// the span tree recursively (one JS stack frame per level), so an unbounded
// nesting depth turns a plain Bash string into a RangeError inside a PreToolUse
// hook — and a hook that dies emits no verdict, which is fail-OPEN. Capping here,
// at the single place every consumer goes through, converts that into the normal
// fail-closed `ok:false` result. 2048 clears the deepest nesting any real command
// (or existing test corpus) reaches by orders of magnitude, while staying well
// under the level where the renderers were measured to throw on this tree.
const MAX_SPAN_DEPTH = 2048;

// Characters that continue a shell WORD. Used for keyword boundary tests only.
const WORD_CH = /[A-Za-z0-9_./-]/;
// Reserved words after which a fresh command list begins.
const CMD_LIST_KEYWORDS = ["then", "do", "else", "elif"];

// True when `word` sits at `i` as a standalone shell word.
function isWordAt(str, i, word) {
  if (str.slice(i, i + word.length) !== word) return false;
  if (i > 0 && WORD_CH.test(str[i - 1])) return false;
  const after = str[i + word.length];
  if (after !== undefined && WORD_CH.test(after)) return false;
  return true;
}

// True when the text ending at `end` (exclusive) is one of `words`, standalone.
function endsWithKeyword(str, end, frameStart, words) {
  for (const w of words) {
    const s = end - w.length;
    if (s < frameStart) continue;
    if (str.slice(s, end) !== w) continue;
    if (s === 0 || !WORD_CH.test(str[s - 1])) return true;
  }
  return false;
}

// True when position `i` is where a command may start inside the current frame:
// at the frame body's start, or right after a separator / list keyword. Anything
// else (e.g. the `case` in `grep case file`) is an ordinary argument word.
function atCommandStart(str, i, frameStart) {
  let j = i - 1;
  while (j >= frameStart && (str[j] === " " || str[j] === "\t")) j -= 1;
  if (j < frameStart) return true;
  const c = str[j];
  if (c === ";" || c === "&" || c === "|" || c === "(" || c === "{" || c === "\n" || c === "\r") {
    return true;
  }
  return endsWithKeyword(str, j + 1, frameStart, CMD_LIST_KEYWORDS);
}

function makeSpan(kind, start, innerStart, depth, parent) {
  return {
    kind,
    start,
    innerStart,
    innerEnd: -1,
    end: -1,
    closed: false,
    expands: EXPANDS[kind] === true,
    depth,
    parent,
  };
}

// The whole scan, without memoization or input validation.
function scanRaw(str) {
  const spans = [];
  const stack = [];
  const n = str.length;
  let i = 0;

  // Per-frame `case … esac` nesting depth, parallel to `stack` (index 0 is the
  // base frame), plus each frame's body start for the command-position test.
  const caseDepth = [0];
  const frameStart = [0];
  let overflow = false;

  const topKind = () => (stack.length === 0 ? "base" : spans[stack[stack.length - 1]].kind);
  const open = (kind, start, innerStart) => {
    const parent = stack.length === 0 ? null : stack[stack.length - 1];
    spans.push(makeSpan(kind, start, innerStart, stack.length, parent));
    stack.push(spans.length - 1);
    caseDepth.push(0);
    frameStart.push(innerStart);
  };
  const close = (innerEnd, end) => {
    const s = spans[stack.pop()];
    s.innerEnd = innerEnd;
    s.end = end;
    s.closed = true;
    caseDepth.pop();
    frameStart.pop();
  };

  while (i < n) {
    if (stack.length > MAX_SPAN_DEPTH) { overflow = true; break; }
    const kind = topKind();
    const ch = str[i];

    // --- single-quoted: nothing is special except the closing quote ---------
    if (kind === "sq") {
      if (ch === "'") { close(i, i + 1); i += 1; continue; }
      i += 1;
      continue;
    }

    // --- ANSI-C ($'...'): backslash escapes, then the closing quote ---------
    if (kind === "ansic") {
      if (ch === "\\") { i += 2; continue; }
      if (ch === "'") { close(i, i + 1); i += 1; continue; }
      i += 1;
      continue;
    }

    // --- double-quoted: escapes plus substitutions, no word/subshell syntax -
    if (kind === "dq") {
      if (ch === "\\") { i += 2; continue; }
      if (ch === '"') { close(i, i + 1); i += 1; continue; }
      if (ch === "`") { open("backtick", i, i + 1); i += 1; continue; }
      if (ch === "$" && str[i + 1] === "(" && str[i + 2] === "(") {
        open("arith", i, i + 3); i += 3; continue;
      }
      if (ch === "$" && str[i + 1] === "(") { open("cmdsubst", i, i + 2); i += 2; continue; }
      i += 1;
      continue;
    }

    // --- command context: base / cmdsubst / backtick / subshell / arith -----
    if (ch === "\\") { i += 2; continue; }

    // `case … esac` makes `)` a PATTERN TERMINATOR rather than a frame close, and
    // a case statement is legal inside any command frame. Without this, the very
    // first pattern paren closes the enclosing `$(`, truncating the substitution
    // span and dropping every command after it out of the scan's view (#1569).
    // Arithmetic frames have no reserved words, so they are excluded.
    if (kind !== "arith" && (ch === "c" || ch === "e")) {
      const fs = frameStart[frameStart.length - 1];
      if (ch === "c" && isWordAt(str, i, "case") && atCommandStart(str, i, fs)) {
        caseDepth[caseDepth.length - 1] += 1;
        i += 4;
        continue;
      }
      if (ch === "e" && caseDepth[caseDepth.length - 1] > 0 && isWordAt(str, i, "esac")
          && atCommandStart(str, i, fs)) {
        caseDepth[caseDepth.length - 1] -= 1;
        i += 4;
        continue;
      }
    }
    if (ch === '"') { open("dq", i, i + 1); i += 1; continue; }
    if (ch === "'") { open("sq", i, i + 1); i += 1; continue; }
    if (ch === "$" && str[i + 1] === "'") { open("ansic", i, i + 2); i += 2; continue; }
    if (ch === "$" && str[i + 1] === "(" && str[i + 2] === "(") {
      open("arith", i, i + 3); i += 3; continue;
    }
    if (ch === "$" && str[i + 1] === "(") { open("cmdsubst", i, i + 2); i += 2; continue; }
    if (ch === "`") {
      // Backticks do not nest: the next ` always closes the open one.
      if (kind === "backtick") { close(i, i + 1); i += 1; continue; }
      open("backtick", i, i + 1);
      i += 1;
      continue;
    }
    if (ch === "(") { open("subshell", i, i + 1); i += 1; continue; }
    if (ch === ")") {
      // Inside an open `case`, this paren ends a pattern list — never a frame.
      if (caseDepth[caseDepth.length - 1] > 0) { i += 1; continue; }
      if (kind === "cmdsubst" || kind === "subshell") { close(i, i + 1); i += 1; continue; }
      if (kind === "arith" && str[i + 1] === ")") { close(i, i + 2); i += 2; continue; }
      i += 1;
      continue;
    }
    i += 1;
  }

  const ok = !overflow && stack.length === 0;
  const failKinds = [];
  for (const idx of stack) {
    failKinds.push(spans[idx].kind);
    spans[idx].innerEnd = n;
    spans[idx].end = n;
  }
  // A depth overflow is not a statement about any one kind — the whole scan is
  // untrustworthy, so every predicate must take the danger branch ("*").
  if (overflow) failKinds.push("*");
  return {
    spans,
    ok,
    failReason: ok ? undefined : (overflow ? "depth" : "unclosed"),
    failKinds,
    str,
  };
}

// Degenerate-input shape: never throw, always fail-closed.
function exceptionResult(str) {
  return {
    spans: [],
    ok: false,
    failReason: "exception",
    failKinds: ["*"],
    str: typeof str === "string" ? str : "",
  };
}

/**
 * scanSpans(str) -> ScanResult
 *   { spans: Span[], ok: boolean, failReason?: string, failKinds: string[], str: string }
 *
 * Span = { kind, start, innerStart, innerEnd, end, closed, expands, depth, parent }
 *   start/end       — outer bounds, `end` exclusive (delimiters included)
 *   innerStart/End  — body bounds (delimiters excluded)
 *   depth           — number of enclosing spans (0 = outermost)
 *   parent          — index into `spans` of the enclosing span, or null
 *
 * Memoized on the exact input string (8-entry LRU) — hooks scan the same
 * command text from several predicates in one PreToolUse pass.
 */
function scanSpans(str) {
  if (typeof str !== "string") return exceptionResult(str);
  if (cache.has(str)) {
    const hit = cache.get(str);
    cache.delete(str);
    cache.set(str, hit);
    return hit;
  }
  let result;
  try {
    result = scanRaw(str);
  } catch (e) {
    result = exceptionResult(str);
  }
  cache.set(str, result);
  if (cache.size > CACHE_LIMIT) cache.delete(cache.keys().next().value);
  return result;
}

function _resetCacheForTest() {
  cache.clear();
}

module.exports = {
  scanSpans,
  _resetCacheForTest,
  QUOTE_KINDS,
  EXPANDING_KINDS,
};
