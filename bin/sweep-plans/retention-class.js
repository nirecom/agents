#!/usr/bin/env node
// bin/sweep-plans/retention-class.js — the bash -> registry bridge of sweep-plans.
// stdin: <group-prefix> NUL <basename> NUL pairs; stdout: one retention word per pair
// (plan / user-requested / non-plan / unknown), LF-separated, in input order.
// The registry (hooks/lib/plans-artifact-registry.js) owns the kind table; this file never copies it.
"use strict";

const path = require("path");
const { retentionClassOf } = require(path.join(__dirname, "..", "..", "hooks", "lib", "plans-artifact-registry.js"));

// Named exception (#847 allowlist, intent decision): empty-prefix names are classified by kind, not as unknown.
function classifyEmptyPrefixBucket(basename) {
  const EMPTY_PREFIX_PROBE_SID = "emptyprefix";
  return retentionClassOf(EMPTY_PREFIX_PROBE_SID + basename, EMPTY_PREFIX_PROBE_SID);
}

function classify(prefix, basename) {
  return prefix === "" ? classifyEmptyPrefixBucket(basename) : retentionClassOf(basename, prefix);
}

const chunks = [];
process.stdin.on("data", (c) => chunks.push(c));
process.stdin.on("end", () => {
  const fields = Buffer.concat(chunks).toString("utf8").split("\0");
  fields.pop(); // the text after the final NUL terminator
  if (fields.length % 2 !== 0) throw new Error("retention-class: odd number of NUL-separated fields");
  const words = [];
  for (let i = 0; i < fields.length; i += 2) words.push(classify(fields[i], fields[i + 1]));
  process.stdout.write(words.map((w) => `${w}\n`).join(""));
});
