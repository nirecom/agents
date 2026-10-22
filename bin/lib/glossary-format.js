#!/usr/bin/env node
"use strict";
// bin/lib/glossary-format.js — parser, checks and file enumeration for the glossary
// entry files docs/glossary/<category>*.md (#2529). Dispatch and re-export only; the
// logic lives in glossary-format/ (entries, files, prompt-data, cli). Shared by the
// bin/review-doc-glossary gate, bin/glossary-promote and the codex prompt data
// (bin/lib/codex-glossary.sh via `prompt-data`). Entry form and the range split rule
// are owned by rules/docs/glossary.md.

const entries = require("./glossary-format/entries");
const files = require("./glossary-format/files");
const promptData = require("./glossary-format/prompt-data");
const cli = require("./glossary-format/cli");

// exitCode, not exit(): a forced exit can cut off stdout still draining into a pipe.
if (require.main === module) process.exitCode = cli.main(process.argv.slice(2));

module.exports = Object.assign({}, entries, files, promptData, { main: cli.main });
