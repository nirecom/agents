#!/usr/bin/env node
// Test-only helper for tests/hooks/TL3-hook-registered-deny.sh:
//   node write-settings.js <deployed-settings.json> <out-settings.json> <allow-json-array> [hookName...]
// Writes a fixture settings.json whose PreToolUse holds, for each named hook, its Bash
// registration copied verbatim from the deployed settings.json (matcher, command, timeout), plus
// the given permissions.allow. No other key is copied (never disableBypassPermissionsMode).
"use strict";

const fs = require("fs");

const [deployedPath, outPath, allowJson, ...hookNames] = process.argv.slice(2);
const deployed = JSON.parse(fs.readFileSync(deployedPath, "utf8"));
const groups = [];
for (const hookName of hookNames) {
  const found = [];
  for (const group of (deployed.hooks && deployed.hooks.PreToolUse) || []) {
    if (!String(group.matcher || "").split("|").includes("Bash")) continue;
    for (const hook of group.hooks || []) {
      if (String(hook.command || "").includes(`/hooks/${hookName}.js`)) found.push({ matcher: group.matcher, hooks: [hook] });
    }
  }
  if (found.length !== 1) {
    process.stderr.write(`write-settings: want one Bash PreToolUse registration of ${hookName}, found ${found.length}\n`);
    process.exit(1);
  }
  groups.push(found[0]);
}
const settings = { hooks: { PreToolUse: groups }, permissions: { allow: JSON.parse(allowJson) } };
fs.writeFileSync(outPath, JSON.stringify(settings, null, 2) + "\n");
