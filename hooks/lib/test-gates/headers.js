"use strict";
// The one reader of a test file's `Tests:` / `Tags:` header lines (#2507 D7; was
// bin/lib/test-frontmatter-headers.sh): the first line within headerMaxLines that starts with
// "<commentPrefix> Tests:" (or Tags:), whole; "" when none. A CRLF line loses its CR, as the
// awk of the bash reader gave it on the host the golden was made on.

const R = require("./registry");

// The lines of the content as the bash reader saw them: trailing LFs cut, split on LF.
function linesOf(content) {
  const s = String(content).replace(/\n+$/, "");
  return s.split("\n");
}

function headerLine(lines, max, prefix) {
  const n = Math.min(lines.length, max);
  for (let i = 0; i < n; i += 1) if (lines[i].startsWith(prefix)) return lines[i].replace(/\r$/, "");
  return "";
}

// readHeaders(content, matchPath) -> { tests, tags }; matchPath picks the comment prefix.
function readHeaders(content, matchPath) {
  const prefix = R.commentPrefix(matchPath);
  const max = R.reg().headerMaxLines;
  const lines = linesOf(content);
  return { tests: headerLine(lines, max, `${prefix} Tests:`), tags: headerLine(lines, max, `${prefix} Tags:`) };
}

module.exports = { readHeaders };
