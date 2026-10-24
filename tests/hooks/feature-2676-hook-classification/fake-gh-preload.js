"use strict";
// Test-only preload for fixture.fakeGhEnv(): on Windows the fake gh is a copy of the node binary
// named gh.exe (Node's shell-less spawn resolves only .exe / .com), and this preload makes that
// copy act as the fake: no output, exit 1. Inert in every other node process.
const path = require("path");

if (path.basename(process.execPath).replace(/\.exe$/i, "").toLowerCase() === "gh") process.exit(1);
