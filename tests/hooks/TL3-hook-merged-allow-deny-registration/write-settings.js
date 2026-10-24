#!/usr/bin/env node
// Test-only helper for tests/hooks/TL3-hook-merged-allow-deny-registration.sh:
//   node write-settings.js <repo-settings.json> <checkout-root> <out-settings.json>
// Copies only the PreToolUse registrations whose command runs hooks/merged-allow-deny.js,
// with $AGENTS_MAIN_ROOT spelled as <checkout-root>, into a minimal settings file (no
// permissions block, no disableBypassPermissionsMode). Prints how many it copied.
"use strict";

const fs = require("fs");

const [source, checkoutRoot, out] = process.argv.slice(2);
let settings = {};
try { settings = JSON.parse(fs.readFileSync(source, "utf8")); } catch (_e) { settings = {}; }
const root = String(checkoutRoot || "").replace(/\\/g, "/");
const groups = (((settings || {}).hooks || {}).PreToolUse || [])
  .map((group) => ({
    matcher: group.matcher,
    hooks: (group.hooks || []).filter((hook) => /merged-allow-deny\.js/.test(String(hook.command || ""))),
  }))
  .filter((group) => group.hooks.length > 0)
  .map((group) => ({
    matcher: group.matcher,
    hooks: group.hooks.map((hook) => ({ ...hook, command: String(hook.command).replace(/\$\{?AGENTS_MAIN_ROOT\}?/g, () => root) })),
  }));
fs.writeFileSync(out, JSON.stringify({ hooks: { PreToolUse: groups } }, null, 2) + "\n");
process.stdout.write(String(groups.length));
