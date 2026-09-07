"use strict";
// hooks/lib/command-ir.js — Bash command Intermediate Representation (IR).
//
// Dispatch + re-export only (rules/coding/file-split.md Pattern A); the logic lives
// in ./command-ir/. parse(cmd) tokenises a raw command once into a structure that
// classifiers query without re-parsing; analysisOf(ir) reads the non-enumerable
// heredoc/substitution/group/separator-link side-channel; isOsTempPath is the SSOT
// temp-path predicate; resolveEffectiveSegment penetrates env prefixes and control
// keywords. Ownership map: docs/architecture/claude-code/shell-command-parsing.md.

const { parse } = require("./command-ir/parse");
const { analysisOf } = require("./command-ir/analysis");
const { isOsTempPath } = require("./command-ir/temp-path");
const { resolveEffectiveSegment } = require("./command-ir/effective");

module.exports = { parse, analysisOf, isOsTempPath, resolveEffectiveSegment };
