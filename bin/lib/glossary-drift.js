"use strict";
// bin/lib/glossary-drift.js — the deterministic spelling-drift check of #2529 S3 (dispatch and
// re-export only; the parts live in glossary-drift/). It never reads a file: the artifact text and
// the terms come from scope.js loadStageInputs (invariant I-FP). This file and its parts are
// RULE_MODULES of the glossary-check fingerprint. Matching rules SSOT:
// docs/architecture/claude-code/glossary-check.md#matching-rules.

const { extractCheckableText } = require("./glossary-drift/extract");
const { findVariants } = require("./glossary-drift/match");
const { findDrift, scanStageInputs } = require("./glossary-drift/scan");

module.exports = { extractCheckableText, findVariants, findDrift, scanStageInputs };
