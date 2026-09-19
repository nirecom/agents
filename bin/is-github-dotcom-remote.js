"use strict";
// #2307: forge classification for bin/is-github-dotcom-remote via the shared
// detectForgeType() (SSOT). Relative require keeps it AGENTS_CONFIG_DIR-independent.
// Prints "github" | "other" | "unknown" for the wrapper's 0/1/2 exit contract:
// the github/other split needs the host field, since a non-github host and a
// missing host both classify as type "unknown" (only host tells 1 from 2).
const { detectForgeType } = require("../hooks/lib/parse-remote-url");
const url = process.argv[2] || "";
const { type, host } = detectForgeType(url);
process.stdout.write(type === "github" ? "github" : (host ? "other" : "unknown"));
