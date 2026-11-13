#!/usr/bin/env node
// bin/lib/run-tests-baseline-compare.js — the #2956 S4 comparer bin/run-tests-baseline calls
// through rtb_compare (bin/lib/run-tests-baseline-compare.sh). Dispatch only; the logic lives in
// run-tests-baseline-compare/{records,normalize,markers,diff}.js.
//
// Usage: run-tests-baseline-compare.js --base-res <dir> --branch-res <dir> --file <rel>
//          --rename-map <tsv> --root <ROOT> --base-wt <wt> --branch-end <normal|interrupted>
// Output: one line RESULT\t<verdict>\t<new_count>\t<new_head_json>\t<fp_base>\t<fp_branch>
// Exit: 0 RESULT printed, 2 usage.
"use strict";

const fs = require("node:fs");
const { readSide, readRenameMap } = require("./run-tests-baseline-compare/records");
const { makeNormalizer, LINE_NO_EXTS } = require("./run-tests-baseline-compare/normalize");
const { compareSides } = require("./run-tests-baseline-compare/diff");

const FLAGS = ["base-res", "branch-res", "file", "rename-map", "root", "base-wt", "branch-end"];
const OPTIONAL_FLAGS = ["new-lines-out"];
const ENDS = ["normal", "interrupted"];

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i].replace(/^--/, "");
    if (!(FLAGS.includes(key) || OPTIONAL_FLAGS.includes(key)) || i + 1 >= argv.length) return { error: `bad argument: ${argv[i]}` };
    opts[key] = argv[i + 1];
  }
  const absent = FLAGS.filter((f) => opts[f] === undefined);
  if (absent.length) return { error: `missing: --${absent.join(" --")}` };
  if (!ENDS.includes(opts["branch-end"])) return { error: `--branch-end must be ${ENDS.join("|")}` };
  return { opts };
}

function main(argv) {
  const { opts, error } = parseArgs(argv);
  if (error) {
    process.stderr.write(`run-tests-baseline-compare: ${error}\n`);
    return 2;
  }
  const r = compareSides(readSide(opts["base-res"]), readSide(opts["branch-res"]), {
    normalize: makeNormalizer({ root: opts.root, baseWt: opts["base-wt"] }),
    renames: readRenameMap(opts["rename-map"]),
    end: opts["branch-end"],
  });
  // --new-lines-out: every new line (the RESULT head keeps only the first few), one per row.
  if (opts["new-lines-out"] && r.all.length) fs.writeFileSync(opts["new-lines-out"], `${r.all.join("\n")}\n`);
  process.stdout.write(`RESULT\t${r.verdict}\t${r.count}\t${JSON.stringify(r.head)}\t${r.fpBase}\t${r.fpBranch}\n`);
  return 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = { main, LINE_NO_EXTS };
