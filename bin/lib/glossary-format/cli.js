"use strict";
// CLI for bin/lib/glossary-format.js: `check-files`, `check-index`, `prompt-data` and, during
// the layout migration, `legacy-paths` (#2529).

const fs = require("fs");
const { checkFiles, checkIndexFile, listMainGlossaryFiles } = require("./files");
const { promptData } = require("./prompt-data");

const LIMIT_FLAGS = { "--max-lines": "maxLines", "--max-bytes": "maxBytes" };
const PROMPT_USAGE = "usage: glossary-format.js prompt-data [--max-lines N] [--max-bytes N] " +
  "(--root <dir> | <label> <path> [<label> <path> ...])\n";

function toPairs(list) {
  const pairs = [];
  for (let k = 0; k < list.length; k += 2) pairs.push({ label: list[k], file: list[k + 1] });
  return pairs;
}

// --root <dir> reads the docs/glossary/ files (or, during the migration, the old
// layout) of <dir>; otherwise the label/path pairs are given positionally.
function parsePromptDataArgs(rest) {
  const limits = { maxLines: Infinity, maxBytes: Infinity };
  let root = null;
  let i = 0;
  while (i < rest.length && (rest[i] === "--root" || Object.prototype.hasOwnProperty.call(LIMIT_FLAGS, rest[i]))) {
    const value = rest[i + 1];
    if (rest[i] === "--root") {
      if (value === undefined || value === "" || root !== null) return null;
      root = value;
    } else {
      if (value === undefined || !/^[1-9][0-9]*$/.test(value)) return null;
      limits[LIMIT_FLAGS[rest[i]]] = Number(value);
    }
    i += 2;
  }
  const tail = rest.slice(i);
  if (root !== null) return tail.length === 0 ? { limits, root, pairs: null } : null;
  if (tail.length === 0 || tail.length % 2 !== 0) return null;
  return { limits, root, pairs: toPairs(tail) };
}

function mainPromptData(rest) {
  const parsed = parsePromptDataArgs(rest);
  if (!parsed) {
    process.stderr.write(PROMPT_USAGE);
    return 2;
  }
  try {
    const pairs = parsed.pairs ||
      listMainGlossaryFiles(parsed.root).files.map((f) => ({ label: f.label, file: f.path }));
    process.stdout.write(promptData(pairs, parsed.limits.maxLines, parsed.limits.maxBytes));
  } catch (e) {
    process.stderr.write("glossary-format.js: " + e.message + "\n");
    return 2;
  }
  return 0;
}

// check-index <label> <path>: BLOCK lines for entries in the docs/glossary.md index page.
function mainCheckIndex(rest) {
  if (rest.length !== 2) {
    process.stderr.write("usage: glossary-format.js check-index <label> <path>\n");
    return 2;
  }
  let blocks;
  try { blocks = checkIndexFile(rest[0], fs.readFileSync(rest[1], "utf8")); } catch (e) {
    process.stderr.write("glossary-format.js: " + e.message + "\n");
    return 2;
  }
  for (const b of blocks) process.stdout.write("  BLOCK: " + b + "\n");
  return blocks.length === 0 ? 0 : 1;
}

let extraCommands = {};

function main(argv) {
  const [cmd, ...rest] = argv;
  if (cmd === "prompt-data") return mainPromptData(rest);
  if (cmd === "check-index") return mainCheckIndex(rest);
  if (Object.prototype.hasOwnProperty.call(extraCommands, cmd)) return extraCommands[cmd](rest);
  if (cmd !== "check-files" || rest.length === 0 || rest.length % 2 !== 0) {
    process.stderr.write("usage: glossary-format.js check-files <label> <path> [<label> <path> ...]\n");
    return 2;
  }
  let blocks;
  try { blocks = checkFiles(toPairs(rest)); } catch (e) {
    process.stderr.write("glossary-format.js: " + e.message + "\n");
    return 2;
  }
  for (const b of blocks) process.stdout.write("  BLOCK: " + b + "\n");
  return blocks.length === 0 ? 0 : 1;
}

module.exports = { main, parsePromptDataArgs };

// --- BEGIN temporary: docs/glossary-<category>.md -> docs/glossary/<category>.md migration added 2026-10-17 ---
// deletion-condition: remove once origin/main has no docs/glossary-user.md / docs/glossary-internal.md and no worktree in "git worktree list" still has them, together with the matching blocks listed in bin/lib/glossary-format/files.js and tests/bin/feat-2529-glossary-legacy-read.sh
// `legacy-paths <path>...`: a BLOCK line per staged non-deletion path in the old layout; exit 1 when any.
extraCommands = {
  "legacy-paths": (paths) => {
    const blocks = require("./files").legacyLayoutBlocks(paths);
    for (const b of blocks) process.stdout.write("  BLOCK: " + b + "\n");
    return blocks.length === 0 ? 0 : 1;
  },
};
// --- END temporary: docs/glossary-<category>.md -> docs/glossary/<category>.md migration ---
