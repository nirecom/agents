#!/usr/bin/env node
// bin/lib/last-json-object.js — extract complete JSON objects from LLM stdout.
//
// Structured parse, never regex-scraping: an LLM answer is prose with one or more
// JSON objects somewhere inside it, and the only reliable way to find them is to
// balance braces while respecting string literals and escapes.
//
// Extracted here (#1761) from bin/request-off-clearance so that every consumer of
// codex output — the OFF-clearance examiner and the issue-verdict reviewer — reads
// the same parser (CPR-2). Callers that must reject an ambiguous answer need the
// CARDINALITY too, so the array is the primary export and `lastJsonObject` is the
// convenience wrapper over it.
//
// CLI:  node bin/lib/last-json-object.js --fields a,b < input
//       stdout = the named fields of the LAST object, tab-separated, flattened to
//       one line each. exit 1 when no JSON object was found.
"use strict";

// extractJsonObjects(text): every top-level `{...}` in `text` that parses as a JSON
// object, in order of appearance. Arrays and scalars are not objects and are skipped.
function extractJsonObjects(text) {
  const s = typeof text === "string" ? text : "";
  const objs = [];
  for (let i = 0; i < s.length; i++) {
    if (s[i] !== "{") continue;
    let depth = 0;
    let inStr = false;
    let esc = false;
    for (let j = i; j < s.length; j++) {
      const c = s[j];
      if (inStr) {
        if (esc) esc = false;
        else if (c === "\\") esc = true;
        else if (c === "\"") inStr = false;
        continue;
      }
      if (c === "\"") { inStr = true; continue; }
      if (c === "{") { depth++; continue; }
      if (c !== "}") continue;
      depth--;
      if (depth !== 0) continue;
      try {
        const o = JSON.parse(s.slice(i, j + 1));
        if (o && typeof o === "object" && !Array.isArray(o)) objs.push(o);
      } catch (_e) { /* not JSON — skip */ }
      i = j;
      break;
    }
  }
  return objs;
}

// lastJsonObject(text): the last extracted object, or null when there is none.
// "Last" and not "first": a model that reasons out loud emits its answer at the end.
function lastJsonObject(text) {
  const objs = extractJsonObjects(text);
  return objs.length === 0 ? null : objs[objs.length - 1];
}

// flatten(v): a string value reduced to one line — the note/audit sinks downstream
// are all single-line formats.
function flatten(v) {
  return typeof v === "string" ? v.replace(/[\t\r\n]+/g, " ").trim() : "";
}

module.exports = { extractJsonObjects, lastJsonObject, flatten };

if (require.main === module) {
  const argv = process.argv.slice(2);
  let fields = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--fields" && i + 1 < argv.length) fields = argv[i + 1].split(",");
  }
  let input = "";
  try {
    input = require("fs").readFileSync(0, "utf8");
  } catch (_e) {
    input = "";
  }
  const last = lastJsonObject(input);
  if (!last) process.exit(1);
  process.stdout.write(fields.map((f) => flatten(last[f])).join("\t"));
}
