"use strict";
// Combined-glossary data for codex prompts (#2529): `### term` + Definition per entry.

const fs = require("fs");
const { parseGlossaryFile } = require("./entries");

// Neutralizes bracketed prompt delimiters ([X START] / [X END]) and HTML comment fences.
function neutralize(s) {
  return s
    .replace(/\[([A-Z][A-Z ]*) (START|END)\]/g, "($1 $2)")
    .replace(/<!--/g, "(!--")
    .replace(/-->/g, "--)");
}

// The `### term` line plus the Definition bullet as written (continuation lines kept).
function promptEntryLines(lines, e) {
  const out = [neutralize(lines[e.lineNumber - 1])];
  const def = e.bullets.find((b) => b.key === "Definition");
  if (def) {
    for (let k = 0; k < def.lines; k++) out.push(neutralize(lines[def.lineNumber - 1 + k]));
  }
  return out;
}

// Whole entries under each file's label until a cap would be crossed; every entry
// left out is counted in the trailing [TRUNCATED: <n> entries omitted] line.
function promptData(pairs, maxLines, maxBytes) {
  let out = "";
  let usedLines = 0;
  let usedBytes = 0;
  let omitted = 0;
  for (const { label, file } of pairs) {
    let text;
    try { text = fs.readFileSync(file, "utf8"); } catch (e) {
      if (e.code === "ENOENT") continue;
      throw e;
    }
    const lines = text.split(/\r?\n/);
    let head = neutralize(label) + "\n";
    for (const e of parseGlossaryFile(text).entries) {
      const chunk = head + promptEntryLines(lines, e).join("\n") + "\n";
      const n = chunk.split("\n").length - 1;
      const b = Buffer.byteLength(chunk, "utf8");
      if (omitted > 0 || usedLines + n > maxLines || usedBytes + b > maxBytes) {
        omitted++;
        continue;
      }
      out += chunk;
      usedLines += n;
      usedBytes += b;
      head = "";
    }
  }
  if (omitted > 0) out += "[TRUNCATED: " + omitted + " entries omitted]\n";
  return out;
}

module.exports = { neutralize, promptData };
