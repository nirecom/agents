// hooks/lib/bash-write-patterns.js
// Dispatch + re-export. Logic lives in bash-write-patterns/ sibling directory.
// External contract: { WRITE_PATTERNS, classify, classifyDetailed, isReadOnlyInterpreterC }
"use strict";
const { WRITE_PATTERNS } = require("./bash-write-patterns/patterns");
const { classify, classifyDetailed, isReadOnlyInterpreterC } = require("./bash-write-patterns/classify");
module.exports = { WRITE_PATTERNS, classify, classifyDetailed, isReadOnlyInterpreterC };
