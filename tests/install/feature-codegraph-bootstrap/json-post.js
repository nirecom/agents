"use strict";
// Tests: install/codegraph-mcp.js
// Tags: codegraph, installer, json-post, TL2, scope:issue-specific
// json-post.js <baseline> <post> — the JSON_POST verdict (#2254, replaces the old
// C10 byte identity). Prints exactly one of:
//   same          — byte-identical, or both absent (checked before any parse)
//   always        — post === canonical(baseline + mcpServers.codegraph.alwaysLoad)
//   other:<why>   — anything else
// For a canonical baseline (the real-CLI path) `always` also requires the line diff
// to be the inserted alwaysLoad line plus a comma on the line before it.
const fs = require("fs");

const canonical = (v) => JSON.stringify(v, null, 2) + "\n";
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

function read(file) {
  try { return fs.readFileSync(file); } catch (e) { return null; }
}

function lineDiffOk(baseText, postText) {
  const b = baseText.split("\n");
  const p = postText.split("\n");
  if (p.length !== b.length + 1) return false;
  let k = 0;
  while (k < b.length && b[k] === p[k]) k++;
  // p[k] is the line before the insertion with a comma added; p[k+1] is the insertion.
  if (k >= b.length || p[k] !== b[k] + ",") return false;
  if (!/^\s*"alwaysLoad": true$/.test(p[k + 1])) return false;
  for (let j = k + 1; j < b.length; j++) {
    if (p[j + 1] !== b[j]) return false;
  }
  return true;
}

function verdict(baseFile, postFile) {
  const base = read(baseFile);
  const post = read(postFile);
  if (base === null && post === null) return "same";
  if (base !== null && post !== null && base.equals(post)) return "same";
  if (base === null) return "other:baseline-absent";
  if (post === null) return "other:post-absent";
  const baseText = base.toString("utf8");
  let data;
  try { data = JSON.parse(baseText); } catch (e) { return "other:baseline-unparsable"; }
  if (!isObj(data)) return "other:baseline-root-not-object";
  if (!isObj(data.mcpServers) || !isObj(data.mcpServers.codegraph)) return "other:baseline-no-entry";
  data.mcpServers.codegraph.alwaysLoad = true;
  const want = canonical(data);
  const postText = post.toString("utf8");
  if (postText !== want) return "other:post-not-canonical-baseline-plus-alwaysLoad";
  const baseIsCanonical = baseText === canonical(JSON.parse(baseText));
  if (baseIsCanonical && !lineDiffOk(baseText, postText)) return "other:line-diff-beyond-alwaysLoad";
  return "always";
}

process.stdout.write(verdict(process.argv[2], process.argv[3]) + "\n");
