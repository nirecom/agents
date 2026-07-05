// hooks/lib/bash-write-patterns.js
// Dispatch + re-export. Logic lives in bash-write-patterns/ sibling directory.
// External contract: { WRITE_PATTERNS, classify, classifyDetailed, isReadOnlyInterpreterC, isGhWriteIR, resolveEffectiveCommand, resolveEffectiveArgv }
"use strict";
const { WRITE_PATTERNS, isGhWriteIR } = require("./bash-write-patterns/patterns");
const { classify, classifyDetailed, isReadOnlyInterpreterC } = require("./bash-write-patterns/classify");
const { resolveEffectiveCommand, resolveEffectiveArgv } = require("./bash-write-patterns/segment-utils");
module.exports = { WRITE_PATTERNS, classify, classifyDetailed, isReadOnlyInterpreterC, isGhWriteIR, resolveEffectiveCommand, resolveEffectiveArgv };
