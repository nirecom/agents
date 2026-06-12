// hooks/lib/shell-segments.js
// SSOT for the quote-aware shell-segment splitter used across hooks.
// Lifted from hooks/lib/merge-detect.js. Splits on ;, &&, || while honoring
// single- and double-quote state. Pipes (|) and background (&) are not split.

"use strict";

function splitShellCommands(command) {
  const segments = [];
  let current = "";
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (c === "'" && !inDouble) inSingle = !inSingle;
    else if (c === '"' && !inSingle) inDouble = !inDouble;

    if (!inSingle && !inDouble) {
      if (c === ";") {
        segments.push(current);
        current = "";
        continue;
      }
      if ((c === "&" || c === "|") && command[i + 1] === c) {
        segments.push(current);
        current = "";
        i++;
        continue;
      }
    }
    current += c;
  }
  segments.push(current);
  return segments.map((s) => s.trim()).filter(Boolean);
}

module.exports = { splitShellCommands };
