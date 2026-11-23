"use strict";
// tests/lib/windows-hide-scan.js — the #3127 static scan for child_process calls that lack
// windowsHide: true under hooks/** and bin/**. Re-export only; the logic lives in windows-hide-scan/.
const { mask, splitTop, spawnCalls, rawWithoutHide } = require("./windows-hide-scan/parse");
const { scanSource } = require("./windows-hide-scan/route");
const { listTargetFiles, scanTree, applyAllowlist, formatViolation } = require("./windows-hide-scan/tree");

module.exports = { mask, splitTop, spawnCalls, rawWithoutHide, listTargetFiles, scanSource, scanTree, applyAllowlist, formatViolation };
