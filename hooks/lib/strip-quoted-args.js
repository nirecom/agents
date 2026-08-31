"use strict";

const { blankQuoteSpans, unwrapCmdSubstInDq } = require("./quote-spans");

// Strip DQ literal content, but unwrap (not blank) $(...) / `...` inside a DQ
// span by replacing the wrapper chars with spaces, so inner writes like
// $(rm foo) stay visible to the command-position write-pattern anchor
// (?:^|[\s;|&])<word>\b — blanking them would hide the write (#514 HIGH).
// Span boundaries come from the shared scanner (hooks/lib/quote-spans), which
// is quote-aware (a depth-counted `$(` walker misreads a `)` hidden inside a
// single-quoted string in the substitution body); an unparseable command
// returns unchanged, keeping the caller on the fail-closed "write" side.
// The try/catch is load-bearing: this runs inside a PreToolUse hook, and an
// escaping exception kills the hook (read as "no objection" = fail-OPEN).
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

// True when `prefix` (text before a sink) leaves a $(, <( or ` open: whatever
// the sink writes to stdout is then CAPTURED and run by the outer command, so
// it is an interpreter's input, not a local file write (#2120/#2121 r2 HIGH).
// Bare `(` is a subshell, not a capture, so it is deliberately not counted.
// The walk runs over blanked quote spans, not raw text: a `)` sitting inside a
// quoted literal would otherwise cancel a real open frame and under-count the
// depth. An unparseable prefix fails closed to "captured" (r5 C24).
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

// True when the newline that opens `prefix`'s last segment is escaped by a
// backslash: `bash -s \<NL>cat <<EOF` is ONE logical command, so that newline is
// not a segment boundary and `cat` is an argument, not a head (#2120/#2121 r3).
// An even run of backslashes is a literal `\`, so only an odd run continues.
function isLineContinuedBoundary(prefix) {
  const head = prefix.replace(/[ \t]*$/, "");
  if (!head.endsWith("\n")) return false;
  let backslashes = 0;
  for (let i = head.length - 2; i >= 0 && head[i] === "\\"; i--) backslashes++;
  return backslashes % 2 === 1;
}

// Mirror of isLineContinuedBoundary on the TRAILING side: when the opener line
// ends in a continuation, the next physical line is still the same logical
// command, so a pipe/chain there never reaches restOfLine (r5 HIGH).
function endsWithLineContinuation(text) {
  const tail = text.replace(/[ \t]*$/, "");
  let backslashes = 0;
  for (let i = tail.length - 1; i >= 0 && tail[i] === "\\"; i--) backslashes++;
  return backslashes % 2 === 1;
}

// Strip heredoc bodies between opening and closing tag, preserving the opener
// (so classify()'s here-doc detection still fires) and a trailing newline.
// Supports <<TAG, <<-TAG, <<'TAG', <<"TAG"; delimiter starts with letter/_.
// Safety (#371; widened #2121; re-anchored by #2120/#2121 security review r2):
// strip only when a DATA-SINK (cat/tee/sponge) OWNS the redirection — the sink
// must be the HEAD of its own segment (only whitespace between a segment
// boundary and the sink), so `bash -s cat <<EOF` or `eval "$(cat <<EOF"` cannot
// hand an interpreter's heredoc to the strip. Refuse too when the opener's own
// line pipes/chains onward (`tee out <<'EOF' | bash`), and when an unquoted
// opener's body holds $(...)/backticks. `mail` was dropped: an outbound channel.
function stripHeredocBody(str) {
  if (!str || typeof str !== "string") return str;
  try {
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
        // `> >(cmd)` / `tee >(cmd)`: the sink's output lands in a process
        // substitution that EXECUTES it, so the body is interpreter input, not
        // a local file — the write direction the $( capture check misses (r3).
        if (/>[ \t]*\(/.test(cmdPart + restOfLine)) {
          return match;
        }
        if (isLineContinuedBoundary(whole.slice(0, offset))) {
          return match;
        }
        if (isInsideSubstitution(whole.slice(0, offset))) {
          return match;
        }
        return cmdPart + opener + restOfLine + "\n";
      }
    );
  } catch (e) {
    return str;
  }
}

// Strip values of inline --body / --title (and -b/-t) so Group A gh commands and
// known-path dispatcher scripts don't false-positive on write-pattern scanning.
// Handles both `--body "..."` and `--body="..."`. --body-file is EXCLUDED (a file
// path, not body text — stripping it would hide a suspicious path from the
// classifier). Safety guard (#514 HIGH): DQ form only, do NOT strip when the body
// contains $(...) or backticks — shell expands those before gh receives the
// argument, so stripping would hide executable content. SQ form is always safe.
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

// Strip values of shell variable assignments: IDENTIFIER='...' and IDENTIFIER="...".
// Anchored to line-start or after whitespace/command-separator to avoid partial matches.
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
