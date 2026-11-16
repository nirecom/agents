#!/usr/bin/env node
// Test-only helper for tests/hooks/TL3-hook-reset-from-gate.sh:
//   node write-settings.js <repo-settings.json> <checkout-root> <out-settings.json>
// Copies the PreToolUse rows that run hooks/gate-reset-from-sentinel.js and the PostToolUse rows
// that run hooks/workflow-mark.js, with $AGENTS_MAIN_ROOT spelled as <checkout-root>, into a
// minimal settings file (no permissions block, no disableBypassPermissionsMode).
// Prints "<pre-count> <post-count>".
"use strict";

const fs = require("fs");

const [source, checkoutRoot, out] = process.argv.slice(2);
let settings = {};
try { settings = JSON.parse(fs.readFileSync(source, "utf8")); } catch (_e) { settings = {}; }
const root = String(checkoutRoot || "").replace(/\\/g, "/");

function pick(event, re) {
  return (((settings || {}).hooks || {})[event] || [])
    .map((group) => ({ matcher: group.matcher, hooks: (group.hooks || []).filter((h) => re.test(String(h.command || ""))) }))
    .filter((group) => group.hooks.length > 0)
    .map((group) => ({
      matcher: group.matcher,
      hooks: group.hooks.map((h) => ({ ...h, command: String(h.command).replace(/\$\{?AGENTS_MAIN_ROOT\}?/g, () => root) })),
    }));
}

const pre = pick("PreToolUse", /hooks\/gate-reset-from-sentinel\.js/);
const post = pick("PostToolUse", /hooks\/workflow-mark\.js/);
fs.writeFileSync(out, JSON.stringify({ hooks: { PreToolUse: pre, PostToolUse: post } }, null, 2) + "\n");
process.stdout.write(`${pre.length} ${post.length}`);
