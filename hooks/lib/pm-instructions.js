"use strict";
// PM supervisor duties injection (#3019). Dispatch and re-export only (Pattern A); the parts live in
// ./pm-instructions/. SSOT of the duties: skills/_shared/pm-supervisor-duties.md.

const { buildInjection, getPmInstructionsInjection } = require("./pm-instructions/inject");
const { CONTRACT, BUNDLES, TIMINGS, MD_ENV, SectionError } = require("./pm-instructions/sections");
const { resolveRole } = require("./pm-instructions/role");
const { MAX_BYTES } = require("./pm-instructions/render");

module.exports = { getPmInstructionsInjection, buildInjection, resolveRole, CONTRACT, BUNDLES, TIMINGS, MD_ENV, MAX_BYTES, SectionError };
