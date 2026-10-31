"use strict";
// envClearLine part of the bash entry (#2507 D7): 0 when the line only clears the named env vars
// (an `unset` line, or every named use is a `-u NAME`), 1 otherwise. The CR is kept, as bash does.
const { test, longest } = require("./match");

const UNSET_RE = "^[[:space:]]*unset([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)+([[:space:]]+2>[[:space:]]*/dev/null)?([[:space:]]*\\|\\|[[:space:]]*true)?[[:space:]]*$";

function envClearLine(names, line) {
  let text = String(line);
  if (test(UNSET_RE, text)) return 0;
  const dashU = `(^|[[:space:]])-u[[:space:]]+(${names})([^A-Za-z0-9_]|$)`;
  for (let m = longest(dashU, text); m !== null; m = longest(dashU, text)) {
    const tail = /[^A-Za-z0-9_]$/.test(m) ? m.slice(-1) : "";
    const at = text.indexOf(m);
    text = `${text.slice(0, at)} ${tail}${text.slice(at + m.length)}`;
  }
  return test(`(^|[^A-Za-z0-9_])(${names})([^A-Za-z0-9_]|$)`, text) ? 1 : 0;
}

module.exports = { envClearLine };
