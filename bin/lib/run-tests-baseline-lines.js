#!/usr/bin/env node
// bin/lib/run-tests-baseline-lines.js — the row-file body of one result dir for the baseline
// ledger (#2956 S7), written by rtb_ledger_lines_store (bin/lib/run-tests-baseline-lines.sh).
// The body is the comparer's fingerprint input (run-tests-baseline-compare/diff.js), normalized
// without renames, so sha256(body) is the side's fp and the comparer can re-read a rebuilt dir.
//
// Usage: run-tests-baseline-lines.js --res <dir> --root <ROOT> --base-wt <wt> --out <file>
// Output: the fp (64 hex) on stdout; the body in <file>.
// Exit: 0 written, 1 the body does not match the comparer's fingerprint, 2 usage or write failure.
"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const { readSide } = require("./run-tests-baseline-compare/records");
const { makeNormalizer } = require("./run-tests-baseline-compare/normalize");
const { fingerprint } = require("./run-tests-baseline-compare/diff");

const FLAGS = ["res", "root", "base-wt", "out"];

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i].replace(/^--/, "");
    if (!FLAGS.includes(key) || i + 1 >= argv.length) return null;
    opts[key] = argv[i + 1];
  }
  return FLAGS.every((f) => opts[f] !== undefined) ? opts : null;
}

// bodyOf(side, normalize) — { body, byCase } in the fingerprint's exact form.
function bodyOf(side, normalize) {
  const byCase = new Map();
  for (const [name, detail] of side.lines) {
    if (!byCase.has(name)) byCase.set(name, []);
    byCase.get(name).push(normalize(detail, []));
  }
  const rows = [];
  for (const [name, lines] of byCase) for (const l of lines) rows.push(`${name}\t${l}`);
  rows.sort();
  return { body: `${[`records=${side.recorded ? "cases" : "none"}`, ...rows].join("\n")}\n`, byCase };
}

function main(argv) {
  const opts = parseArgs(argv);
  if (!opts) {
    process.stderr.write("usage: run-tests-baseline-lines.js --res <dir> --root <ROOT> --base-wt <wt> --out <file>\n");
    return 2;
  }
  const side = readSide(opts.res);
  const { body, byCase } = bodyOf(side, makeNormalizer({ root: opts.root, baseWt: opts["base-wt"] }));
  const fp = crypto.createHash("sha256").update(body).digest("hex");
  if (fp !== fingerprint(side, byCase)) {
    process.stderr.write("run-tests-baseline-lines: body drifted from the comparer's fingerprint\n");
    return 1;
  }
  try { fs.writeFileSync(opts.out, body); } catch (e) {
    process.stderr.write(`run-tests-baseline-lines: ${e.message}\n`);
    return 2;
  }
  process.stdout.write(`${fp}\n`);
  return 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = { bodyOf, main };
