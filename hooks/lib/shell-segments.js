// hooks/lib/shell-segments.js
// Legacy quote-aware segment splitter, shrinking toward hooks/lib/command-ir/.
// Splits on ;, &&, || honoring quote state; pipes (|) and background (&) are NOT split.
// canary-1 (merge-detect.js) already migrated to parse(); the remaining 2 consumers
// migrate under #1253. Ownership map: docs/architecture/claude-code/shell-command-parsing.md.

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
