#!/usr/bin/env node
// CLI wrapper around hooks/lib/model-match.js, the SSOT for model
// identification. Exists so shell callers (bin/github-issues/issue-create.sh)
// and LLM callers (skills/issue-create) reuse the same parser, matcher and
// label table instead of re-implementing them.
//
// Usage:
//   node bin/model-match.js --extract-self-report "<self-report sentence>"
//   node bin/model-match.js --reporter-label <model-id>
//   node bin/model-match.js --match <model-id> --keywords "<a;b;c>"
//
// Each subcommand prints its single result on one line, or nothing when there
// is no match. Exit 0 always — "no match" is a normal outcome, so callers can
// use the output directly. Exit 2 (with a stderr message) is reserved for a
// malformed invocation.

"use strict";
const path = require("path");
const {
  extractModelIdFromSelfReport,
  parseKeywordList,
  matchKeyword,
  resolveReporterModelLabel,
} = require(path.join(__dirname, "..", "hooks", "lib", "model-match.js"));

function usage(message) {
  process.stderr.write(
    `${message}\n` +
      "Usage:\n" +
      "  model-match.js --extract-self-report <text>\n" +
      "  model-match.js --reporter-label <model-id>\n" +
      "  model-match.js --match <model-id> --keywords <a;b;c>\n"
  );
  process.exit(2);
}

// Print the result and terminate. `null` / empty prints an empty line so the
// caller's `$(...)` capture yields an empty string rather than the word "null".
function emit(value) {
  process.stdout.write(`${value || ""}\n`);
  process.exit(0);
}

const argv = process.argv.slice(2);
const subcommand = argv[0];

if (subcommand === "--extract-self-report") {
  if (argv.length < 2) usage("--extract-self-report requires a text argument");
  emit(extractModelIdFromSelfReport(argv[1]));
}

if (subcommand === "--reporter-label") {
  if (argv.length < 2) usage("--reporter-label requires a model id argument");
  emit(resolveReporterModelLabel(argv[1]));
}

if (subcommand === "--match") {
  if (argv.length < 2) usage("--match requires a model id argument");
  const modelId = argv[1];
  const keywordsFlagIndex = argv.indexOf("--keywords", 2);
  if (keywordsFlagIndex === -1 || argv.length < keywordsFlagIndex + 2) {
    usage("--match requires --keywords <a;b;c>");
  }
  emit(matchKeyword(modelId, parseKeywordList(argv[keywordsFlagIndex + 1])));
}

usage(`unknown subcommand: ${subcommand === undefined ? "(none)" : subcommand}`);
