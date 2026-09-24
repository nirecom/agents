"use strict";
// For each case in corpus.js, prints parse(cmd, opts) as one line of stable JSON.
// Stabilization is exactly two things: (1) recursively sort keys, (2) look only at own
// enumerable properties as returned by Object.keys. (2) is itself the current-compat pin --
// redirects[].targetRaw is deliberately added as non-enumerable by hooks/lib/command-ir.js
// and must not appear in the snapshot. The analysis Step 2 adds is non-enumerable for the
// same reason.

// Output: by default, one "<id>\t<json>" line per case. --id <id> prints only that one case's JSON.
// Sorting key order is purely for snapshot stabilization; the public contract's key
// "order" is pinned separately by shape-contract.sh as an Object.keys array (roles are kept separate).

const path = require("path");
const CORPUS = require("./corpus.js");
const { parse } = require(path.join(__dirname, "..", "..", "hooks", "lib", "command-ir.js"));

// Recursive key sort. Reads only own enumerable properties, so non-enumerable ones are dropped.
function canon(v) {
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(canon);
  const out = {};
  for (const k of Object.keys(v).sort()) out[k] = canon(v[k]);
  return out;
}

// Keeps one line even when parse() throws. A throw is not expected to happen under the
// current contract, so a marker is left so the fact that it happened shows up as a snapshot diff.
function probeOne(entry) {
  let ir;
  try {
    ir = parse(entry.cmd, entry.opts);
  } catch (e) {
    return { __threw: String((e && e.message) || e) };
  }
  return canon(ir);
}

function main(argv) {
  const idFlag = argv.indexOf("--id");
  if (idFlag !== -1) {
    const wanted = argv[idFlag + 1];
    const entry = CORPUS.find((c) => c.id === wanted);
    if (!entry) {
      process.stderr.write("probe.js: unknown corpus id: " + String(wanted) + "\n");
      process.exit(2);
    }
    process.stdout.write(JSON.stringify(probeOne(entry)) + "\n");
    return;
  }
  const lines = [];
  for (const entry of CORPUS) lines.push(entry.id + "\t" + JSON.stringify(probeOne(entry)));
  process.stdout.write(lines.join("\n") + "\n");
}

if (require.main === module) main(process.argv.slice(2));

module.exports = { canon, probeOne };
