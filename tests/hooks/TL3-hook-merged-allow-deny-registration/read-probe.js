#!/usr/bin/env node
// Test-only helper for tests/hooks/TL3-hook-merged-allow-deny-registration.sh:
//   node read-probe.js <basename> <marker> <file...>
// tests/lib/tl3-turn-transcript.js --probe counts command tools only, so this reads the Read
// tool_use blocks instead: those whose file_path ends in <basename>, and their linked results.
// Prints attempted=, result_error= and marker= lines (unknown when no result is linked).
"use strict";

const fs = require("fs");
const { parseRecords, collectBlocks, resultTextOf } = require("../../lib/tl3-turn-transcript");

const [basename, marker, ...files] = process.argv.slice(2);
const records = [];
for (const file of files) {
  let text = null;
  try { text = fs.readFileSync(file, "utf8"); } catch (_e) { text = null; }
  records.push(...parseRecords(text));
}
const { uses, results } = collectBlocks(records);
const named = (filePath) => String(filePath || "").replace(/\\/g, "/").split("/").pop() === basename;
const reads = uses.filter((use) => use.name === "Read" && use.input && named(use.input.file_path));
const ids = new Set(reads.map((use) => use.id).filter((id) => typeof id === "string"));
const linked = results.filter((res) => ids.has(res.tool_use_id));
const seen = (pick) => (linked.length > 0 ? String(linked.some(pick)) : "unknown");
process.stdout.write([
  "attempted=" + String(reads.length > 0),
  "result_error=" + seen((res) => res.is_error === true),
  "marker=" + seen((res) => res.is_error === true && resultTextOf(res).indexOf(marker) !== -1),
].join("\n") + "\n");
