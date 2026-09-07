#!/usr/bin/env node
// Extracts ONE hook's real PreToolUse registration out of the deployable settings.json
// and re-emits it as a minimal project settings fixture, so a TL3 test exercises the
// artifact that ships rather than the harness author's idea of the registration.
//   --matcher <needle> | --timeout <needle> | --emit <needle>
// Path placeholders in the real command resolve to this checkout (the fixture project
// is not the agents repo). Prints NOT_REGISTERED / SETTINGS_UNREADABLE / BAD_MODE.
"use strict";

const fs = require("fs");
const path = require("path");

const AGENTS_DIR = process.env.AGENTS_DIR || path.join(__dirname, "..", "..");
const NATIVE_DIR = AGENTS_DIR.replace(/\\/g, "/");
const mode = process.argv[2];
const needle = process.argv[3] || "";

let settings;
try {
  settings = JSON.parse(fs.readFileSync(path.join(AGENTS_DIR, "settings.json"), "utf8"));
} catch (e) {
  console.log("SETTINGS_UNREADABLE:" + (e && e.message ? e.message : String(e)));
  process.exit(0);
}

const pre = settings && settings.hooks && Array.isArray(settings.hooks.PreToolUse)
  ? settings.hooks.PreToolUse : [];
const has = (h) => h && typeof h.command === "string" && h.command.indexOf(needle) !== -1;
const entry = needle ? pre.find((e) => e && Array.isArray(e.hooks) && e.hooks.some(has)) : null;

if (!entry) {
  console.log("NOT_REGISTERED");
  process.exit(0);
}

function resolvePlaceholders(cmd) {
  return cmd
    .split("$CLAUDE_PROJECT_DIR").join(NATIVE_DIR)
    .split("${CLAUDE_PROJECT_DIR}").join(NATIVE_DIR)
    .split("$AGENTS_CONFIG_DIR").join(NATIVE_DIR)
    .split("${AGENTS_CONFIG_DIR}").join(NATIVE_DIR);
}

if (mode === "--matcher") {
  console.log(String(entry.matcher));
} else if (mode === "--timeout") {
  console.log(String(entry.hooks.find(has).timeout));
} else if (mode === "--emit") {
  // Only the hook under test survives: a fixture carrying the sibling hooks of the
  // same entry would let another guard produce the deny this test attributes here.
  const hook = entry.hooks.find(has);
  const out = {
    hooks: {
      PreToolUse: [
        {
          matcher: entry.matcher,
          hooks: [
            {
              type: hook.type || "command",
              command: resolvePlaceholders(hook.command),
              timeout: hook.timeout,
            },
          ],
        },
      ],
    },
  };
  console.log(JSON.stringify(out, null, 2));
} else {
  console.log("BAD_MODE");
}
