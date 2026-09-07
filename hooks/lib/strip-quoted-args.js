"use strict";

const { blankQuoteSpans, unwrapCmdSubstInDq } = require("./quote-spans");

// Strip DQ literal content, but UNWRAP rather than blank a substitution inside
// a DQ span: blanking would hide an inner write from the command-position
// anchor (#514). The try/catch is load-bearing — an exception escaping a
// PreToolUse hook is read as "no objection" (fail-OPEN).
function stripDqPreservingCmdSubst(str) {
  if (typeof str !== "string") return str;
  try {
    return unwrapCmdSubstInDq(str).out;
  } catch (e) {
    return str;
  }
}

function stripQuotedArgs(str) {
  if (!str || typeof str !== "string") return str;
  try {
    return blankQuoteSpans(str).out;
  } catch (e) {
    return str;
  }
}

// True when `prefix` leaves a capturing frame open, so the sink's stdout is run
// by the outer command rather than written to a file (#2120). Bare `(` is a
// subshell, not a capture. Walking blanked spans keeps a `)` inside a quoted
// literal from cancelling a real frame; an unparseable prefix fails closed.
function isInsideSubstitution(prefix) {
  let scanned;
  try {
    scanned = blankQuoteSpans(prefix);
  } catch (e) {
    return true;
  }
  if (!scanned.ok) return true;
  const text = scanned.out;
  let depth = 0;
  let ticks = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "`") ticks++;
    else if ((c === "$" || c === "<") && text[i + 1] === "(") { depth++; i++; }
    else if (c === ")" && depth > 0) depth--;
  }
  return depth > 0 || ticks % 2 === 1;
}

// True when the newline opening `prefix`'s last segment is backslash-escaped:
// the line is then still the previous command, so what follows is an argument,
// not a head (#2120). Only an odd backslash run continues; even is a literal.
function isLineContinuedBoundary(prefix) {
  const head = prefix.replace(/[ \t]*$/, "");
  if (!head.endsWith("\n")) return false;
  let backslashes = 0;
  for (let i = head.length - 2; i >= 0 && head[i] === "\\"; i--) backslashes++;
  return backslashes % 2 === 1;
}

// isLineContinuedBoundary(str.slice(0, offset)) without materialising the
// prefix: only the run immediately before `offset` can change the answer.
function isLineContinuedAt(str, offset) {
  let i = offset - 1;
  while (i >= 0 && (str[i] === " " || str[i] === "\t")) i--;
  if (i < 0 || str[i] !== "\n") return false;
  let backslashes = 0;
  for (let k = i - 1; k >= 0 && str[k] === "\\"; k--) backslashes++;
  return backslashes % 2 === 1;
}

// Index of the first character that could open a quote span or substitution
// frame, or -1. Before it isInsideSubstitution is provably false, and skipping
// its per-match O(prefix) walk keeps heredoc-dense payloads from going
// quadratic past the hook's 5s timeout (#2210).
function firstSpanRelevantIndex(str) {
  for (let i = 0; i < str.length; i++) {
    const c = str[i];
    if (c === "'" || c === '"' || c === "`" || c === "$") return i;
    if (c === "<" && str[i + 1] === "(") return i;
  }
  return -1;
}

// Trailing-side mirror of isLineContinuedBoundary: a continued opener line puts
// the next line's pipe or chain outside restOfLine, where the guard misses it.
function endsWithLineContinuation(text) {
  const tail = text.replace(/[ \t]*$/, "");
  let backslashes = 0;
  for (let i = tail.length - 1; i >= 0 && tail[i] === "\\"; i--) backslashes++;
  return backslashes % 2 === 1;
}

// Strip heredoc bodies, preserving the opener so classify()'s here-doc
// detection still fires. Safety (#2120): strip only when a data sink is the
// HEAD of its own segment, so an interpreter's heredoc is never handed to the
// strip; refuse as well when the opener line chains onward or an unquoted
// body holds a substitution. `mail` is excluded as an outbound channel.
function stripHeredocBody(str) {
  if (!str || typeof str !== "string") return str;
  try {
    const spanRelevant = firstSpanRelevantIndex(str);
    return str.replace(
      /(?<=(?:^|[\n;&|])[ \t]*)((?:cat|tee|sponge)(?![\w-])(?:[ \t]+[^\s;&|<]+)*[ \t]*)(<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_.-]*)\3)([^\n]*)\n([\s\S]*?)\n\s*\4\s*(?:\n|$)/g,
      function (match, cmdPart, opener, quoteChar, _tagName, restOfLine, body, offset, whole) {
        const isQuoted = quoteChar === "'" || quoteChar === '"';
        if (!isQuoted && /\$\(|`/.test(body)) {
          return match;
        }
        if (/[|&;]/.test(restOfLine)) {
          return match;
        }
        if (endsWithLineContinuation(restOfLine)) {
          return match;
        }
        // Output into a process substitution EXECUTES the body — the write
        // direction the capture check above misses.
        if (/>[ \t]*\(/.test(cmdPart + restOfLine)) {
          return match;
        }
        if (isLineContinuedAt(whole, offset)) {
          return match;
        }
        // The empty prefix stands in when no frame can be open; the scanner is
        // still called so its throw and ok:false arms stay live.
        const captured = spanRelevant !== -1 && spanRelevant < offset;
        if (isInsideSubstitution(captured ? whole.slice(0, offset) : "")) {
          return match;
        }
        return cmdPart + opener + restOfLine + "\n";
      }
    );
  } catch (e) {
    return str;
  }
}

// Strip inline --body / --title values so gh commands don't false-positive on
// write-pattern scanning. --body-file is excluded: it is a path, and stripping
// it would hide that path from the classifier. In the DQ form a substitution is
// left alone — the shell expands it before gh sees the argument (#514).
function stripInlineBodyArg(str) {
  if (!str || typeof str !== "string") return str;
  try {
    return str
      .replace(/(--(?:body|title)|-[bt])(?:\s+|=)"((?:[^"\\]|\\.)*)"/g, function (match, flag, body) {
        if (/\$\(|`/.test(body)) return match;
        return flag + ' ""';
      })
      .replace(/(--(?:body|title)|-[bt])(?:\s+|=)'[^']*'/g, "$1 ''");
  } catch (e) {
    return str;
  }
}

// Strip shell variable assignment values; anchored to a line start or separator
// so a partial match cannot fire.
// keep in sync with classify() Group A re-strip in bash-write-patterns/classify.js
function stripShellVarAssignment(str) {
  if (!str || typeof str !== "string") return str;
  try {
    return str
      .replace(/(^|[\s;|&])([A-Za-z_][A-Za-z0-9_]*=)'[^']*'/gms, "$1$2''")
      .replace(/(^|[\s;|&])([A-Za-z_][A-Za-z0-9_]*=)"(?:[^"\\]|\\.)*"/gm, '$1$2""');
  } catch (e) {
    return str;
  }
}

module.exports = { stripQuotedArgs, stripHeredocBody, stripInlineBodyArg, stripShellVarAssignment, stripDqPreservingCmdSubst, isInsideSubstitution, isLineContinuedBoundary, endsWithLineContinuation };
